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
  /// [languageCode] (en-IN, hi-IN, kn-IN) picks the voice's language — LEO answers in the language you spoke.
  Future<void> speak(String text, {bool private = false, String languageCode = 'en-IN'}) async {
    final clean = _speakable(text);
    if (clean.isEmpty) return;
    final gen = ++_generation;
    _set(true);
    try {
      final key = settings.secret(SecretKey.sarvam);
      final keepLocal = private && settings.privateVoice;
      if (!keepLocal && !settings.useDeviceTts && key != null && key.isNotEmpty) {
        try {
          await _speakSarvam(clean, key, gen, languageCode);
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
      if (languageCode != _deviceLang) {
        // Fall back to English if the phone has no voice for this language.
        final ok = await _tts.isLanguageAvailable(languageCode) == true;
        await _tts.setLanguage(ok ? languageCode : 'en-IN');
        _deviceLang = ok ? languageCode : 'en-IN';
      }
      await _tts.speak(clean);
    } finally {
      if (gen == _generation) _set(false);
    }
  }

  String _deviceLang = 'en-IN';

  // Recently spoken audio, so phrases LEO says often ("Anything else, sir?", "WhatsApp is open") play
  // instantly instead of waiting ~1 s for synthesis. Short, non-private lines only; memory only.
  final _audioCache = <String, Uint8List>{}; // insertion-ordered: oldest first
  static const _cacheMaxEntries = 40;
  static const _cacheMaxChars = 220;

  /// Bumped by [stop]; lets callers drop speech that was queued before an interruption.
  int stopCount = 0;

  Future<void> _speakSarvam(String text, String key, int gen, String languageCode) async {
    final chunks = chunkForSpeech(text, 450);
    // Pipeline: synthesise the next chunk while the current one plays.
    Future<Uint8List> synth(String c) async {
      final cacheKey = '${settings.sarvamTtsModel}|${settings.sarvamSpeaker}|${settings.ttsPace}|$languageCode|$c';
      final hit = _audioCache.remove(cacheKey);
      if (hit != null) {
        _audioCache[cacheKey] = hit; // most recently used
        return hit;
      }
      try {
        final a = await sarvam.synthesize(
          apiKey: key,
          text: c,
          model: settings.sarvamTtsModel,
          speaker: settings.sarvamSpeaker,
          languageCode: languageCode,
          pace: settings.ttsPace,
        );
        unawaited(memory.logVoiceUsage('tts', c.length.toDouble(), true));
        if (c.length <= _cacheMaxChars) {
          _audioCache[cacheKey] = a;
          while (_audioCache.length > _cacheMaxEntries) {
            _audioCache.remove(_audioCache.keys.first);
          }
        }
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
    stopCount++;
    sarvam.cancelSpeech();
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

  /// Splits [text] for synthesis. A long reply's first sentence goes alone (when short), so playback
  /// starts sooner; the rest is synthesised while it plays.
  static List<String> chunkForSpeech(String text, int max) {
    final parts = _chunk(text, max);
    if (parts.length == 1 && text.length <= 200) return parts;
    final m = RegExp(r'^.{20,180}?[.!?।](\s|$)').firstMatch(text);
    if (m == null) return parts;
    final first = m.group(0)!.trim();
    final rest = text.substring(m.end).trim();
    return rest.isEmpty ? [first] : [first, ..._chunk(rest, max)];
  }

  static List<String> _chunk(String text, int max) {
    if (text.length <= max) return [text];
    final sentences = RegExp(r'[^.!?।]+[.!?।]*\s*').allMatches(text).map((m) => m.group(0)!).toList();
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
