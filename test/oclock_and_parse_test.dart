import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';
import 'package:jarvis/core/time_parser.dart';
import 'package:jarvis/ai/sarvam_brain.dart';
import 'package:jarvis/orchestrator/jarvis_orchestrator.dart';
void main() {
  test('6 o\'clock', () {
    final i = LocalIntentEngine().parse("turn off my 6 o'clock alarm");
    print(i.runtimeType);
    expect(i, isA<DismissAlarmIntent>());
    expect(TimeParser.when((i as DismissAlarmIntent).text), isNotNull, reason: i.text);
  });
  test('stray key', () => expect(SarvamBrain.parse('{"on the phone": "open X"}').commands, ['on the phone: open X']));

  test('complex requests go to the brain', () {
    for (final t in ['yaar pehle youtube khol do phir time bata do', 'open youtube and then tell me the time', 'mujhe gaana sunna hai']) {
      expect(JarvisOrchestrator.looksComplex(t), isTrue, reason: t);
    }
    for (final t in ['what time is it', 'open youtube', 'call mom']) {
      expect(JarvisOrchestrator.looksComplex(t), isFalse, reason: t);
    }
  });
}
