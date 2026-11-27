import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/intent/local_classifier.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';

void main() {
  final e = LocalIntentEngine();

  group('Everyday tasks are handled by local rules (no AI)', () {
    test('play pesamale song in youtube', () {
      final i = e.parse('play pesamale song in youtube');
      expect(i, isA<PlayMediaIntent>());
      expect((i as PlayMediaIntent).query, 'pesamale song');
      expect(i.app, MediaApp.youtube);
      expect(i.requiresAi, isFalse);
    });
    test('Jarvis, play Kesariya on YouTube Music', () {
      final i = e.parse('Jarvis, play Kesariya on YouTube Music') as PlayMediaIntent;
      expect(i.query, 'Kesariya');
      expect(i.app, MediaApp.youtubeMusic);
    });
    test('open play store is not media', () => expect(e.parse('open play store'), isA<OpenAppIntent>()));
    test('call pavan', () {
      final i = e.parse('call pavan');
      expect(i, isA<CallIntent>());
      expect((i as CallIntent).name, 'pavan');
      expect(i.requiresAi, isFalse);
    });
    test('make a call to Pavan Kumar', () => expect((e.parse('make a call to Pavan Kumar') as CallIntent).name, 'Pavan Kumar'));
    test('check new messages in whatsapp and email', () {
      final i = e.parse('check new messages in whatsapp and email') as CheckMessagesIntent;
      expect(i.whatsapp, isTrue);
      expect(i.email, isTrue);
    });
    test('any new emails', () {
      final i = e.parse('any new emails?') as CheckMessagesIntent;
      expect(i.email, isTrue);
      expect(i.whatsapp, isFalse);
    });
    test('open WhatsApp stays open-app', () => expect(e.parse('open WhatsApp'), isA<OpenAppIntent>()));
    test('sending is still messaging', () => expect(e.parse('send a message to Rahul saying hi'), isA<SendMessageIntent>()));
    test('writing still uses AI', () => expect(e.parse('write a mail to HR and send it').requiresAi, isTrue));
  });

  group('On-device intent model catches paraphrases the rules miss', () {
    final c = LocalIntentClassifier()..train();
    test('"I wanna hear pesamale" → play', () {
      final i = c.classify('I wanna hear pesamale');
      expect(i, isA<PlayMediaIntent>());
      expect((i as PlayMediaIntent).query.toLowerCase(), contains('pesamale'));
    });
    test('"get pavan on the line" → call', () {
      final i = c.classify('get pavan on the line');
      expect(i, isA<CallIntent>());
      expect((i as CallIntent).name.toLowerCase(), contains('pavan'));
    });
    test('"any whatsapp messages for me" → check messages', () => expect(c.classify('any whatsapp messages for me'), isA<CheckMessagesIntent>()));
    test('knowledge questions are NOT handled locally', () => expect(c.classify('who won the world cup in 2011'), isNull));
    test('writing is NOT handled locally', () => expect(c.classify('draft an email to my manager about the delay'), isNull));
    test('learning: a phrase seen once becomes local', () {
      final c2 = LocalIntentClassifier()..train();
      const phrase = 'blast some tunes by anirudh';
      c2.add(phrase, 'play_media');
      c2.add('blast some tunes by arijit', 'play_media');
      expect(c2.classify('blast some tunes by sid sriram'), isA<PlayMediaIntent>());
    });
  });

  group('Music controls are local', () {
    final e = LocalIntentEngine();
    MediaAction? a(String s) { final i = e.parse(s); return i is MediaControlIntent ? i.action : null; }
    test('uh, pause the music', () => expect(a('uh, pause the music.'), MediaAction.pause));
    test('stop the song', () => expect(a('stop the song'), MediaAction.pause));
    test('resume the music', () => expect(a('resume the music'), MediaAction.play));
    test('next song', () => expect(a('next song'), MediaAction.next));
    test('skip this song', () => expect(a('skip this song'), MediaAction.next));
    test('volume up', () => expect(a('volume up'), MediaAction.volumeUp));
    test('plain STOP still stops LEO tasks', () => expect(e.parse('stop'), isA<StopIntent>()));
    test('play pesamale still searches', () => expect(e.parse('play pesamale'), isA<PlayMediaIntent>()));
  });

  group('Wake name LEO is stripped like JARVIS', () {
    final e = LocalIntentEngine();
    test('Leo, stop', () => expect(e.parse('Leo, stop'), isA<StopIntent>()));
    test('Hey Leo, play pesamale', () => expect((e.parse('Hey Leo, play pesamale') as PlayMediaIntent).query, 'pesamale'));
    test('Leo call pavan', () => expect((e.parse('Leo call pavan') as CallIntent).name, 'pavan'));
  });

  group('Sign-in command (local)', () {
    final e = LocalIntentEngine();
    test('sign in to youtube music', () => expect((e.parse('sign in to youtube music') as SignInIntent).appName, 'youtube music'));
    test('Leo, log into Spotify', () => expect((e.parse('Leo, log into Spotify') as SignInIntent).appName, 'Spotify'));
    test('login to my instagram account', () => expect((e.parse('login to my instagram account') as SignInIntent).appName, 'instagram'));
    test('open youtube is not sign-in', () => expect(e.parse('open youtube'), isA<OpenAppIntent>()));
  });
}
