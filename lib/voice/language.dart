
import 'sarvam_client.dart';

/// Multilingual support: LEO understands Kannada, Hindi and mixed speech (Sarvam translates it to
/// English, which all of LEO's existing command handling already understands) and replies in the
/// language the user spoke.
class Lang {
  static const english = 'en-IN', hindi = 'hi-IN', kannada = 'kn-IN';
  static const supported = {english, hindi, kannada};
  static const names = {english: 'English', hindi: 'हिन्दी', kannada: 'ಕನ್ನಡ'};

  static const _hindiNeighbours = {'gu-IN', 'mr-IN', 'pa-IN'};

  /// Below this confidence a detection is not trusted (noisy audio, one-word answers).
  static const minConfidence = 0.5; // English scores ~1.0; short loanword-heavy Hindi can be ~0.55

  /// The language to reply in after an utterance: a confident detection of a supported language,
  /// otherwise the conversation keeps the language it was in.
  static String pick(String? detected, double? probability, {required String previous}) {
    // Short Hindi commands share words with Gujarati/Marathi/Punjabi ("फ्लैशलाइट चालू करो" was scored
    // gu-IN 0.75). An unsure detection of a close neighbour is treated as Hindi.
    if (_hindiNeighbours.contains(detected) && (probability ?? 0) < 0.9) return hindi;
    if (detected == null || !supported.contains(detected)) return previous;
    if ((probability ?? 0) < minConfidence) return previous;
    return detected;
  }

  /// Language of typed text, from its script (Kannada or Devanagari letters), else null.
  static String? ofScript(String text) {
    var kn = 0, hi = 0, latin = 0;
    for (final r in text.runes) {
      if (r >= 0x0C80 && r <= 0x0CFF) {
        kn++;
      } else if (r >= 0x0900 && r <= 0x097F) {
        hi++;
      } else if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
        latin++;
      }
    }
    if (kn == 0 && hi == 0) return null;
    if (kn + hi < latin ~/ 4) return null; // mostly English with a stray word
    return kn >= hi ? kannada : hindi;
  }

  /// Speech translation turns relation words into English ("ಅಮ್ಮನಿಗೆ ಕರೆ ಮಾಡು" → "Call mother"),
  /// but contacts are usually saved as Amma, Appa, Mummy… These are the names to try.
  static List<String> relationAliases(String name) {
    final n = name.toLowerCase().trim().replaceFirst(RegExp(r'^(my|the)\s+'), '');
    for (final group in _relations) {
      if (group.contains(n)) return [for (final g in group) if (g != n) g];
    }
    return const [];
  }

  static const _relations = <List<String>>[
    ['mother', 'mom', 'mum', 'mummy', 'mommy', 'amma', 'maa', 'ammi', 'mata'],
    ['father', 'dad', 'daddy', 'appa', 'papa', 'pappa', 'pitaji', 'baba', 'abba'],
    ['elder brother', 'anna', 'bhaiya', 'bhai', 'brother'],
    ['elder sister', 'akka', 'didi', 'sister'],
    ['grandmother', 'grandma', 'ajji', 'avva', 'dadi', 'nani', 'paati'],
    ['grandfather', 'grandpa', 'ajja', 'thatha', 'tata', 'dada', 'nana'],
    ['wife', 'hendathi', 'patni', 'biwi'],
    ['husband', 'ganda', 'pati'],
    ['uncle', 'mama', 'chikkappa', 'doddappa', 'chacha', 'chachu'],
    ['aunt', 'aunty', 'attey', 'chikkamma', 'doddamma', 'chachi', 'mausi', 'bua'],
  ];
}

/// Translates LEO's English replies into the user's language, with a small cache so repeated
/// phrases ("Anything else, sir?") cost nothing and add no delay. Failures fall back to English.
class ReplyTranslator {
  final SarvamClient sarvam;
  final String? Function() apiKey;
  final _cache = <String, String>{}; // insertion-ordered: oldest first
  static const _maxCache = 300;

  ReplyTranslator(this.sarvam, this.apiKey);

  /// Quoted text — the message about to be sent, a song or file name — must stay exactly as it is,
  /// so the user approves what will really happen. Only the words around it are translated.
  static final _quoted = RegExp(r'"[^"]+"|“[^”]+”|‘[^’]+’');

  Future<String> toLanguage(String english, String target) async {
    if (target == Lang.english || english.trim().isEmpty) return english;
    if (!_quoted.hasMatch(english)) return _plain(english, target);
    final out = StringBuffer();
    var last = 0, changed = false;
    for (final m in _quoted.allMatches(english)) {
      final before = english.substring(last, m.start);
      final t = RegExp(r'[A-Za-z]').hasMatch(before) ? await _plain(before.trim(), target) : before.trim();
      changed |= !identical(t, before.trim()) && t != before.trim();
      if (t.isNotEmpty) out.write('$t ');
      out.write('${m.group(0)} ');
      last = m.end;
    }
    final tail = english.substring(last);
    final tt = RegExp(r'[A-Za-z]').hasMatch(tail) ? await _plain(tail.trim(), target) : tail.trim();
    changed |= tt != tail.trim();
    out.write(tt);
    return changed ? out.toString().trim() : english; // all fragments failed → plain English
  }

  /// LEO's short status lines ("Alarm set for 7 AM, sir.", "Flashlight on.") read like instructions
  /// once translated ("please set an alarm"). For translation only, they are said as full sentences;
  /// the English replies themselves stay exactly as they were.
  static final _expand = <(RegExp, String Function(Match))>[
    (RegExp(r'^Alarm set for ', caseSensitive: false), (m) => 'I have set an alarm for '),
    (RegExp(r'^Timer set for ', caseSensitive: false), (m) => 'I have set a timer for '),
    (RegExp(r'^Flashlight (on|off)\.?$', caseSensitive: false), (m) => 'I have turned the flashlight ${m[1]}.'),
    (RegExp(r'^Camera is ready', caseSensitive: false), (m) => 'The camera is ready'),
    (RegExp(r'^Done\.?$', caseSensitive: false), (m) => 'It is done.'),
  ];

  static String forTranslation(String english) {
    for (final (re, f) in _expand) {
      final m = re.firstMatch(english);
      if (m != null) return english.replaceRange(m.start, m.end, f(m));
    }
    return english;
  }

  Future<String> _plain(String english, String target) async {
    final key = '$target|$english';
    final hit = _cache.remove(key);
    if (hit != null) return _cache[key] = hit; // move to most-recent
    final k = apiKey();
    if (k == null || k.isEmpty) return english;
    try {
      // Mayura takes up to ~1000 characters per request: translate long replies sentence by sentence.
      final parts = _split(forTranslation(english), 900);
      final out = <String>[];
      for (final part in parts) {
        var t = await sarvam.translate(apiKey: k, text: part, source: Lang.english, target: target);
        // Everyday style sometimes keeps a short line entirely in English — then ask for a fuller one.
        if (t.trim() == part.trim()) t = await sarvam.translate(apiKey: k, text: part, source: Lang.english, target: target, mode: 'formal');
        out.add(t);
      }
      final t = out.join(' ').trim();
      if (t.isEmpty) return english;
      _cache[key] = t;
      if (_cache.length > _maxCache) _cache.remove(_cache.keys.first);
      return t;
    } catch (_) {
      return english; // never block a reply on translation
    }
  }

  /// Translates what the user TYPED in Kannada/Hindi into English for LEO's command handling.
  Future<String?> toEnglish(String text, String source) async {
    final k = apiKey();
    if (k == null || k.isEmpty) return null;
    try {
      return await sarvam.translate(apiKey: k, text: text, source: source, target: Lang.english, mode: 'formal');
    } catch (_) {
      return null;
    }
  }

  static List<String> _split(String text, int max) {
    if (text.length <= max) return [text];
    final sentences = RegExp(r'[^.!?।]+[.!?।]*\s*').allMatches(text).map((m) => m.group(0)!).toList();
    final out = <String>[];
    var cur = StringBuffer();
    for (final s in sentences) {
      if (cur.length + s.length > max && cur.isNotEmpty) {
        out.add(cur.toString().trim());
        cur = StringBuffer();
      }
      cur.write(s.length > max ? s.substring(0, max) : s);
    }
    if (cur.isNotEmpty) out.add(cur.toString().trim());
    return out;
  }
}
