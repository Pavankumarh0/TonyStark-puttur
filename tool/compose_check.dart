// Live check of OpenAI message writing (needs OPENAI_API_KEY in lib/.env). Same detector, prompt and
// settings as the app. Flags invented reasons/placeholders.   dart run tool/compose_check.dart
import 'dart:convert';
import 'dart:io';

import 'package:jarvis/ai/compose_prompts.dart';
import 'package:jarvis/ai/openai_brain.dart';
import 'package:jarvis/core/intent/compose_detector.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';
import 'package:jarvis/core/privacy_filter.dart';

Future<void> main() async {
  final key = File('lib/.env')
      .readAsLinesSync()
      .map((l) => RegExp(r'^\s*OPENAI_API_KEY\s*=\s*(\S+)').firstMatch(l)?.group(1))
      .whereType<String>()
      .first
      .replaceAll(RegExp('''["']'''), '');
  final brain = OpenAiBrain();
  final engine = LocalIntentEngine();
  // (request, words that must NOT appear because the user never said them)
  const cases = [
    ("send a WhatsApp message to my manager explaining why I won't be coming today", r'\bsick\b|fever|\bill\b|unwell|doctor|emergency|hospital|Dear Manager'),
    ("tell Kiran on WhatsApp that I can't come today because I have a fever, write it properly", r'hospital|doctor|emergency|covid'),
    ('send a polite message to my manager that I will be late by an hour', r'traffic|\bsick\b|doctor|emergency|\btrain\b|\bbus\b|personal matter|Dear Manager'),
    ('compose a long message to Amma telling her I reached safely and will call at night', r'hotel|flight|\btrain\b|tomorrow|journey|\btrip\b|settl|smooth|on the way'),
    ('whatsapp the office group that I am working from home today, explain it professionally', r'\bsick\b|\bill\b|plumber|emergency|internet|e-?mail|personal matter'),
  ];
  var pass = 0;
  for (final (req, invented) in cases) {
    final intent = ComposeDetector.upgrade(engine.parse(req), LocalIntentEngine.clean(req)) as SendMessageIntent;
    final red = PrivacyFilter.redact('Request: ${intent.composeTopic}', messageBodies: false);
    final sw = Stopwatch()..start();
    final r = await brain.chat(
        apiKey: key, model: 'gpt-4o-mini', system: ComposePrompts.wellWritten(intent.recipient), user: red.text,
        maxTokens: 350, temperature: 0.5, json: true);
    final text = red.restore(((jsonDecode(r.text) as Map)['content'] as String).trim());
    final bad = RegExp(invented, caseSensitive: false).firstMatch(text)?.group(0);
    final placeholder = RegExp(r'\[[A-Za-z ]+\]').hasMatch(text);
    final ok = bad == null && !placeholder && text.length > 20;
    if (ok) pass++;
    stdout.writeln('${ok ? 'PASS' : 'FAIL'}  "$req"');
    stdout.writeln('      to: ${intent.recipient}${intent.isGroup ? ' (group)' : ''}  ·  ${sw.elapsedMilliseconds} ms  ·  ${(r.input ?? 0) + (r.output ?? 0)} tokens');
    stdout.writeln('      → $text');
    if (bad != null) stdout.writeln('      ✗ invented: "$bad"');
    if (placeholder) stdout.writeln('      ✗ placeholder left in');
  }
  stdout.writeln('\n$pass/${cases.length} passed');
  exit(pass == cases.length ? 0 : 1);
}
