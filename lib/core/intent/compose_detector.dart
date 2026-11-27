import 'local_intent.dart';

/// Spots requests where the user wants LEO to WRITE a message or email (not send their exact words)
/// and turns them into a compose request, so OpenAI drafts a well-written text that the user then
/// approves before anything is sent.
///
/// It only steps in when the wording asks for writing — a writing verb ("write / compose / draft"),
/// a tone ("polite / formal / professional / detailed / long"), an explaining connector
/// ("explaining why…", "asking for…", "regarding…") or a style instruction ("write it properly",
/// "explain it professionally"). Plain dictation ("message Rahul that I am late") is left exactly as
/// LEO already handles it: those exact words are sent.
class ComposeDetector {
  static const _writeVerbs = {'write', 'compose', 'draft', 'prepare', 'create', 'frame'};
  static const _tone =
      r'(?:short|long|longer|detailed|polite|formal|professional|proper|nice|good|quick|brief|well[- ]written|sweet|clear|small|kind|warm|official)';
  static const _composeConnectors = {
    'explaining', 'explain', 'asking', 'about', 'regarding', 'informing', 'letting', 'requesting',
    'apologizing', 'apologising', 'for', 'to inform', 'to let', 'to explain', 'to ask', 'to request',
  };
  static const _connector = r'(saying|that|telling\s+(?:him|her|them)|explaining|explain|asking|about|regarding|'
      r'informing(?:\s+(?:him|her|them))?|letting\s+(?:him|her|them)\s+know|to\s+say|to\s+tell\s+(?:him|her|them)|'
      r'to\s+let\s+(?:him|her|them)\s+know|to\s+inform(?:\s+(?:him|her|them))?|to\s+explain|to\s+ask|to\s+request|'
      r'requesting|apologi[sz]ing|for)';

  /// "…, write it properly", "explain it professionally", "make it polite", "in detail", "politely".
  static final style = RegExp(
      r'(?:[,.]?\s*(?:and\s+)?(?:please\s+)?(?:write|make|phrase|word|put|explain|say|frame|draft)\s+(?:it|this|that)\s+'
      r'(?:properly|nicely|politely|professionally|formally|well|clearly|in\s+detail|in\s+a\s+\w+\s+way|polite|formal|professional|nice))'
      r'|(?:[,.]?\s*(?:very\s+)?(?:politely|professionally|formally|in\s+detail|nicely)\.?\s*$)',
      caseSensitive: false);

  static final _message = RegExp(
      '^(?:please\\s+|can\\s+you\\s+|could\\s+you\\s+)*(send|write|compose|draft|prepare|create|frame|type)\\s+'
      '(?:(?:a|an|the)\\s+)?((?:$_tone\\s+)*)(?:whats\\s*app\\s+)?(?:message|msg|text|note|reply)\\s+'
      '(?:on\\s+whats\\s*app\\s+)?to\\s+(.+?)\\s*,?\\s+$_connector\\s+(.+)\$',
      caseSensitive: false);

  static final _email = RegExp(
      '^(?:please\\s+|can\\s+you\\s+|could\\s+you\\s+)*(?:(send|write|compose|draft|prepare|create|frame)\\s+)?'
      '(?:(?:a|an|the)\\s+)?((?:$_tone\\s+)*)(?:e-?mail|mail)\\s+(?:to\\s+)?(\\S+@\\S+|.+?)\\s*,?\\s+$_connector\\s+(.+)\$',
      caseSensitive: false);

  /// Returns a compose intent when [text] asks LEO to write; otherwise [intent] unchanged.
  static LocalIntent upgrade(LocalIntent intent, String text) {
    // Only intents a writing request can be (mis)read as; anything else (ask ChatGPT to write…,
    // alarms, calls…) is never touched.
    if (intent is! SendMessageIntent && intent is! EmailIntent && intent is! WriteIntent && intent is! PhoneTaskIntent && intent is! UnknownIntent) {
      return intent;
    }
    final t = text.trim().replaceAll(RegExp(r'[.!]+$'), '');
    final hasStyle = style.hasMatch(t);

    final e = _email.firstMatch(t);
    if (e != null && !RegExp(r'\b(whats\s*app|message|msg|text)\b', caseSensitive: false).hasMatch(e.group(3)!)) {
      final verb = (e.group(1) ?? 'email').toLowerCase();
      final conn = e.group(4)!.toLowerCase().replaceAll(RegExp(r'\s+(him|her|them).*$'), '');
      if (_writeVerbs.contains(verb) || e.group(2)!.trim().isNotEmpty || _isComposeConnector(conn) || hasStyle) {
        return EmailIntent(_cleanRecipient(e.group(3)!), topic: _factsOnly(t));
      }
    }

    final m = _message.firstMatch(t);
    if (m != null) {
      final verb = m.group(1)!.toLowerCase();
      final conn = m.group(4)!.toLowerCase().replaceAll(RegExp(r'\s+(him|her|them).*$'), '');
      if (_writeVerbs.contains(verb) || m.group(2)!.trim().isNotEmpty || _isComposeConnector(conn) || hasStyle) {
        final (name, isGroup) = _recipientOf(m.group(3)!);
        return SendMessageIntent(
            app: _app(t), recipient: name, composeTopic: t, composeLong: true, isGroup: isGroup);
      }
    }

    // Dictation with a style instruction: "tell Kiran on WhatsApp that I'm sick, write it properly".
    if (intent is SendMessageIntent && intent.message != null && style.hasMatch(intent.message!)) {
      return SendMessageIntent(
          app: intent.app, recipient: intent.recipient, composeTopic: t, composeLong: true, isGroup: intent.isGroup);
    }
    return intent;
  }

  static bool _isComposeConnector(String c) => _composeConnectors.contains(c) || _composeConnectors.contains(c.split(' ').first);

  static MessagingApp _app(String t) =>
      RegExp(r'whats\s*app\s+business', caseSensitive: false).hasMatch(t) ? MessagingApp.whatsappBusiness : MessagingApp.whatsapp;

  static String _cleanRecipient(String r) => r
      .trim()
      .replaceAll(RegExp(r'\s+on\s+whats\s*app$', caseSensitive: false), '')
      .replaceAll(RegExp(r'^(?:my|the)\s+', caseSensitive: false), '')
      .replaceAll(RegExp(r'[.,!?;:"]+$'), '')
      .trim();

  static (String, bool) _recipientOf(String raw) {
    var r = _cleanRecipient(raw);
    final g = RegExp(r'^(?:whats\s*app\s+)?group\s+(?:called\s+|named\s+)?(.+)$|^(.+?)\s+(?:whats\s*app\s+)?group$', caseSensitive: false).firstMatch(r);
    if (g != null) return ((g.group(1) ?? g.group(2))!.trim(), true);
    return (r, false);
  }

  /// The email writer gets the user's request plus a guard against made-up details.
  static String _factsOnly(String request) =>
      '$request. (Use only the facts the user gave; if a reason or detail is not given, keep it general instead of inventing one.)';
}
