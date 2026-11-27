import 'dart:convert';

import '../device/device_bridge.dart';

/// Screen-agent brain that runs ENTIRELY on the phone (no API key, no network):
/// Qwen2.5-1.5B-Instruct via MediaPipe. Small model ⇒ short prompt, one JSON action, and all
/// safety decisions stay in LEO's own code (approvals, blocked apps, passwords).
class LocalAgentBrain {
  final DeviceBridge device;
  LocalAgentBrain(this.device);

  static const _maxPromptTokens = 1120; // model KV cache is 1280 tokens (prompt + answer)

  static const _system =
      'You control an Android phone to reach the user\'s goal, one step at a time. Reply with ONE JSON object only.\n'
      'Actions:\n'
      '{"action":"open_app","app":"Gmail"}\n'
      '{"action":"tap","index":3}\n'
      '{"action":"type","index":2,"text":"hello"}\n'
      '{"action":"submit"} (press enter/search after typing)\n'
      '{"action":"scroll","dir":"down"}\n'
      '{"action":"back"}\n'
      '{"action":"done","text":"what was achieved"}\n'
      '{"action":"ask","text":"question for the user"}\n'
      'Use the [number] of a screen element for index. Open the right app first. '
      'Say done only when the screen shows the goal is achieved. Never type passwords.';

  String _prompt(String goal, List<String> history, String? package, List<String> screen) =>
      '<|im_start|>system\n$_system<|im_end|>\n'
      '<|im_start|>user\nGoal: $goal\n'
      'Done so far: ${history.isEmpty ? 'nothing yet' : history.join('; ')}\n'
      'Current app: ${package ?? 'unknown'}\n'
      'Screen:\n${screen.join('\n')}<|im_end|>\n'
      '<|im_start|>assistant\n{"action":"';

  /// Returns the same plan shape the Gemini agent uses:
  /// {action:{type,index,text,dir,app}, done, summary, ask, describe}
  Future<Map<String, dynamic>> step({
    required String goal,
    required String screen,
    required String? package,
    required List<String> history,
  }) async {
    var lines = screen.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final hist = history.length > 4 ? history.sublist(history.length - 4) : history;
    // Fit the context window: drop elements from the end until the prompt fits.
    var prompt = _prompt(goal, hist, package, lines);
    var tokens = await device.llmCountTokens(prompt);
    while (tokens > _maxPromptTokens && lines.length > 5) {
      lines = lines.sublist(0, (lines.length * 0.8).floor());
      prompt = _prompt(goal, hist, package, lines);
      tokens = await device.llmCountTokens(prompt);
    }
    final raw = '{"action":"${await device.llmGenerate(prompt)}';
    return parse(raw, screenLines: lines);
  }

  /// Robust JSON extraction for small-model output (trailing text, single quotes, stray tokens).
  static Map<String, dynamic> parse(String raw, {List<String> screenLines = const []}) {
    var text = raw.replaceAll('<|im_end|>', '').trim();
    final start = text.indexOf('{');
    if (start < 0) return const {'ask': 'I could not decide the next step on my own.'};
    final end = text.indexOf('}', start);
    if (end < 0) return const {'ask': 'I could not decide the next step on my own.'};
    var obj = text.substring(start, end + 1);
    Map<String, dynamic>? j;
    for (final candidate in [obj, obj.replaceAll("'", '"')]) {
      try {
        final v = jsonDecode(candidate);
        if (v is Map<String, dynamic>) {
          j = v;
          break;
        }
      } catch (_) {}
    }
    if (j == null) return const {'ask': 'I could not decide the next step on my own.'};
    final action = (j['action'] as String? ?? '').trim().toLowerCase();
    final index = j['index'] is num ? (j['index'] as num).toInt() : int.tryParse('${j['index'] ?? ''}');
    final t = (j['text'] as String?)?.trim();
    String label() {
      if (index == null) return '';
      final line = screenLines.firstWhere((l) => l.startsWith('[$index]'), orElse: () => '');
      final m = RegExp(r'"([^"]*)"').firstMatch(line);
      return m?.group(1)?.split(' | ').first ?? '';
    }

    switch (action) {
      case 'done':
        return {'done': true, 'summary': t ?? 'Done.'};
      case 'ask':
        return {'ask': t ?? 'What should I do next?'};
      case 'open_app':
        final app = (j['app'] as String?) ?? t;
        return {'action': {'type': 'open_app', 'app': app}, 'describe': 'Open $app'};
      case 'tap':
      case 'long_press':
        final l = label();
        return {'action': {'type': action, 'index': index}, 'describe': l.isEmpty ? 'Tap item $index' : 'Tap "$l"'};
      case 'type':
        return {'action': {'type': 'type', 'index': index, 'text': t ?? ''}, 'describe': 'Type "${t ?? ''}"'};
      case 'submit':
        return {'action': {'type': 'submit', 'index': index}, 'describe': 'Press enter'};
      case 'scroll':
        final dir = (j['dir'] as String?) ?? 'down';
        return {'action': {'type': 'scroll', 'index': index, 'dir': dir}, 'describe': 'Scroll $dir'};
      case 'back':
      case 'home':
      case 'wait':
        return {'action': {'type': action}, 'describe': action == 'back' ? 'Go back' : (action == 'home' ? 'Go home' : 'Wait')};
    }
    return const {'ask': 'I could not decide the next step on my own.'};
  }
}
