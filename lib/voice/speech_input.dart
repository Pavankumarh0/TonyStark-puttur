import 'dart:async';

import '../data/memory_repository.dart';
import '../data/settings_store.dart';
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
  final Set<String> keyterms = {'JARVIS', 'WhatsApp', 'WhatsApp Business'};

  SpeechInput(this.mic, this.sarvam, this.settings, this.memory);

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
      final text = await sarvam.transcribe(
        apiKey: key,
        wav: encodeWav(samples, sampleRate: MicEngine.sampleRate),
        model: settings.sarvamSttModel,
        keyterms: keyterms.toList(),
      );
      unawaited(memory.logVoiceUsage('stt', seconds, true));
      return text.isEmpty ? null : text;
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
