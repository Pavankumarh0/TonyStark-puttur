import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';
import 'package:jarvis/orchestrator/jarvis_orchestrator.dart';
import 'package:jarvis/ai/local_agent_brain.dart';

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
    test('search for bengaluru on wikipedia', () {
      final i = e.parse('search for bengaluru on wikipedia') as OpenWebsiteIntent;
      expect(i.site, 'wikipedia');
      expect(i.then, 'search for bengaluru');
    });
    test('plain web search unchanged', () => expect(e.parse('search for best biryani near me'), isA<WebSearchIntent>()));
    test('site search urls', () {
      expect(JarvisOrchestrator.siteSearchUrl('wikipedia.org', 'bengaluru'), 'https://en.wikipedia.org/w/index.php?search=bengaluru');
      expect(JarvisOrchestrator.siteSearchUrl('example.org', 'x y'), contains('site%3Aexample.org'));
    });
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
    test('price parser skips filter chips and list prices', () {
      final p = JarvisOrchestrator.parseProducts([
        'ANC vs transparency mode for calls',
        'Best wireless earbuds for iPhone users',
        'Noise Buds Mini X Truly Wireless Earbuds',
        '3.9',
        '-67%',
        '₹999',
        '₹2,999.00',
        'Realme Buds T110 with AI ENC for calls',
        '₹1,299',
      ]);
      expect(p.map((x) => x.price), [999, 1299]);
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

  group('Natural phrasing', () {
    test('uh, can you … ? is still a phone task', () =>
        expect(e.parse('uh, can you open Instagram and send a reel to Pawan Kumar?'), isA<PhoneTaskIntent>()));
    test('so, um... play kesariya on spotify', () => expect(e.parse('so, play kesariya on spotify'), isA<PlayMediaIntent>()));
    test('questions still go to knowledge', () => expect(e.parse('what is the capital of France?'), isNot(isA<PhoneTaskIntent>())));
  });

  test('name spelling variants', () {
    expect(JarvisOrchestrator.spellingVariants('Pawan'), contains('pavan'));
    expect(JarvisOrchestrator.spellingVariants('Sreya'), contains('shreya'));
  });

  group('Login', () {
    test('log in to spotify with my phone number', () {
      final i = e.parse('log in to spotify with my phone number') as SignInIntent;
      expect(i.appName, 'spotify');
      expect(i.method, 'phone');
    });
    test('sign into instagram using google', () => expect((e.parse('sign into instagram using google') as SignInIntent).method, 'google'));
    test('login to spotify', () => expect((e.parse('login to spotify') as SignInIntent).method, isNull));
    test('otp from sms', () {
      expect(JarvisOrchestrator.extractOtp('482913 is your Spotify verification code. Do not share it.'), '482913');
      expect(JarvisOrchestrator.extractOtp('Your OTP for login is 5521. Valid for 10 mins'), '5521');
      expect(JarvisOrchestrator.extractOtp('Rs 1200 debited from a/c 4455'), isNull);
    });
  });

  group('Screen questions', () {
    test('One-Step Login sheet is a question', () {
      const screen = '[0] text "One-Step Login" ()\n'
          '[1] text "Activate One-Step Login for Spotify across all of your Samsung devices" ()\n'
          '[2] button "Activate" (tap)\n'
          '[3] button "Not now" (tap)';
      final q = LocalAgentBrain.detectQuestion(screen)!;
      expect(q.buttons.map((b) => b.label), ['Activate', 'Not now']);
      expect(q.question, contains('One-Step Login'));
    });
    test('permission prompt', () {
      const screen = '[0] text "Allow Instagram to access photos and videos?" ()\n'
          '[1] button "Allow" (tap)\n[2] button "Don\'t allow" (tap)';
      expect(LocalAgentBrain.detectQuestion(screen)!.buttons.length, 2);
    });
    test('normal page is not a question', () {
      const screen = '[0] input "Search" (tap,input)\n[1] button "Home" (tap)\n[2] text "Recently played" ()\n'
          '[3] button "Kesariya" (tap)\n[4] button "Library" (tap)';
      expect(LocalAgentBrain.detectQuestion(screen), isNull);
    });
  });
}
