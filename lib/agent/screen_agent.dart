import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../ai/openai_brain.dart';
import '../core/privacy_filter.dart';
import '../device/app_resolver.dart';
import '../device/device_bridge.dart';
import 'tools.dart';

/// What the screen agent needs from the rest of LEO (kept as callbacks so the agent stays testable
/// and the orchestrator keeps ownership of approvals, voice and task state).
class ScreenAgentHooks {
  /// STOP / PAUSE / CANCEL: throws when the task was stopped, waits while paused.
  final Future<void> Function() checkpoint;

  /// Ask the user to approve one sensitive tap. Must be bound to exactly this app + button (+ typed text).
  final Future<bool> Function(String app, String button, String? typedText) approve;

  /// Ask the user a free-text question (e.g. "which Rahul?").
  final Future<String> Function(String question) askUser;

  /// Progress for the overlay / task card. [index] highlights the element being acted on.
  final void Function(String step, {int? index, bool warn}) onStep;

  /// Every model call: real token usage (as reported by the API) + exactly what was sent (masked).
  final void Function(int? input, int? output, int? cached, int ms, String sentPreview) onUsage;

  /// Labels that need approval before tapping (send, pay, call, delete …).
  final bool Function(String label) isSensitive;

  const ScreenAgentHooks({
    required this.checkpoint,
    required this.approve,
    required this.askUser,
    required this.onStep,
    required this.onUsage,
    required this.isSensitive,
  });
}

class ScreenAgentResult {
  final String status; // success | failed | declined | timeout
  final String message;
  final int inputTokens, outputTokens, steps;
  const ScreenAgentResult(this.status, this.message, {this.inputTokens = 0, this.outputTokens = 0, this.steps = 0});
}

/// Model-driven agent that operates other apps through LEO's accessibility service.
///
/// Architecture adapted from Sanna's accessibility sub-agent (MIT): tool loop, screen state only in
/// tool results (never in the system prompt), finish_task as the only exit, action history, learned
/// per-app hints. LEO additions: success is REJECTED unless the screen was re-read after the last
/// action; sensitive taps need the user's approval; STOP/PAUSE checked before every model call and
/// action; only the latest screen stays in context (fewer tokens); personal data on screen is masked.
class ScreenAgent {
  final DeviceBridge device;
  final AppResolver apps;
  final OpenAiBrain brain;
  final String apiKey, model;
  final ScreenAgentHooks hooks;
  final int maxSteps;

  ScreenAgent({
    required this.device,
    required this.apps,
    required this.brain,
    required this.apiKey,
    required this.model,
    required this.hooks,
    this.maxSteps = 16,
  });

  // ---- run state
  String? _screen; // last screen as sent (masked)
  String? _pkg;
  bool _verifiedAfterLastAction = false;
  bool _actedAtLeastOnce = false;
  final _secrets = <String, String>{}; // placeholder → real value (stays on the phone)
  final _history = <String>[]; // human-readable successful steps, for learned hints
  final _failures = <String>[];
  ({String status, String message})? _finish;

  static const systemPrompt = '''
You are LEO's screen agent. You operate Android apps for the user through tools, one action at a time.

Screen format (from get_screen): one element per line: [index] Kind "label | description" (flags).
Flags: tap = can be tapped, input = text field, scroll = scrollable, on/off = switch state.

Rules:
1. Start with get_screen (or open_app if the right app is not open).
2. Every act returns the NEW screen. Use ONLY indices from the most recent screen.
3. Prefer the most direct path. Do not repeat an action that failed — try something else.
4. Typing: act(type) into the input, then press the send/search button (or act(submit)).
5. Values like <PHONE_1>, <EMAIL_1>, <OTP_1> are private values hidden by the phone: type them exactly as written.
6. If you need information only the user has (which contact, which item), call ask_user.
7. Sensitive buttons (send, pay, buy, call, delete, post…) are checked with the user automatically when you tap them.
8. finish_task(status="success") as soon as the latest screen shows the goal is achieved. Describe what was ACTUALLY done.
   A message is SENT when its text appears in the conversation and the text box is empty again — then finish, don't act further.
   An item is ADDED when its button changes to "1 in cart" / "Added" — then finish, don't tap prices or "Buy".
9. If stuck after 2 attempts, try back/home once, then finish_task(status="failed") with the reason. Never guess.
Keep any text you write very short.''';

  Future<ScreenAgentResult> run(String goal) async {
    final reg = ToolRegistry()
      ..register(_OpenAppTool(this))
      ..register(_GetScreenTool(this))
      ..register(_ActTool(this))
      ..register(_AskUserTool(this))
      ..register(_FinishTool(this));
    final hints = await _loadHints(goal);
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt}, // static → cacheable
      {
        'role': 'user',
        'content': 'Goal: $goal'
            '${hints.isEmpty ? '' : '\nWhat worked before in similar tasks:\n${hints.map((h) => '- $h').join('\n')}'}',
      },
    ];
    final idToTool = <String, String>{};
    var inTok = 0, outTok = 0, step = 0;
    for (; step < maxSteps; step++) {
      await hooks.checkpoint();
      _trimOldScreens(messages, idToTool);
      final r = await brain.chatTools(apiKey: apiKey, model: model, messages: messages, tools: reg.definitions());
      inTok += r.input ?? 0;
      outTok += r.output ?? 0;
      hooks.onUsage(r.input, r.output, r.cached, r.ms, _preview(messages));
      messages.add({'role': 'assistant', 'content': r.message['content'], 'tool_calls': r.message['tool_calls']});
      if (r.calls.isEmpty) {
        return ScreenAgentResult('failed', r.text.isEmpty ? 'The model stopped without finishing.' : r.text,
            inputTokens: inTok, outputTokens: outTok, steps: step + 1);
      }
      for (final c in r.calls) {
        idToTool[c.id] = c.name;
        await hooks.checkpoint();
        final res = await reg.execute(c.name, c.args);
        messages.add({'role': 'tool', 'tool_call_id': c.id, 'content': res.forModel});
        if (res.stop) {
          final f = _finish ?? (status: 'failed', message: res.forModel);
          if (f.status == 'success') await _saveHint(goal);
          return ScreenAgentResult(f.status, f.message, inputTokens: inTok, outputTokens: outTok, steps: step + 1);
        }
      }
    }
    return ScreenAgentResult('timeout', 'I couldn\'t finish within $maxSteps steps.', inputTokens: inTok, outputTokens: outTok, steps: step);
  }

  /// Only the newest screen stays in the conversation — older ones become a one-line stub.
  void _trimOldScreens(List<Map<String, dynamic>> messages, Map<String, String> idToTool) {
    final screens = [
      for (var i = 0; i < messages.length; i++)
        if (messages[i]['role'] == 'tool' && '${messages[i]['content']}'.contains('SCREEN (app:')) i
    ];
    for (final i in screens.take(screens.length > 1 ? screens.length - 1 : 0)) {
      final c = '${messages[i]['content']}';
      messages[i] = {...messages[i], 'content': '${c.substring(0, c.indexOf('SCREEN (app:'))}[older screen omitted]'};
    }
  }

  static String _preview(List<Map<String, dynamic>> m) {
    final last = m.lastWhere((x) => x['role'] == 'tool' || x['role'] == 'user', orElse: () => m.last);
    final c = '${last['content'] ?? ''}';
    return c.length > 300 ? '${c.substring(0, 300)}…' : c;
  }

  // ---- learned hints (deterministic: recorded from steps that worked; no extra model calls)
  static String _hintKey(String pkg) => 'agent_hints_$pkg';

  Future<List<String>> _loadHints(String goal) async {
    try {
      final p = await SharedPreferences.getInstance();
      final all = <String>[];
      for (final k in p.getKeys().where((k) => k.startsWith('agent_hints_'))) {
        all.addAll((jsonDecode(p.getString(k) ?? '[]') as List).cast<String>());
      }
      final words = goal.toLowerCase().split(RegExp(r'\W+')).where((w) => w.length > 3).toSet();
      final scored = [for (final h in all) (h, words.where(h.toLowerCase().contains).length)]..sort((a, b) => b.$2.compareTo(a.$2));
      return [for (final s in scored.take(2)) if (s.$2 > 0) s.$1];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveHint(String goal) async {
    if (_pkg == null || _history.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final list = (jsonDecode(p.getString(_hintKey(_pkg!)) ?? '[]') as List).cast<String>();
      final hint = '"${goal.length > 60 ? goal.substring(0, 60) : goal}" in $_pkg: ${_history.join(' → ')}';
      list
        ..remove(hint)
        ..insert(0, hint);
      await p.setString(_hintKey(_pkg!), jsonEncode(list.take(5).toList()));
    } catch (_) {}
  }

  static Future<void> clearHints() async {
    final p = await SharedPreferences.getInstance();
    for (final k in p.getKeys().where((k) => k.startsWith('agent_hints_')).toList()) {
      await p.remove(k);
    }
  }

  /// Reads + masks the current screen. Returns the block sent to the model.
  Future<String?> _readScreen() async {
    final d = await device.screenDump(max: 70);
    if (d['ok'] != true) return null;
    _pkg = d['package'] as String?;
    final red = PrivacyFilter.redact(d['screen'] as String? ?? '', messageBodies: false);
    _secrets.addAll(red.secrets);
    _screen = red.text;
    _verifiedAfterLastAction = true;
    return 'SCREEN (app: $_pkg):\n${red.text}';
  }

  /// After an approved send: is [typed] now shown as a message and gone from the text box?
  bool _looksSent(String typed) {
    final probe = typed.toLowerCase().trim();
    if (probe.isEmpty || _screen == null) return false;
    final lines = _screen!.toLowerCase().split('\n');
    final inBox = lines.any((l) => l.contains('input') && l.contains(probe));
    final shown = lines.any((l) => !l.contains('input') && l.contains(probe));
    return shown && !inBox;
  }

  /// After tapping "Add to cart": does the screen now show the item in the cart?
  bool _looksAddedToCart() => RegExp(r'\b\d+ in (cart|basket|bag)\b|added to (your )?(cart|basket|bag)|item added|go to (cart|basket|bag)',
          caseSensitive: false)
      .hasMatch(_screen ?? '');

  String? _labelOf(int index) {
    final line = (_screen ?? '').split('\n').firstWhere((l) => l.startsWith('[$index]'), orElse: () => '');
    final m = RegExp(r'"(.*)"').firstMatch(line);
    return m?.group(1)?.split(' | ').firstWhere((x) => x.trim().isNotEmpty, orElse: () => '').trim();
  }

  String _restore(String s) {
    var out = s;
    _secrets.forEach((k, v) => out = out.replaceAll(k, v));
    return out;
  }
}

// ------------------------------------------------------------------ tools

class _OpenAppTool extends AgentTool {
  final ScreenAgent a;
  _OpenAppTool(this.a);
  @override
  String get name => 'open_app';
  @override
  String get description => 'Open an installed app by its name.';
  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {'app': {'type': 'string', 'description': 'App name, e.g. "Instagram"'}},
        'required': ['app'],
      };
  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final name = '${args['app'] ?? ''}';
    final found = await a.apps.resolve(name);
    if (found.isEmpty) return ToolResult.error('"$name" is not installed.');
    if (await a.device.isBlockedApp(found.first.packageName)) {
      return const ToolResult('Banking/payment apps are not operated by LEO.', stop: true, isError: true);
    }
    a.hooks.onStep('Open ${found.first.label}');
    final r = await a.device.screenAct('open_app', package: found.first.packageName);
    if (r['ok'] != true) return ToolResult.error('Could not open ${found.first.label}.');
    a._history.add('open ${found.first.label}');
    a._verifiedAfterLastAction = false;
    return ToolResult('Opened ${found.first.label}. Call get_screen.');
  }
}

class _GetScreenTool extends AgentTool {
  final ScreenAgent a;
  _GetScreenTool(this.a);
  @override
  String get name => 'get_screen';
  @override
  String get description => 'Read the current screen (elements with indices). Call after every action.';
  @override
  Map<String, dynamic> get parameters => {'type': 'object', 'properties': {}};
  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    // Phone numbers / emails / OTPs / IDs on screen are masked before they leave the phone.
    final scr = await a._readScreen();
    if (scr == null) return ToolResult.error('Cannot read the screen (accessibility off or banking app).');
    return ToolResult(scr);
  }
}

class _ActTool extends AgentTool {
  final ScreenAgent a;
  _ActTool(this.a);
  @override
  String get name => 'act';
  @override
  String get description => 'Do one UI action on the current screen.';
  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': ['tap', 'long_press', 'type', 'submit', 'scroll_down', 'scroll_up', 'back', 'wait'],
          },
          'index': {'type': 'integer', 'description': 'Element index from the latest get_screen (tap/long_press/type/submit).'},
          'text': {'type': 'string', 'description': 'Text for "type".'},
        },
        'required': ['action'],
      };
  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final action = '${args['action']}';
    final index = (args['index'] as num?)?.toInt();
    final text = args['text'] == null ? null : a._restore('${args['text']}');
    if ({'tap', 'long_press', 'type'}.contains(action) && index == null) return ToolResult.error('"index" is required for $action.');
    final label = index == null ? null : a._labelOf(index);
    if (index != null && label == null) return ToolResult.error('No element [$index] on the latest screen. Call get_screen.');

    // Human in control: sensitive buttons need an explicit OK bound to this exact button + app.
    final sensitive = (action == 'tap' || action == 'long_press') && label != null && a.hooks.isSensitive(label);
    final lastTyped = a._history.lastWhere((h) => h.startsWith('type '), orElse: () => '');
    final typedText = lastTyped.isEmpty ? null : lastTyped.substring(5);
    if (sensitive) {
      a.hooks.onStep('Waiting for your OK: "$label"', index: index, warn: true);
      final ok = await a.hooks.approve(a._pkg ?? 'this app', label, typedText);
      if (!ok) {
        a._finish = (status: 'declined', message: 'You said no, so I didn\'t press "$label".');
        return ToolResult('User declined pressing "$label". Stop.', stop: true);
      }
    }

    final describe = switch (action) {
      'tap' => 'Tap "$label"',
      'long_press' => 'Long-press "$label"',
      'type' => 'Type "${args['text']}"',
      'submit' => 'Press enter',
      'scroll_down' => 'Scroll down',
      'scroll_up' => 'Scroll up',
      'back' => 'Go back',
      _ => 'Wait',
    };
    a.hooks.onStep(describe, index: index);
    Map<String, dynamic> r;
    switch (action) {
      case 'scroll_down' || 'scroll_up':
        r = await a.device.screenAct('scroll', dir: action == 'scroll_up' ? 'up' : 'down');
      case 'tap':
        r = await a.device.screenAct('tap', index: index);
      default:
        r = await a.device.screenAct(action, index: index, text: text);
    }
    final ok = r['ok'] == true;
    a._verifiedAfterLastAction = false;
    a._actedAtLeastOnce = true;
    if (ok) {
      a._history.add(switch (action) {
        'tap' => 'tap "$label"',
        'type' => 'type ${args['text']}',
        _ => action,
      });
    } else {
      a._failures.add(describe);
    }
    // Return the new screen with the result: one model call per action instead of two.
    final scr = await a._readScreen();
    // A send we approved is confirmed by code, not by the model's opinion.
    if (ok && sensitive && typedText != null && a._looksSent(typedText)) { // both masked the same way
      a._finish = (status: 'success', message: 'Sent "$typedText".');
      return ToolResult('Sent — confirmed on screen.', stop: true);
    }
    // "Add to cart" is confirmed by code too, so the model doesn't wander onto "Buy" buttons afterwards.
    if (ok && action == 'tap' && RegExp(r'add to (cart|basket|bag)', caseSensitive: false).hasMatch(label ?? '') && a._looksAddedToCart()) {
      a._finish = (status: 'success', message: 'Added it to the cart (shown on screen). Nothing was bought.');
      return ToolResult('Added to cart — confirmed on screen.', stop: true);
    }
    final head = ok ? '$describe → done.' : '$describe → FAILED (${r['reason'] ?? 'unknown'}). Try something else.';
    return ToolResult(scr == null ? head : '$head\n$scr', isError: !ok);
  }
}

class _AskUserTool extends AgentTool {
  final ScreenAgent a;
  _AskUserTool(this.a);
  @override
  String get name => 'ask_user';
  @override
  String get description => 'Ask the user a short question when information is missing or ambiguous.';
  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {'question': {'type': 'string'}},
        'required': ['question'],
      };
  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final answer = await a.hooks.askUser('${args['question']}');
    return ToolResult('User answered: "${PrivacyFilter.redact(answer, messageBodies: false).text}"');
  }
}

class _FinishTool extends AgentTool {
  final ScreenAgent a;
  _FinishTool(this.a);
  @override
  String get name => 'finish_task';
  @override
  String get description =>
      'End the task. status "success" ONLY after a fresh get_screen confirms the goal; otherwise "failed" with the reason.';
  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'status': {'type': 'string', 'enum': ['success', 'failed']},
          'message': {'type': 'string', 'description': 'What was ACTUALLY done (past tense), or why it failed.'},
        },
        'required': ['status', 'message'],
      };
  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final status = '${args['status']}';
    final msg = a._restore('${args['message'] ?? ''}');
    // Enforced in code, not just in the prompt: no success without looking at the result.
    if (status == 'success' && (!a._verifiedAfterLastAction || !a._actedAtLeastOnce && a._history.isEmpty)) {
      return ToolResult.error('Not verified: call get_screen and check the result before finishing with success.');
    }
    a._finish = (status: status, message: msg);
    return ToolResult('Finished: $status', stop: true);
  }
}
