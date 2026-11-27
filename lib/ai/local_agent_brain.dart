import 'dart:convert';

import '../device/app_resolver.dart';
import '../device/device_bridge.dart';

/// Screen-agent brain that runs ENTIRELY on the phone (no API key, no network).
///
/// A 1.5B model can't plan freely (tested: it copies an example action whatever the screen),
/// so the job is split:
///  1. Rules handle the obvious steps (open the named app, search box → type → enter → done).
///  2. If exactly one on-screen element clearly matches the goal's distinctive words → pick it.
///  3. Otherwise the screen becomes a short numbered menu and the model only PICKS A NUMBER
///     (tested 4/6 on hard cases vs 0/3 for free-form JSON).
/// Safety decisions (approval, blocked apps, passwords) always stay in LEO's own code.
class LocalAgentBrain {
  final DeviceBridge device;
  final AppResolver apps;
  LocalAgentBrain(this.device, this.apps);

  static const _stop = {
    'the', 'a', 'an', 'my', 'in', 'on', 'at', 'to', 'for', 'of', 'and', 'with', 'from', 'open', 'go', 'please', 'leo',
    'app', 'me', 'show', 'find', 'search', 'look', 'up', 'latest', 'last', 'first', 'new', 'all', 'this', 'that', 'it', 'is',
  };

  static List<String> _words(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r"'s\b"), '') // "Rahul's" → "rahul"
      .replaceAll(RegExp(r"[^a-z0-9 ]"), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.length > 1)
      .toList();

  /// "search for beach photos in gallery" → "beach photos"
  static String? searchQuery(String goal) {
    final m = RegExp(r"\b(?:search|look|find|look up|show me|show)(?:\s+(?:for|up))?\s+(.+?)(?:\s+(?:in|on|inside|using)\s+(?:the\s+|my\s+)?[a-z ]+)?$",
            caseSensitive: false)
        .firstMatch(goal.trim());
    final q = m?.group(1)?.replaceAll(RegExp(r'^(my|the)\s+', caseSensitive: false), '').trim();
    return (q == null || q.isEmpty) ? null : q;
  }

  static ({int index, String kind, String label, List<String> flags})? _parseLine(String l) {
    final m = RegExp(r'^\[(\d+)\]\s+(\S+)\s+"(.*)"\s+\((.*)\)$').firstMatch(l.trim());
    if (m == null) return null;
    return (index: int.parse(m.group(1)!), kind: m.group(2)!, label: m.group(3)!, flags: m.group(4)!.split(',').where((f) => f.isNotEmpty).toList());
  }

  static bool _did(List<String> history, String type) =>
      history.any((h) => RegExp('^\\d+\\. $type\\b').hasMatch(h) && h.contains('→ ok'));

  Future<Map<String, dynamic>> step({
    required String goal,
    required String screen,
    required String? package,
    required List<String> history,
  }) async {
    final els = screen.split('\n').map(_parseLine).whereType<({int index, String kind, String label, List<String> flags})>().toList();

    // ---- Rule 1: open the app named in the goal (once).
    if (!_did(history, 'open_app')) {
      final installed = await apps.apps();
      final g = ' ${_words(goal).join(' ')} ';
      final named = installed.where((a) {
        final l = _words(a.label).join(' ');
        return l.isNotEmpty && g.contains(' $l ');
      }).toList()
        ..sort((x, y) => y.label.length.compareTo(x.label.length));
      if (named.isNotEmpty && named.first.packageName != package) {
        return {'action': {'type': 'open_app', 'app': named.first.label}, 'describe': 'Open ${named.first.label}', 'how': 'rule'};
      }
    }

    // ---- Rule: install from Play Store — tap the matching result, then Install (approval is enforced by LEO).
    final inst = RegExp(r'^install\s+(.+)$', caseSensitive: false).firstMatch(goal.trim());
    if (inst != null) {
      final installBtn = els.where((e) => e.flags.contains('tap') && RegExp(r'^install$', caseSensitive: false).hasMatch(e.label.split(' | ').first.trim())).firstOrNull;
      if (installBtn != null) {
        if (_did(history, 'tap') && history.last.contains('Tap "Install"')) {
          return {'done': true, 'summary': 'Installing ${inst.group(1)}. It will appear on your home screen when it finishes.', 'how': 'rule'};
        }
        return {'action': {'type': 'tap', 'index': installBtn.index}, 'describe': 'Tap "Install"', 'how': 'rule'};
      }
      final opened = els.any((e) => RegExp(r'^(open|uninstall|update)$', caseSensitive: false).hasMatch(e.label.split(' | ').first.trim()));
      if (opened && history.any((h) => h.contains('Tap "Install"'))) {
        return {'done': true, 'summary': '${inst.group(1)} is installing or installed.', 'how': 'rule'};
      }
      if (opened) return {'done': true, 'summary': '${inst.group(1)} is already installed.', 'how': 'rule'};
    }

    // ---- Rule: shopping "add to cart" button visible.
    if (RegExp(r'\b(add .* to (the |my )?cart|add to cart)\b', caseSensitive: false).hasMatch(goal)) {
      final cart = els.where((e) => e.flags.contains('tap') && RegExp(r'add to (cart|basket)', caseSensitive: false).hasMatch(e.label)).firstOrNull;
      if (cart != null && !history.any((h) => h.contains('Add to')))
        return {'action': {'type': 'tap', 'index': cart.index}, 'describe': 'Tap "Add to cart"', 'how': 'rule'};
    }

    // ---- Rule 2: search flow.
    final q = searchQuery(goal);
    if (q != null) {
      if (_did(history, 'submit')) {
        // "open/show the … photo": after searching, open the first result.
        if (RegExp(r'\b(and|then)\s+(open|show)\b|\b(open|show) (it|the (first|photo|image|picture|result|one))', caseSensitive: false).hasMatch(goal) &&
            !history.any((h) => h.contains('Open the first result'))) {
          final first = els.where((e) => e.flags.contains('tap') && RegExp(r'image|photo|picture|video|thumbnail', caseSensitive: false).hasMatch('${e.kind} ${e.label}')).firstOrNull;
          if (first != null) return {'action': {'type': 'tap', 'index': first.index}, 'describe': 'Open the first result', 'how': 'rule'};
        }
        return {'done': true, 'summary': 'Here are the results for "$q".', 'how': 'rule'};
      }
      final input = els.where((e) => e.flags.contains('input')).firstOrNull;
      if (_did(history, 'type') && input != null) {
        return {'action': {'type': 'submit', 'index': input.index}, 'describe': 'Press search', 'how': 'rule'};
      }
      if (input != null) {
        return {'action': {'type': 'type', 'index': input.index, 'text': q}, 'describe': 'Type "$q"', 'how': 'rule'};
      }
      final searchBtn = els.where((e) => e.flags.contains('tap') && RegExp(r'\bsearch\b', caseSensitive: false).hasMatch(e.label)).firstOrNull;
      if (searchBtn != null && !history.any((h) => h.contains('Tap "${searchBtn.label.split(' | ').first}"') && h.contains('→ ok'))) {
        return {'action': {'type': 'tap', 'index': searchBtn.index}, 'describe': 'Tap "${searchBtn.label.split(' | ').first}"', 'how': 'rule'};
      }
    }

    // ---- Build the option menu: tappable elements ranked by overlap with the goal's distinctive words.
    final goalWords = _words(goal).where((w) => !_stop.contains(w)).toSet();
    final done = history.map((h) => h.split(' — ').length > 1 ? h.split(' — ')[1].split(' →').first : '').toSet();
    final scored = <({String text, Map<String, dynamic> plan, int score})>[];
    for (final e in els) {
      if (!e.flags.contains('tap') || e.flags.contains('disabled')) continue;
      final label = e.label.split(' | ').first.trim();
      if (label.isEmpty) continue;
      final text = 'Tap "${label.length > 50 ? label.substring(0, 50) : label}"';
      if (done.contains(text)) continue; // don't repeat a step that already ran
      final score = _words(e.label).where(goalWords.contains).length;
      scored.add((text: text, plan: {'action': {'type': 'tap', 'index': e.index}, 'describe': text}, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    // ---- Rule 3: one clear match on a distinctive word → take it without the model.
    if (scored.isNotEmpty && scored.first.score > 0 && (scored.length == 1 || scored[1].score < scored.first.score)) {
      return {...scored.first.plan, 'how': 'match'};
    }

    // ---- Model: multiple choice.
    final options = <({String text, Map<String, dynamic> plan})>[
      for (final s in scored.take(8)) (text: s.text, plan: s.plan),
      (text: 'Scroll down', plan: {'action': {'type': 'scroll', 'dir': 'down'}, 'describe': 'Scroll down'}),
      (text: 'Go back', plan: {'action': {'type': 'back'}, 'describe': 'Go back'}),
      (text: 'The goal is already achieved', plan: {'done': true, 'summary': 'Done.'}),
    ];
    final prompt = '<|im_start|>system\nYou help operate a phone. Pick the option that moves closest to the goal. '
        'Answer with the option number only.<|im_end|>\n'
        '<|im_start|>user\nGoal: $goal\nAlready done: ${history.isEmpty ? 'nothing' : history.map((h) => h.split(' — ').last.split(' →').first).join('; ')}\n'
        'Current app: ${package ?? 'unknown'}\nOptions:\n${[for (var i = 0; i < options.length; i++) '${i + 1}. ${options[i].text}'].join('\n')}<|im_end|>\n'
        '<|im_start|>assistant\nOption ';
    final out = await device.llmGenerate(prompt);
    final n = int.tryParse(RegExp(r'\d+').firstMatch(out)?.group(0) ?? '');
    if (n == null || n < 1 || n > options.length) {
      return {'ask': 'I\'m not sure what to do on this screen. What should I tap?', 'raw': out.trim(), 'how': 'model'};
    }
    return {...options[n - 1].plan, 'how': 'model', 'raw': 'picked $n'};
  }

  /// Kept for compatibility/tests: robust JSON extraction for small-model output.
  static Map<String, dynamic> parse(String raw, {List<String> screenLines = const []}) {
    final text = raw.replaceAll('<|im_end|>', '').trim();
    final start = text.indexOf('{');
    if (start < 0) return const {'ask': 'I could not decide the next step on my own.'};
    final end = text.indexOf('}', start);
    if (end < 0) return const {'ask': 'I could not decide the next step on my own.'};
    final obj = text.substring(start, end + 1);
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
