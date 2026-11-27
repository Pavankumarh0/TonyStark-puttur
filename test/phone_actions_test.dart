import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';

void main() {
  final e = LocalIntentEngine();

  group('Phone actions are local (no AI)', () {
    test('set alarm for 6:30 am', () {
      final i = e.parse('set alarm for 6:30 am');
      expect(i, isA<SetAlarmIntent>());
      expect(i.requiresAi, isFalse);
    });
    test('Leo, wake me up at 7 tomorrow', () => expect(e.parse('Leo, wake me up at 7 tomorrow'), isA<SetAlarmIntent>()));
    test('remind me to call mom at 8 pm', () {
      final i = e.parse('remind me to call mom at 8 pm') as SetAlarmIntent;
      expect(i.label, 'Call mom');
    });
    test('set a timer for 10 minutes', () => expect((e.parse('set a timer for 10 minutes') as SetTimerIntent).length, const Duration(minutes: 10)));
    test('timer for 1 hour 30 minutes', () => expect((e.parse('timer for 1 hour 30 minutes') as SetTimerIntent).length, const Duration(minutes: 90)));

    test('schedule meeting at gmeet tomorrow 3 pm with Rahul about project review', () {
      final i = e.parse('schedule a meeting on google meet tomorrow at 3 pm with Rahul about project review') as ScheduleMeetingIntent;
      expect(i.googleMeet, isTrue);
      expect(i.attendees, ['Rahul']);
      expect(i.title, 'Project review');
    });
    test('schedule gmeet with Rahul and Kiran', () {
      final i = e.parse('schedule a gmeet with Rahul and Kiran tomorrow at 11 am') as ScheduleMeetingIntent;
      expect(i.googleMeet, isTrue);
      expect(i.attendees, ['Rahul', 'Kiran']);
      expect(i.title, 'Meeting with Rahul, Kiran');
    });
    test('book an appointment friday 4 pm (not meet)', () {
      final i = e.parse('book an appointment on friday at 4 pm') as ScheduleMeetingIntent;
      expect(i.googleMeet, isFalse);
    });
    test('start a google meet', () => expect(e.parse('start a google meet'), isA<StartMeetIntent>()));
    test('navigate to Mangalore', () => expect((e.parse('navigate to Mangalore') as NavigateIntent).place, 'Mangalore'));
    test('search google for best biryani in Puttur', () => expect((e.parse('search google for best biryani in Puttur') as WebSearchIntent).query, 'best biryani in Puttur'));
    test('turn on the flashlight', () => expect((e.parse('turn on the flashlight') as FlashlightIntent).on, isTrue));
    test('torch off', () => expect((e.parse('torch off') as FlashlightIntent).on, isFalse));
    test('take a selfie', () => expect((e.parse('take a selfie') as CameraIntent).selfie, isTrue));
    test('turn on wifi → panel', () {
      final i = e.parse('turn on wifi') as SettingsPanelIntent;
      expect(i.kind, 'wifi');
      expect(i.on, isTrue);
    });
    test('turn bluetooth off', () => expect((e.parse('turn bluetooth off') as SettingsPanelIntent).kind, 'bluetooth'));
    test('"play pesamale" still media, "stop" still stop', () {
      expect(e.parse('play pesamale'), isA<PlayMediaIntent>());
      expect(e.parse('stop'), isA<StopIntent>());
    });
  });
}
