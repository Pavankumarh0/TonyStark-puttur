import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SecretKey { gemini, sarvam, picovoice, openai }

/// Non-secret preferences in SharedPreferences; API keys in Android Keystore-backed secure storage.
/// Keys are never written to source code or logs.
class SettingsStore extends ChangeNotifier {
  static const _secure = FlutterSecureStorage();
  late SharedPreferences _prefs;
  final Map<SecretKey, String> _secrets = {};

  /// Keys compiled into the APK at build time from the gitignored secrets.json
  /// (`flutter build apk --dart-define-from-file=secrets.json`). Never in source code.
  static const Map<SecretKey, String> _builtIn = {
    SecretKey.gemini: String.fromEnvironment('GEMINI_API_KEY'),
    SecretKey.sarvam: String.fromEnvironment('SARVAM_API_KEY'),
    SecretKey.picovoice: String.fromEnvironment('PICOVOICE_ACCESS_KEY'),
    SecretKey.openai: String.fromEnvironment('OPENAI_API_KEY'),
  };
  static const _builtInModel = String.fromEnvironment('GEMINI_MODEL');

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    // Optional on-device overrides (Settings). Built-in keys are used when no override exists.
    for (final k in SecretKey.values) {
      final v = _clean(await _secure.read(key: 'secret_${k.name}'));
      if (v.isNotEmpty) _secrets[k] = v;
    }
  }

  String? secret(SecretKey k) {
    final o = _secrets[k];
    if (o != null && o.isNotEmpty) return o;
    // First word only: tolerates notes written after the key on the same .env line.
    final b = _clean(_builtIn[k]);
    return b.isEmpty ? null : b;
  }

  /// API keys never contain spaces/quotes: keep only the first word so pasted notes are ignored.
  static String _clean(String? raw) =>
      (raw ?? '').trim().replaceAll(RegExp(r'''^["']|["']$'''), '').split(RegExp(r'\s+')).first;

  bool hasSecret(SecretKey k) => (secret(k) ?? '').isNotEmpty;
  bool isBuiltIn(SecretKey k) => !(_secrets[k]?.isNotEmpty ?? false) && _builtIn[k]!.isNotEmpty;

  String maskedSecret(SecretKey k) {
    final v = secret(k);
    if (v == null || v.isEmpty) return 'Not set — add it to lib/.env and rebuild';
    final m = v.length <= 6 ? '••••' : '••••${v.substring(v.length - 4)}';
    return isBuiltIn(k) ? '$m (built into app)' : '$m (override set on phone)';
  }

  Future<void> setSecret(SecretKey k, String? value) async {
    final v = _clean(value);
    if (v.isEmpty) {
      _secrets.remove(k);
      await _secure.delete(key: 'secret_${k.name}');
    } else {
      _secrets[k] = v;
      await _secure.write(key: 'secret_${k.name}', value: v);
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ preferences
  String get address => _prefs.getString('address') ?? 'sir';
  set address(String v) => _set('address', v.trim().isEmpty ? 'sir' : v.trim());

  String get geminiModel =>
      _prefs.getString('gemini_model') ?? (_builtInModel.isNotEmpty ? _builtInModel : 'gemini-2.5-flash');
  set geminiModel(String v) => _set('gemini_model', v.trim());

  String get sarvamSttModel => _prefs.getString('sarvam_stt_model') ?? 'saaras:v4';
  set sarvamSttModel(String v) => _set('sarvam_stt_model', v.trim());

  String get sarvamTtsModel => _prefs.getString('sarvam_tts_model') ?? 'bulbul:v3';
  set sarvamTtsModel(String v) => _set('sarvam_tts_model', v.trim());

  String get sarvamSpeaker => _prefs.getString('sarvam_speaker') ?? 'shubh';
  set sarvamSpeaker(String v) => _set('sarvam_speaker', v.trim());

  double get ttsPace => _prefs.getDouble('tts_pace') ?? 1.05;
  set ttsPace(double v) => _setD('tts_pace', v);

  double get wakeSensitivity => _prefs.getDouble('wake_sensitivity') ?? 0.6;
  set wakeSensitivity(double v) => _setD('wake_sensitivity', v);

  /// 'sherpa' (free, default) or 'porcupine' (needs Picovoice AccessKey).
  String get wakeEngine => _prefs.getString('wake_engine') ?? 'sherpa';
  set wakeEngine(String v) => _set('wake_engine', v);

  /// Screen-agent brain: 'local' (on-device model, free, offline) or 'gemini' (cloud, uses quota).
  String get agentBrain => _prefs.getString('agent_brain') ?? 'local';
  set agentBrain(String v) => _set('agent_brain', v);

  /// Understand Hindi/Kannada/code-mixed speech by translating it to English (Sarvam translate mode).
  bool get mixedLanguage => _prefs.getBool('mixed_language') ?? true;
  set mixedLanguage(bool v) => _setB('mixed_language', v);

  bool get listeningEnabled => _prefs.getBool('listening_enabled') ?? false;
  set listeningEnabled(bool v) => _setB('listening_enabled', v);

  bool get speakResponses => _prefs.getBool('speak_responses') ?? true;
  set speakResponses(bool v) => _setB('speak_responses', v);

  /// Which cloud model explains free-form requests to LEO: auto (OpenAI if a key is set, else Sarvam) | openai | sarvam.
  String get understandingProvider => _prefs.getString('understanding_provider') ?? 'auto';
  set understandingProvider(String v) => _set('understanding_provider', v);

  /// OpenAI model for understanding. Small + non-reasoning = fast and cheap.
  String get openAiModel => _prefs.getString('openai_model') ?? 'gpt-4o-mini';
  set openAiModel(String v) => _set('openai_model', v.trim());

  /// Speak private content (messages, chats, OTPs, what's on screen) with the on-device voice only.
  bool get privateVoice => _prefs.getBool('private_voice') ?? true;
  set privateVoice(bool v) => _setB('private_voice', v);

  /// Hide LEO's screens from screenshots, screen recording and the recent-apps preview.
  bool get secureScreen => _prefs.getBool('secure_screen') ?? false;
  set secureScreen(bool v) => _setB('secure_screen', v);

  /// Let Sarvam's chat model understand free-form speech and turn it into clear LEO commands.
  bool get sarvamUnderstanding => _prefs.getBool('sarvam_understanding') ?? true;
  set sarvamUnderstanding(bool v) => _setB('sarvam_understanding', v);

  bool get followUpListening => _prefs.getBool('follow_up_listening') ?? true;
  set followUpListening(bool v) => _setB('follow_up_listening', v);

  /// Use the phone's own offline voice instead of Sarvam (no network, no Sarvam usage).
  bool get useDeviceTts => _prefs.getBool('use_device_tts') ?? false;
  set useDeviceTts(bool v) => _setB('use_device_tts', v);

  void _set(String k, String v) {
    _prefs.setString(k, v);
    notifyListeners();
  }

  void _setD(String k, double v) {
    _prefs.setDouble(k, v);
    notifyListeners();
  }

  void _setB(String k, bool v) {
    _prefs.setBool(k, v);
    notifyListeners();
  }
}

/// Helper for showing secrets-related platform errors without leaking values.
String describePlatformError(Object e) => e is PlatformException ? (e.message ?? e.code) : e.toString();
