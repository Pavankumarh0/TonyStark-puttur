import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:porcupine_flutter/porcupine.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'jarvis_keywords.dart';

/// An on-device wake-word detector fed with 16 kHz, 16-bit mono frames from [MicEngine].
/// Nothing here touches the network.
abstract class WakeWordDetector {
  String get name;
  Future<void> init();

  /// Returns true when "Jarvis" was detected in this frame.
  Future<bool> process(List<int> frame);
  Future<void> dispose();
}

/// FREE, open-source (Apache-2.0), no account or key: sherpa-onnx streaming keyword spotter
/// with a 3.3M-parameter English zipformer model bundled in the APK (assets/kws).
/// Open vocabulary: the keyword is the BPE spelling of "JARVIS" (▁JA R VI S).
class SherpaWakeWord implements WakeWordDetector {
  final double sensitivity; // 0.3 … 0.9, higher = triggers more easily
  SherpaWakeWord({this.sensitivity = 0.6});

  sherpa.KeywordSpotter? _spotter;
  sherpa.OnlineStream? _stream;

  @override
  String get name => 'sherpa-onnx (free, on-device)';

  static const _assets = ['encoder.int8.onnx', 'decoder.onnx', 'joiner.int8.onnx', 'tokens.txt'];

  /// Native code needs real file paths, so the bundled model is copied out of the APK once.
  static Future<String> _modelDir() async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/kws_v2'); // v2: full gigaspeech model (the -mobile export crashes)
    if (!dir.existsSync()) dir.createSync(recursive: true);
    for (final a in _assets) {
      final f = File('${dir.path}/$a');
      if (!f.existsSync() || f.lengthSync() == 0) {
        final data = await rootBundle.load('assets/kws/$a');
        await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      }
    }
    return dir.path;
  }

  @override
  Future<void> init() async {
    sherpa.initBindings();
    final dir = await _modelDir();
    // Lower threshold = more sensitive. Sensitivity 0.6 → ~0.12 (validated offline: good recall,
    // no false triggers on non-Jarvis speech). Many BPE spellings of JARVIS improve recall.
    final threshold = (0.25 - sensitivity * 0.22).clamp(0.04, 0.22);
    final keywords = File('$dir/keywords.txt');
    await keywords.writeAsString(
      jarvisTokenVariants.map((v) => '$v :2.0 #${threshold.toStringAsFixed(3)} @JARVIS').join('\n'),
    );
    final config = sherpa.KeywordSpotterConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: '$dir/encoder.int8.onnx',
          decoder: '$dir/decoder.onnx',
          joiner: '$dir/joiner.int8.onnx',
        ),
        tokens: '$dir/tokens.txt',
        numThreads: 1,
        debug: false,
      ),
      keywordsFile: keywords.path,
      keywordsScore: 2.0,
      keywordsThreshold: threshold,
      numTrailingBlanks: 1,
    );
    _spotter = sherpa.KeywordSpotter(config);
    _stream = _spotter!.createStream();
  }

  @override
  Future<bool> process(List<int> frame) async {
    final s = _spotter;
    final st = _stream;
    if (s == null || st == null) return false;
    final f = Float32List(frame.length);
    for (var i = 0; i < frame.length; i++) {
      f[i] = frame[i] / 32768.0;
    }
    st.acceptWaveform(samples: f, sampleRate: 16000);
    var hit = false;
    while (s.isReady(st)) {
      s.decode(st);
      if (s.getResult(st).keyword.isNotEmpty) {
        hit = true;
        s.reset(st); // required after a detection
      }
    }
    return hit;
  }

  @override
  Future<void> dispose() async {
    _stream?.free();
    _spotter?.free();
    _stream = null;
    _spotter = null;
  }
}

/// Optional: Picovoice Porcupine built-in "Jarvis" (needs a free Picovoice AccessKey).
class PorcupineWakeWord implements WakeWordDetector {
  final String accessKey;
  final double sensitivity;
  PorcupineWakeWord(this.accessKey, {this.sensitivity = 0.6});
  Porcupine? _p;

  @override
  String get name => 'Porcupine (on-device)';

  @override
  Future<void> init() async {
    _p = await Porcupine.fromBuiltInKeywords(accessKey, [BuiltInKeyword.JARVIS],
        sensitivities: [sensitivity.clamp(0.1, 0.95)]);
  }

  @override
  Future<bool> process(List<int> frame) async => (await _p?.process(frame) ?? -1) >= 0;

  @override
  Future<void> dispose() async {
    await _p?.delete();
    _p = null;
  }
}

String describeWakeError(Object e) {
  if (e is PlatformException) return e.message ?? e.code;
  final s = e.toString();
  return s.length > 200 ? '${s.substring(0, 200)}…' : s;
}
