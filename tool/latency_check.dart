// Measures LEO's network legs with the app's own clients (needs SARVAM_API_KEY in lib/.env):
// speech-to-text on a cold vs warmed connection, and voice synthesis with vs without the cache.
//   dart run tool/latency_check.dart
import 'dart:io';

import 'package:jarvis/voice/sarvam_client.dart';

String _key(String name) => File('lib/.env')
    .readAsLinesSync()
    .map((l) => RegExp(r'^\s*' + name + r'\s*=\s*(\S+)').firstMatch(l)?.group(1))
    .whereType<String>()
    .first
    .replaceAll(RegExp('''["']'''), '');

Future<int> _time(Future<void> Function() f) async {
  final sw = Stopwatch()..start();
  await f();
  return sw.elapsedMilliseconds;
}

Future<void> main() async {
  final key = _key('SARVAM_API_KEY');
  // A real spoken command, made with Bulbul (22.05 kHz WAV).
  final wav = await SarvamClient().synthesize(apiKey: key, text: 'Send a WhatsApp message to Rahul that I am running late.');
  final cold = <int>[], warm = <int>[];
  for (var i = 0; i < 3; i++) {
    final c = SarvamClient(); // new client = new connection, like before (stop() dropped it)
    cold.add(await _time(() => c.transcribe(apiKey: key, wav: wav)));
    final w = SarvamClient();
    w.warmUp(); // done while the user is speaking (~1-2 s before the request)
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    warm.add(await _time(() => w.transcribe(apiKey: key, wav: wav)));
  }
  final ttsClient = SarvamClient();
  final ttsMs = await _time(() => ttsClient.synthesize(apiKey: key, text: 'Anything else, sir?'));
  String avg(List<int> l) => '${(l.reduce((a, b) => a + b) / l.length).round()} ms';
  stdout.writeln('speech-to-text, cold connection : ${avg(cold)}   $cold');
  stdout.writeln('speech-to-text, warmed          : ${avg(warm)}   $warm');
  stdout.writeln('voice line, synthesised         : $ttsMs ms  (cached repeat: ~0 ms)');
  stdout.writeln('test audio: ${(wav.length / 1024).round()} KB');
  exit(0);
}
