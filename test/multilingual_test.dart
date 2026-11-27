import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/intent/local_intent.dart';
import 'package:jarvis/core/intent/local_intent_engine.dart';
import 'package:jarvis/orchestrator/jarvis_orchestrator.dart';
import 'package:jarvis/voice/language.dart';
import 'package:jarvis/voice/sarvam_client.dart';

/// Records what was sent for translation; "translates" by tagging the text.
class FakeSarvam extends SarvamClient {
  final sent = <String>[];
  bool fail = false;
  @override
  Future<String> translate(
      {required String apiKey, required String text, required String source, required String target, String model = 'mayura:v1', String mode = 'modern-colloquial'}) async {
    if (fail) throw SarvamException('down');
    sent.add(text);
    return '[$target] $text';
  }
}

void main() {
  group('language detection', () {
    test('a confident Kannada / Hindi / English detection sets the reply language', () {
      expect(Lang.pick('kn-IN', 0.87, previous: Lang.english), Lang.kannada);
      expect(Lang.pick('hi-IN', 0.99, previous: Lang.kannada), Lang.hindi);
      expect(Lang.pick('en-IN', 0.99, previous: Lang.hindi), Lang.english);
    });

    test('low confidence or unsupported languages keep the conversation language', () {
      expect(Lang.pick('kn-IN', 0.4, previous: Lang.hindi), Lang.hindi);
      expect(Lang.pick('hi-IN', 0.56, previous: Lang.english), Lang.hindi); // real score for a short Hindi command // e.g. a one-word "ok"
      expect(Lang.pick('ta-IN', 0.99, previous: Lang.english), Lang.english);
      expect(Lang.pick(null, null, previous: Lang.kannada), Lang.kannada);
    });

    test('an unsure Gujarati/Marathi/Punjabi score on a short Hindi command counts as Hindi', () {
      expect(Lang.pick('gu-IN', 0.75, previous: Lang.english), Lang.hindi); // "फ्लैशलाइट चालू करो" (real result)
      expect(Lang.pick('gu-IN', 0.97, previous: Lang.english), Lang.english); // confident Gujarati → not guessed
    });

    test('typed text: language from its script', () {
      expect(Lang.ofScript('ಅಮ್ಮನಿಗೆ ಕರೆ ಮಾಡು'), Lang.kannada);
      expect(Lang.ofScript('कल सुबह अलार्म लगा दो'), Lang.hindi);
      expect(Lang.ofScript('YouTube ನಲ್ಲಿ ಹಾಡು ಪ್ಲೇ ಮಾಡು'), Lang.kannada); // mixed
      expect(Lang.ofScript('set an alarm for 6'), isNull); // English → unchanged path
      expect(Lang.ofScript('Rahul ko message karo'), isNull); // romanised Hinglish typed → English path (LLM handles it)
    });
  });

  group('contacts after translation', () {
    test('relation words map to how contacts are saved', () {
      expect(Lang.relationAliases('mother'), containsAll(['amma', 'mummy', 'maa', 'mom']));
      expect(Lang.relationAliases('my father'), containsAll(['appa', 'papa', 'dad']));
      expect(Lang.relationAliases('Rahul'), isEmpty);
    });

    test('alias must be a whole word of the contact name', () {
      expect(JarvisOrchestrator.nameHasWord('Amma', 'amma'), isTrue);
      expect(JarvisOrchestrator.nameHasWord('Amma Home', 'amma'), isTrue);
      expect(JarvisOrchestrator.nameHasWord('Kamma Reddy', 'amma'), isFalse);
      expect(JarvisOrchestrator.nameHasWord('Papa Jio', 'papa'), isTrue);
    });
  });

  group('existing command engine on Sarvam\'s translations (real outputs, saaras:v4)', () {
    final engine = LocalIntentEngine();
    // Kannada "ಅಮ್ಮನಿಗೆ ಕರೆ ಮಾಡು"
    test('"Call mother."', () {
      final i = engine.parse('Call mother.');
      expect(i, isA<CallIntent>());
      expect((i as CallIntent).name.toLowerCase(), 'mother');
    });
    // Hindi "कल सुबह छह बजे का अलार्म लगा दो"
    test('"Set an alarm for 6:00 AM tomorrow morning."', () {
      expect(engine.parse('Set an alarm for 6:00 AM tomorrow morning.'), isA<SetAlarmIntent>());
    });
    // Hinglish "Rahul ko WhatsApp pe message karo ki main late hoon"
    test('"Message Rahul on WhatsApp that I am late."', () {
      final i = engine.parse('Message Rahul on WhatsApp that I am late.');
      expect(i, isA<SendMessageIntent>());
      expect((i as SendMessageIntent).message?.toLowerCase(), contains('late'));
    });
    // Kanglish "YouTube ನಲ್ಲಿ ಹಾಡು ಪ್ಲೇ ಮಾಡು" (no song named) arrives as "Play the song on YouTube." —
    // LEO's existing English handling treats that as resume-playback, same as if said in English.
    test('"Play the song on YouTube." behaves exactly like the English command', () {
      expect(engine.parse('Play the song on YouTube.').runtimeType, engine.parse('play the song on youtube').runtimeType);
    });
    test('English is unchanged: "Set an alarm for 6:30 in the morning."', () {
      expect(engine.parse('Set an alarm for 6:30 in the morning.'), isA<SetAlarmIntent>());
    });
  });

  group('reply translation', () {
    test('English replies are not sent anywhere', () async {
      final f = FakeSarvam();
      final t = ReplyTranslator(f, () => 'k');
      expect(await t.toLanguage('Done, sir.', Lang.english), 'Done, sir.');
      expect(f.sent, isEmpty);
    });

    test('quoted message text is never translated (you approve what is really sent)', () async {
      final f = FakeSarvam();
      final t = ReplyTranslator(f, () => 'k');
      final out = await t.toLanguage('Shall I send “see you at 5” to Rahul, sir?', Lang.kannada);
      expect(out, contains('“see you at 5”'));
      expect(f.sent.join('|'), isNot(contains('see you at 5')));
      expect(out, contains('[kn-IN] Shall I send'));
    });

    test('repeated phrases come from the cache', () async {
      final f = FakeSarvam();
      final t = ReplyTranslator(f, () => 'k');
      await t.toLanguage('Anything else, sir?', Lang.hindi);
      await t.toLanguage('Anything else, sir?', Lang.hindi);
      expect(f.sent.length, 1);
    });

    test('translation failure → the English reply (never silence)', () async {
      final f = FakeSarvam()..fail = true;
      final t = ReplyTranslator(f, () => 'k');
      expect(await t.toLanguage('Calling Amma, sir.', Lang.kannada), 'Calling Amma, sir.');
    });
  });

  test('terse status lines are said in full only for translation; English is untouched', () {
    expect(ReplyTranslator.forTranslation('Alarm set for 7:00 AM tomorrow, sir.'), 'I have set an alarm for 7:00 AM tomorrow, sir.');
    expect(ReplyTranslator.forTranslation('Flashlight on.'), 'I have turned the flashlight on.');
    expect(ReplyTranslator.forTranslation('Calling Amma, sir.'), 'Calling Amma, sir.');
  });
}
