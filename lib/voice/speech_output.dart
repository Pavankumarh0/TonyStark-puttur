import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../data/memory_repository.dart';
import '../data/settings_store.dart';
import 'sarvam_client.dart';

/// Interruptible speech output. Sarvam Bulbul voice when configured; otherwise (or on failure)
/// the phone's own offline TTS voice.
class SpeechOutput extends ChangeNotifier {
  final SettingsStore settings;
  final SarvamClient sarvam;
  final MemoryRepository memory;
  final AudioPlayer _player = AudioPlayer();
  final FlutterTts _tts = FlutterTts();

  bool _speaking = false;
  bool get speaking => _speaking;
  int _generation = 0;
  String? lastError;
  String? lastEngine; // 'sarvam' | 'device'

  SpeechOutput(this.settings, this.sarvam, this.memory) {
    _player.setReleaseMode(ReleaseMode.stop);
    // Speak as an assistant: other audio is ducked (lowered), not stopped.
    _player.setAudioContext(AudioContext(
      android: const AudioContextAndroid(
        usageType: AndroidUsageType.assistant,
        contentType: AndroidContentType.speech,
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
      ),
    ));
    _tts.setLanguage('en-IN');
    _tts.setSpeechRate(0.5);
    _tts.awaitSpeakCompletion(true);
  }

  /// Speaks [text]; completes when finished or when [stop] is called.
  /// [private] text (messages, chats, OTPs, screen contents) is spoken with the phone's own voice only —
  /// it is never sent to a cloud voice service.
  Future<void> speak(String text, {bool private = false}) async {
    final clean = _speakable(text);
    if (clean.isEmpty) return;
    final gen = ++_generation;
    _set(true);
    try {
      final key = settings.secret(SecretKey.sarvam);
      final keepLocal = private && settings.privateVoice;
      if (!keepLocal && !settings.useDeviceTts && key != null && key.isNotEmpty) {
        try {
          await _speakSarvam(clean, key, gen);
          lastEngine = 'sarvam';
          lastError = null;
          return;
        } catch (e) {
          if (gen != _generation) return; // stopped
          lastError = 'Sarvam voice failed, using device voice: $e';
        }
      }
      if (gen != _generation) return;
      lastEngine = 'device';
      await _tts.speak(clean);
    } finally {
      if (gen == _generation) _set(false);
    }
  }

  Future<void> _speakSarvam(String text, String key, int gen) async {
    final chunks = _chunk(text, 450);
    // Pipeline: synthesise the next chunk while the current one plays.
    Future<Uint8List> synth(String c) async {
      try {
        final a = await sarvam.synthesize(
          apiKey: key,
          text: c,
          model: settings.sarvamTtsModel,
          speaker: settings.sarvamSpeaker,
          pace: settings.ttsPace,
        );
        unawaited(memory.logVoiceUsage('tts', c.length.toDouble(), true));
        return a;
      } catch (e) {
        unawaited(memory.logVoiceUsage('tts', c.length.toDouble(), false));
        rethrow;
      }
    }

    Future<Uint8List>? next = synth(chunks.first);
    for (var i = 0; i < chunks.length; i++) {
      final audio = await next!;
      if (gen != _generation) return;
      next = i + 1 < chunks.length ? synth(chunks[i + 1]) : null;
      final done = Completer<void>();
      late final StreamSubscription sub;
      sub = _player.onPlayerStateChanged.listen((s) {
        if (s == PlayerState.completed || s == PlayerState.stopped) {
          if (!done.isCompleted) done.complete();
        }
      });
      await _player.play(BytesSource(audio, mimeType: 'audio/wav'));
      await done.future;
      await sub.cancel();
      if (gen != _generation) return;
    }
  }

  /// Interrupts speech immediately.
  Future<void> stop() async {
    _generation++;
    sarvam.cancelInFlight();
    await _player.stop();
    await _tts.stop();
    _set(false);
  }

  void _set(bool v) {
    if (_speaking == v) return;
    _speaking = v;
    notifyListeners();
  }

  static String _speakable(String t) => t
      .replaceAll(RegExp(r'[*_#`>|]'), '')
      .replaceAll(RegExp(r'\[(.*?)\]\(.*?\)'), r'$1')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static List<String> _chunk(String text, int max) {
    if (text.length <= max) return [text];
    final sentences = RegExp(r'[^.!?]+[.!?]*\s*').allMatches(text).map((m) => m.group(0)!).toList();
    final out = <String>[];
    var cur = StringBuffer();
    for (final s in sentences) {
      if (cur.length + s.length > max && cur.isNotEmpty) {
        out.add(cur.toString().trim());
        cur = StringBuffer();
      }
      if (s.length > max) {
        for (var i = 0; i < s.length; i += max) {
          out.add(s.substring(i, i + max > s.length ? s.length : i + max));
        }
      } else {
        cur.write(s);
      }
    }
    if (cur.isNotEmpty) out.add(cur.toString().trim());
    return out.where((c) => c.isNotEmpty).toList();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
