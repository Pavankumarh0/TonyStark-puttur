// Live end-to-end check of multilingual voice (uses the real Sarvam APIs; needs SARVAM_API_KEY in lib/.env):
//   real Kannada/Hindi/mixed speech (Bulbul) → Saaras detect + translate → LEO's own command engine →
//   reply translated back (Mayura) → spoken in that language (Bulbul).
//   dart run tool/multilingual_check.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:jarvis/core/intent/local_intent_engine.dart';
import 'package:jarvis/voice/language.dart';
import 'package:jarvis/voice/sarvam_client.dart';

Future<void> main() async {
  final key = File('lib/.env')
      .readAsLinesSync()
      .map((l) => RegExp(r'^\s*SARVAM_API_KEY\s*=\s*(\S+)').firstMatch(l)?.group(1))
      .whereType<String>()
      .first
      .replaceAll(RegExp('''["']'''), '');
  final sarvam = SarvamClient();
  final engine = LocalIntentEngine();
  final tr = ReplyTranslator(SarvamClient(), () => key);

  // (spoken language, what the user says, LEO's English reply for that command)
  const cases = [
    ('kn-IN', 'ಅಮ್ಮನಿಗೆ ಕರೆ ಮಾಡು', 'Calling Amma, sir.'),
    ('kn-IN', 'ನಾಳೆ ಬೆಳಿಗ್ಗೆ ಏಳು ಗಂಟೆಗೆ ಅಲಾರಾಂ ಇಡು', 'Alarm set for 7:00 AM tomorrow, sir.'),
    ('kn-IN', 'YouTube ನಲ್ಲಿ ಕೇಸರಿಯಾ ಹಾಡು ಪ್ಲೇ ಮಾಡು', 'Playing Kesariya on YouTube, sir.'),
    ('kn-IN', 'WhatsApp ಓಪನ್ ಮಾಡು', 'WhatsApp is open, sir. What next?'),
    ('hi-IN', 'कल सुबह छह बजे का अलार्म लगा दो', 'Alarm set for 6:00 AM tomorrow, sir.'),
    ('hi-IN', 'Rahul ko WhatsApp pe message karo ki main late hoon', 'Shall I send “I am late” to Rahul on WhatsApp, sir?'),
    ('hi-IN', 'फ्लैशलाइट चालू करो', 'Flashlight on.'),
    ('hi-IN', 'Instagram kholo', 'Instagram is open, sir. What next?'),
    ('en-IN', 'Set an alarm for six thirty in the morning', 'Alarm set for 6:30 AM, sir.'),
  ];

  var pass = 0;
  for (final (lang, said, reply) in cases) {
    final wav = await _tts(key, said, lang);
    final sw = Stopwatch()..start();
    final stt = await sarvam.transcribeDetailed(apiKey: key, wav: wav, model: 'saaras:v4', languageCode: 'unknown', mode: 'translate');
    final sttMs = sw.elapsedMilliseconds;
    final replyLang = Lang.pick(stt.languageCode, stt.probability, previous: Lang.english);
    final intent = engine.parse(stt.text);
    sw.reset();
    final answer = await tr.toLanguage(reply, replyLang);
    final trMs = sw.elapsedMilliseconds;
    sw.reset();
    final voice = await sarvam.synthesize(apiKey: key, text: answer, languageCode: replyLang);
    final ttsMs = sw.elapsedMilliseconds;
    final ok = replyLang == lang && intent.runtimeType.toString() != 'UnknownIntent' && voice.length > 1000 &&
        (lang == Lang.english ? answer == reply : answer != reply);
    if (ok) pass++;
    stdout.writeln('${ok ? 'PASS' : 'FAIL'}  [$lang] "$said"');
    stdout.writeln('      heard: ${stt.languageCode} (${stt.probability?.toStringAsFixed(2)}) → "${stt.text}"  [$sttMs ms]');
    stdout.writeln('      intent: ${intent.runtimeType}');
    stdout.writeln('      reply ($replyLang): "$answer"  [translate $trMs ms, voice $ttsMs ms, ${voice.length ~/ 1024} KB audio]');
  }
  stdout.writeln('\n$pass/${cases.length} passed');
  exit(pass == cases.length ? 0 : 1);
}

Future<Uint8List> _tts(String key, String text, String lang) async {
  final r = await http.post(Uri.parse('https://api.sarvam.ai/text-to-speech'),
      headers: {'api-subscription-key': key, 'Content-Type': 'application/json'},
      body: jsonEncode({'text': text, 'target_language_code': lang, 'model': 'bulbul:v3', 'speaker': 'shubh', 'speech_sample_rate': 16000}));
  return base64Decode(((jsonDecode(r.body) as Map)['audios'] as List).first as String);
}
