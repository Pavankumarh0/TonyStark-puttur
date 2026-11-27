import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_voice_processor/flutter_voice_processor.dart';

import 'wake_word.dart';

enum WakeWordStatus { off, starting, armed, error }

/// One microphone pipeline (16 kHz, 512-sample frames) shared by:
///  * Porcupine — offline "Jarvis" wake word (audio never leaves the device), and
///  * the utterance recorder — energy-based voice activity detection that captures one command.
/// Using one AudioRecord avoids mic hand-off races and allows "Jarvis" barge-in while speaking.
class MicEngine extends ChangeNotifier {
  static const sampleRate = 16000;
  static const frameLength = 512; // Porcupine frame length at 16 kHz
  static const _framesPerSecond = sampleRate / frameLength; // ≈31.25

  final VoiceProcessor _vp = VoiceProcessor.instance!;
  WakeWordDetector? _detector;
  Future<void> _detectorChain = Future.value();
  String? get wakeEngineName => _detector?.name;

  bool _running = false;
  bool get running => _running;

  WakeWordStatus _wakeStatus = WakeWordStatus.off;
  String? _wakeError;
  WakeWordStatus get wakeStatus => _wakeStatus;
  String? get wakeError => _wakeError;

  /// Called on the platform thread's event loop when "Jarvis" is detected.
  VoidCallback? onWake;
  bool wakeSuppressed = false;

  final _level = StreamController<double>.broadcast();
  Stream<double> get level => _level.stream;
  double _lastLevel = 0;
  double get lastLevel => _lastLevel;

  final ListQueue<List<int>> _preRoll = ListQueue();
  static const _preRollFrames = 10; // ≈320 ms kept so the first syllable is not cut off
  _Capture? _capture;
  double _noiseFloor = 300;
  String? lastError;

  MicEngine() {
    _vp.addFrameListener(_onFrame);
    _vp.addErrorListener((e) {
      lastError = e.message;
      notifyListeners();
    });
  }

  Future<bool> hasPermission() async => (await _vp.hasRecordAudioPermission()) ?? false;

  /// Starts the shared microphone stream. Requires RECORD_AUDIO.
  Future<void> start() async {
    if (_running) return;
    await _vp.start(frameLength, sampleRate);
    _running = (await _vp.isRecording()) ?? true;
    notifyListeners();
  }

  Future<void> stop() async {
    _capture?.finish(null);
    _capture = null;
    if (_running) await _vp.stop();
    _running = false;
    _level.add(0);
    notifyListeners();
  }

  /// Arms the offline wake word. Uses Porcupine if a Picovoice key is supplied, otherwise the
  /// free sherpa-onnx keyword spotter. Returns an error description, or null on success.
  Future<String?> enableWakeWord({String? picovoiceKey, double sensitivity = 0.6}) async {
    if (_detector != null) {
      _wakeStatus = WakeWordStatus.armed;
      notifyListeners();
      return null;
    }
    _wakeStatus = WakeWordStatus.starting;
    notifyListeners();
    WakeWordDetector d = (picovoiceKey != null && picovoiceKey.isNotEmpty)
        ? PorcupineWakeWord(picovoiceKey, sensitivity: sensitivity)
        : SherpaWakeWord(sensitivity: sensitivity);
    try {
      await d.init();
    } catch (e) {
      if (d is PorcupineWakeWord) {
        // Fall back to the free engine if the Picovoice key is invalid/expired.
        d = SherpaWakeWord(sensitivity: sensitivity);
        try {
          await d.init();
        } catch (e2) {
          return _fail(e2);
        }
      } else {
        return _fail(e);
      }
    }
    _detector = d;
    _wakeStatus = WakeWordStatus.armed;
    _wakeError = null;
    notifyListeners();
    return null;
  }

  String _fail(Object e) {
    _wakeStatus = WakeWordStatus.error;
    _wakeError = describeWakeError(e);
    notifyListeners();
    return _wakeError!;
  }

  Future<void> disableWakeWord() async {
    final d = _detector;
    _detector = null;
    await _detectorChain;
    await d?.dispose();
    _wakeStatus = WakeWordStatus.off;
    notifyListeners();
  }

  bool get isCapturing => _capture != null;

  /// Records one spoken utterance using voice activity detection.
  /// Returns null if nobody spoke before [noSpeechTimeout] or the capture was cancelled.
  Future<List<int>?> captureUtterance({
    Duration noSpeechTimeout = const Duration(seconds: 6),
    Duration maxDuration = const Duration(seconds: 15),
    Duration endSilence = const Duration(milliseconds: 900),
  }) async {
    if (!_running) await start();
    _capture?.finish(null);
    final c = _Capture(
      noSpeechFrames: (noSpeechTimeout.inMilliseconds / 1000 * _framesPerSecond).round(),
      maxFrames: (maxDuration.inMilliseconds / 1000 * _framesPerSecond).round(),
      endSilenceFrames: (endSilence.inMilliseconds / 1000 * _framesPerSecond).round(),
    );
    _capture = c;
    notifyListeners();
    final r = await c.done.future;
    if (identical(_capture, c)) _capture = null;
    notifyListeners();
    return r;
  }

  void cancelCapture() {
    _capture?.finish(null);
    _capture = null;
    notifyListeners();
  }

  void _onFrame(List<int> frame) {
    // RMS energy for level meter and VAD.
    var sum = 0.0;
    for (final s in frame) {
      sum += s * s;
    }
    final rms = sqrt(sum / frame.length);
    final lvl = (rms / 3500).clamp(0.0, 1.0);
    _lastLevel = lvl;
    _level.add(lvl);

    final c = _capture;
    if (c != null && !captureMuted) {
      _feedCapture(c, frame, rms);
    } else {
      if (c != null) _feedCapture(c, frame, rms);
      // Track ambient noise while idle so thresholds adapt to the room.
      _noiseFloor = _noiseFloor * 0.98 + min(rms, 2500) * 0.02;
      final d = _detector;
      if (d != null && !wakeSuppressed && onWake != null) {
        _detectorChain = _detectorChain.then((_) async {
          if (!identical(_detector, d)) return; // disabled meanwhile
          try {
            final hit = await d.process(frame);
            if (hit && (_capture == null || captureMuted)) onWake?.call();
          } catch (_) {}
        });
      }
    }

    _preRoll.addLast(frame);
    while (_preRoll.length > _preRollFrames) {
      _preRoll.removeFirst();
    }
  }

  /// While JARVIS is speaking, the recorder ignores audio so it never transcribes its own voice.
  /// (The wake word stays active so "Jarvis" can still barge in.)
  bool captureMuted = false;

  void _feedCapture(_Capture c, List<int> frame, double rms) {
    if (captureMuted) {
      if (!c.speechStarted) c.frames = 0; // don't time out while we are talking
      return;
    }
    final start = max(_noiseFloor * 2.6, 420.0);
    final end = max(_noiseFloor * 1.8, 300.0);
    c.frames++;
    if (!c.speechStarted) {
      if (rms > start) {
        c.loudStreak++;
        if (c.loudStreak >= 2) {
          c.speechStarted = true;
          for (final f in _preRoll) {
            c.samples.addAll(f);
          }
        }
      } else {
        c.loudStreak = 0;
        _noiseFloor = _noiseFloor * 0.95 + min(rms, 2500) * 0.05;
      }
      if (c.frames >= c.noSpeechFrames && !c.speechStarted) {
        c.finish(null);
        _capture = null;
        notifyListeners();
      }
      return;
    }
    c.samples.addAll(frame);
    c.speechFrames++;
    c.silentStreak = rms < end ? c.silentStreak + 1 : 0;
    if (c.silentStreak >= c.endSilenceFrames || c.speechFrames >= c.maxFrames) {
      // Need at least ~250 ms of speech to be worth transcribing.
      c.finish(c.speechFrames > 8 ? List<int>.from(c.samples) : null);
      _capture = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _vp.removeFrameListener(_onFrame);
    _detector?.dispose();
    _level.close();
    super.dispose();
  }
}

class _Capture {
  final int noSpeechFrames;
  final int maxFrames;
  final int endSilenceFrames;
  final done = Completer<List<int>?>();
  final List<int> samples = [];
  int frames = 0;
  int speechFrames = 0;
  int loudStreak = 0;
  int silentStreak = 0;
  bool speechStarted = false;

  _Capture({required this.noSpeechFrames, required this.maxFrames, required this.endSilenceFrames});

  void finish(List<int>? r) {
    if (!done.isCompleted) done.complete(r);
  }
}
