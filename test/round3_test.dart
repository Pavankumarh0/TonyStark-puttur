import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';
import 'package:jarvis/orchestrator/jarvis_orchestrator.dart';

void main() {
  final e = LocalIntentEngine();

  group('1 · alarms', () {
    test('turn off my 6:30 alarm', () => expect((e.parse('turn off my 6:30 alarm') as DismissAlarmIntent).text, '6:30'));
    test('stop the alarm (not STOP)', () => expect(e.parse('stop the alarm'), isA<DismissAlarmIntent>()));
    test('cancel all alarms', () => expect((e.parse('cancel all alarms') as DismissAlarmIntent).all, isTrue));
    test('snooze for 10 minutes', () => expect((e.parse('snooze for 10 minutes') as SnoozeAlarmIntent).minutes, 10));
    test('plain stop is still STOP', () => expect(e.parse('stop'), isA<StopIntent>()));
  });

  group('2 · whatsapp', () {
    test('read my chat with Rahul', () => expect((e.parse('read my chat with Rahul') as ReadChatIntent).who, 'Rahul'));
    test('read messages from mom on whatsapp', () => expect((e.parse('read messages from mom on whatsapp') as ReadChatIntent).who, 'Mom'));
    test('delete message → screen agent', () => expect(e.parse('delete the last message in my chat with Rahul on whatsapp'), isA<PhoneTaskIntent>()));
  });

  group('3 · install', () {
    test('install spotify', () => expect((e.parse('install spotify') as InstallAppIntent).app, 'spotify'));
    test('download the zomato app from play store', () => expect((e.parse('download the zomato app from play store') as InstallAppIntent).app, 'zomato'));
    test('download my pdf is NOT install', () => expect(e.parse('download my resume pdf'), isNot(isA<InstallAppIntent>())));
  });

  group('5 · calls', () {
    test('answer the call', () => expect((e.parse('answer the call') as CallControlIntent).action, CallAction.answer));
    test('pick up', () => expect((e.parse('Leo, pick up') as CallControlIntent).action, CallAction.answer));
    test('cut the call', () => expect((e.parse('cut the call') as CallControlIntent).action, CallAction.end));
    test('hang up', () => expect((e.parse('hang up') as CallControlIntent).action, CallAction.end));
    test('reject the call', () => expect((e.parse('reject the call') as CallControlIntent).action, CallAction.reject));
  });

  group('8 · files', () {
    test('open my resume pdf', () {
      final i = e.parse('open my resume pdf') as FindFileIntent;
      expect(i.query, 'resume');
      expect(i.open, isTrue);
    });
    test('find the aadhaar document', () => expect((e.parse('find the aadhaar document') as FindFileIntent).exts, contains('pdf')));
  });

  group('9 · websites', () {
    test('open flipkart.com', () => expect((e.parse('open flipkart.com') as OpenWebsiteIntent).site, 'flipkart.com'));
    test('go to wikipedia website', () => expect((e.parse('go to wikipedia website') as OpenWebsiteIntent).site, 'wikipedia website'));
    test('open github.com and search for flutter', () => expect((e.parse('open github.com and search for flutter') as OpenWebsiteIntent).then, 'search for flutter'));
  });

  group('10 · reminders', () {
    test('what are my reminders', () => expect(e.parse('what are my reminders'), isA<ListRemindersIntent>()));
    test('delete the reminder about milk', () => expect((e.parse('delete the reminder about milk') as DeleteReminderIntent).about, 'milk'));
    test('delete all reminders', () => expect((e.parse('delete all reminders') as DeleteReminderIntent).all, isTrue));
  });

  group('11 · shopping', () {
    test('search for wireless earbuds on amazon', () {
      final i = e.parse('search for wireless earbuds on amazon') as ShopIntent;
      expect(i.query, 'wireless earbuds');
      expect(i.addToCart, isFalse);
    });
    test('add a phone cover to cart on flipkart', () {
      final i = e.parse('add a phone cover to cart on flipkart') as ShopIntent;
      expect(i.store, 'flipkart');
      expect(i.addToCart, isTrue);
    });
    test('price parser pairs titles with prices', () {
      final p = JarvisOrchestrator.parseProducts([
        'Sponsored',
        'boAt Airdopes 141 Bluetooth TWS Earbuds with 42H Playtime',
        '4.1 out of 5 stars',
        '₹1,099',
        'Noise Buds VS104 Truly Wireless Earbuds, 45H Playtime',
        '₹899',
      ]);
      expect(p.length, 2);
      expect(p.first.price, 1099);
      expect(p.last.short, 'Noise Buds VS104 Truly Wireless Earbuds');
    });
  });

  group('12 · meetings', () {
    test('schedule a zoom meeting tomorrow at 5 pm with Kiran', () {
      final i = e.parse('schedule a zoom meeting tomorrow at 5 pm with Kiran') as ScheduleMeetingIntent;
      expect(i.attendees, ['Kiran']);
    });
  });

  group('Screen context', () {
    test('read this', () => expect((e.parse('read this') as ScreenCommandIntent).command, ScreenCommand.read));
    test("what's on my screen", () => expect((e.parse("what's on my screen") as ScreenCommandIntent).command, ScreenCommand.read));
    test('scroll down', () => expect((e.parse('scroll down') as ScreenCommandIntent).command, ScreenCommand.scrollDown));
    test('tap archive', () => expect((e.parse('tap archive') as ScreenCommandIntent).arg, 'archive'));
    test('go back', () => expect((e.parse('go back') as ScreenCommandIntent).command, ScreenCommand.back));
  });
}
