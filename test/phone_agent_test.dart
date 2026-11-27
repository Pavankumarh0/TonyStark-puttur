import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';

void main() {
  final e = LocalIntentEngine();

  group('Reply from notification (local)', () {
    test('reply to Rahul saying I am on my way', () {
      final i = e.parse('reply to Rahul saying I am on my way') as ReplyIntent;
      expect(i.who, 'Rahul');
      expect(i.message, 'I am on my way');
      expect(i.requiresAi, isFalse);
    });
    test('reply to mom (ask for text later)', () => expect((e.parse('reply to mom') as ReplyIntent).message, isNull));
  });

  group('Real toggles (local)', () {
    test('turn on do not disturb', () => expect((e.parse('turn on do not disturb') as SettingsPanelIntent).kind, 'dnd'));
    test('turn off power saving mode', () => expect((e.parse('turn off power saving mode') as SettingsPanelIntent).kind, 'power_saving'));
    test('turn hotspot on', () => expect((e.parse('turn hotspot on') as SettingsPanelIntent).kind, 'hotspot'));
  });

  group('Anything else goes to the screen agent', () {
    for (final s in [
      'delete the last email from Amazon',
      'open gallery and search for beach photos',
      'find my photos from Goa in gallery',
      'mark all emails as read in Gmail',
      'go to instagram and like the latest post from virat',
      'send an email to hr@company.com with my leave request',
    ]) {
      test(s, () {
        final i = e.parse(s);
        expect(i, isA<PhoneTaskIntent>(), reason: '${i.runtimeType}');
        expect(i.requiresAi, isTrue);
      });
    }
  });

  group('Simple things stay local (no agent, no AI)', () {
    test('open gallery', () => expect(e.parse('open gallery'), isA<OpenAppIntent>()));
    test('open whatsapp', () => expect(e.parse('open whatsapp'), isA<OpenAppIntent>()));
    test('play pesamale', () => expect(e.parse('play pesamale'), isA<PlayMediaIntent>()));
    test('call pavan', () => expect(e.parse('call pavan'), isA<CallIntent>()));
    test('set alarm 7 am', () => expect(e.parse('set alarm for 7 am'), isA<SetAlarmIntent>()));
    test('check messages', () => expect(e.parse('check my new messages'), isA<CheckMessagesIntent>()));
    test('send whatsapp', () => expect(e.parse('send a message to Rahul saying hi'), isA<SendMessageIntent>()));
    test('knowledge still knowledge', () => expect(e.parse('what is the capital of France'), isA<KnowledgeIntent>()));
  });
}
