import '../device/device_bridge.dart';
import 'intent/local_classifier.dart';
import 'time_parser.dart';

/// The kinds of ambiguity LEO detects. Each one is resolved by asking ONE short question
/// (or, for [screenReference], by looking at the app on screen) — never by guessing silently.
enum AmbiguityKind {
  /// Several saved contacts fit the name ("call Rahul" with three Rahuls).
  severalContacts,
  /// The chosen contact has more than one number.
  severalNumbers,
  /// Several installed apps fit the name ("open maps").
  severalApps,
  /// A required detail is missing ("set an alarm" — for what time?).
  missingTime,
  /// A message with no text ("message Kiran").
  missingMessage,
  /// The on-device model has a guess but is not sure (40–70 %): "Did you mean…?".
  unsureIntent,
  /// A confident guess of a call/message from a bare name ("Rahul"): confirmed before acting.
  riskyGuess,
  /// "this / it / that" said over another app: resolved from what is on screen.
  screenReference,
}

/// LEO's ambiguity rules in one place. The app uses exactly these functions, so the evaluation
/// in test/hai_eval_test.dart measures the real behaviour, not a copy of it.
class Ambiguity {
  /// Contacts a CALL could mean: an exact full-name match wins, then a first-name match,
  /// then everything the phone's search found. More than one left → ask.
  static List<ContactMatch> callCandidates(String name, List<ContactMatch> found) {
    final n = name.toLowerCase();
    final exact = found.where((c) => c.name.toLowerCase() == n).toList();
    final firstName = found.where((c) => c.name.toLowerCase().split(' ').first == n).toList();
    return exact.isNotEmpty ? exact : (firstName.isNotEmpty ? firstName : found);
  }

  /// Contacts a WHATSAPP message could mean: exact name wins, else everything found; contacts
  /// that have WhatsApp are preferred. More than one left → ask.
  static List<ContactMatch> messageCandidates(String name, List<ContactMatch> found) {
    final n = name.toLowerCase();
    final exact = found.where((c) => c.name.toLowerCase() == n).toList();
    var pool = exact.isNotEmpty ? exact : found;
    final wa = pool.where((c) => c.hasWhatsApp).toList();
    if (wa.isNotEmpty) pool = wa;
    return pool;
  }

  /// An alarm/reminder request without a clock time needs one.
  static bool needsTime(String text) {
    final w = TimeParser.when(text);
    return w == null || !w.hadTime;
  }

  /// The on-device model's best guess is plausible but not certain → confirm instead of acting.
  /// (Used only after the rules found nothing and the model was below its 70 % action threshold.)
  static bool isUnsure(List<(String, double)> top) =>
      top.isNotEmpty && top.first.$2 >= 0.4 && LocalIntentClassifier.describe(top.first.$1) != null;

  /// Calls and messages reach another person and can't be undone. A bare name or a couple of words
  /// ("Rahul", "dad", "kiran please") is too little evidence for them, however confident the model is
  /// (short inputs make it over-confident), so such a guess is confirmed first.
  static bool riskyGuess(String label, String text) {
    if (label != 'call' && label != 'send_message') return false;
    return !_actionWord.hasMatch(text);
  }

  static final _actionWord = RegExp(
      r'\b(call|calling|phone|dial|ring|buzz|message|messages|text|whatsapp|tell|send|ping|reach|contact|speak|talk)\b',
      caseSensitive: false);

  /// "delete this", "share it", "save that": refers to something on screen.
  static final _deictic = RegExp(r'\b(this|it|that|here|these|those)\b', caseSensitive: false);
  static bool refersToScreen(String utterance) => _deictic.hasMatch(utterance);
}
