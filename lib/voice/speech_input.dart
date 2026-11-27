import 'dart:async';

import '../data/memory_repository.dart';
import '../data/settings_store.dart';
import 'language.dart';
import 'mic_engine.dart';
import 'sarvam_client.dart';
import 'wav.dart';

class SpeechInputException implements Exception {
  final String message;
  SpeechInputException(this.message);
  @override
  String toString() => message;
}

/// Captures one utterance from the shared mic and transcribes it with Sarvam Saaras (en-IN).
class SpeechInput {
  final MicEngine mic;
  final SarvamClient sarvam;
  final SettingsStore settings;
  final MemoryRepository memory;

  /// Names that improve recognition (contacts mentioned recently, app names, …).
  final Set<String> keyterms = {'Leo', 'WhatsApp', 'WhatsApp Business', 'YouTube'};

  SpeechInput(this.mic, this.sarvam, this.settings, this.memory);

  /// Language of the conversation, from the last utterance (en-IN, hi-IN or kn-IN).
  String lastLanguage = Lang.english;
  String? lastDetected;
  double? lastProbability;

  bool get isConfigured => settings.hasSecret(SecretKey.sarvam);

  /// Returns the transcript, or null when nobody spoke.
  Future<String?> listenOnce({
    Duration noSpeechTimeout = const Duration(seconds: 6),
    void Function()? onSpeechCaptured,
  }) async {
    final key = settings.secret(SecretKey.sarvam);
    if (key == null || key.isEmpty) {
      throw SpeechInputException('Sarvam API key is not set. Add it in Settings to use voice input.');
    }
    final samples = await mic.captureUtterance(noSpeechTimeout: noSpeechTimeout);
    if (samples == null) return null;
    onSpeechCaptured?.call();
    final seconds = samples.length / MicEngine.sampleRate;
    try {
      final r = await sarvam.transcribeDetailed(
        apiKey: key,
        wav: encodeWav(samples, sampleRate: MicEngine.sampleRate),
        model: settings.sarvamSttModel,
        // Mixed-language mode: Hindi/Kannada/code-mixed speech is translated to English text, so all of
        // LEO's command handling works unchanged — and Sarvam tells us which language was spoken.
        languageCode: settings.mixedLanguage ? 'unknown' : 'en-IN',
        mode: settings.mixedLanguage ? 'translate' : 'transcribe',
        keyterms: keyterms.toList(),
      );
      unawaited(memory.logVoiceUsage('stt', seconds, true));
      if (r.text.isEmpty) return null;
      lastDetected = r.languageCode;
      lastProbability = r.probability;
      lastLanguage = settings.mixedLanguage ? Lang.pick(r.languageCode, r.probability, previous: lastLanguage) : Lang.english;
      return r.text;
    } catch (e) {
      unawaited(memory.logVoiceUsage('stt', seconds, false));
      rethrow;
    }
  }

  void cancel() {
    mic.cancelCapture();
    sarvam.cancelInFlight();
  }
}
