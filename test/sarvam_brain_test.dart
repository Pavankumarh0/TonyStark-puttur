import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/ai/sarvam_brain.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';

void main() {
  test('parses commands', () {
    final r = SarvamBrain.parse('{"commands": ["open ChatGPT", "ask it to prepare a PPT about blood"]}');
    expect(r.commands, ['open ChatGPT', 'ask it to prepare a PPT about blood']);
  });
  test('tolerates code fences / prose', () {
    final r = SarvamBrain.parse('Sure!\n```json\n{"answer": "It is 25 degrees, sir."}\n```');
    expect(r.answer, 'It is 25 degrees, sir.');
    expect(r.commands, isEmpty);
  });
  test('caps the chain at 4', () {
    final r = SarvamBrain.parse('{"commands": ["a","b","c","d","e","f"]}');
    expect(r.commands.length, 4);
  });
  test('clarify', () => expect(SarvamBrain.parse('{"clarify": "Which Rahul, sir?"}').clarify, 'Which Rahul, sir?'));
  test('every example command in the prompt is understood locally', () {
    final e = LocalIntentEngine();
    for (final c in [
      'open ChatGPT', 'play kesariya on spotify', 'pause the music', 'call Rahul', 'send a whatsapp message to Rahul saying hi',
      'read my chat with Rahul', 'check my messages', 'ask it to prepare a PPT about blood', 'ask ChatGPT to write a poem',
      'click Save', 'scroll down', 'go back', 'read this', 'set an alarm for 6 am', 'turn off my 6:30 alarm',
      'remind me to drink water at 5 pm', 'what are my reminders', 'open wikipedia.org', 'search for bengaluru on wikipedia',
      'open my resume pdf', 'install spotify', 'turn on wifi', 'log in to spotify with my phone number', 'navigate to MG Road',
      'on the phone: open Instagram, go to Reels, tap Share',
    ]) {
      final i = e.parse(c);
      expect(i, isNot(isA<UnknownIntent>()), reason: c);
      expect(i, isNot(isA<KnowledgeIntent>()), reason: c);
    }
  });
}
