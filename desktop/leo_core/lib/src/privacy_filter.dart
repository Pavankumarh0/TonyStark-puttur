// Shared with the LEO Android app (copied from lib/core/privacy_filter.dart). Keep in sync until Android adopts leo_core.
/// Strips personal identifiers from text BEFORE it leaves the phone, and puts them back afterwards.
///
/// `send my OTP 482913 to rahul@gmail.com and call 98450 12345`
///   → cloud sees: `send my OTP <OTP_1> to <EMAIL_1> and call <PHONE_1>`
///   → the cloud reply `call <PHONE_1>` is restored on the phone to `call 98450 12345`.
///
/// Times ("6:30", "5 pm"), dates, small counts and prices stay — they're needed to understand the request
/// and identify no one.
class Redaction {
  final String text;
  final Map<String, String> secrets; // placeholder → original (kept on the phone only)
  const Redaction(this.text, this.secrets);

  /// Puts the original values back into text produced by the cloud model.
  String restore(String s) {
    var out = s;
    secrets.forEach((k, v) => out = out.replaceAll(k, v));
    return out;
  }

  int get count => secrets.length;
}

class PrivacyFilter {
  // Order matters: most specific first.
  static final _rules = <(String, RegExp)>[
    // The body of a message being dictated: "… saying happy birthday da", "tell him that I'm late".
    ('MESSAGE', RegExp(r'(?<=\b(?:saying|that says|which says|tell (?:him|her|them)(?: that)?|telling (?:him|her|them)(?: that)?|message:|text:)\s+).{2,500}$', caseSensitive: false)),
    // Anything LEO quoted back ("I've prepared this message: \"…\"").
    ('QUOTE', RegExp(r'"[^"]{2,300}"|“[^”]{2,300}”')),
    // Secrets spoken next to a keyword: "otp is 4829", "password abc@123", "pin 1234", "cvv 123"
    ('SECRET', RegExp(r'(?<=\b(?:password|passcode|pass code)\s*(?:is|:|=)\s*)[^\s,]{3,32}', caseSensitive: false)),
    ('OTP', RegExp(r'(?<=\b(?:pin|cvv|mpin|upi pin|otp|one time password|verification code|code)\s*(?:is|:|=)?\s*)\d{3,8}\b', caseSensitive: false)),
    ('EMAIL', RegExp(r'\b[\w.+-]+@[\w-]+\.[\w.]{2,}\b')),
    ('UPI', RegExp(r'\b[\w.-]{2,}@(?:ok\w+|ybl|ibl|axl|upi|paytm|apl|yapl|icici|sbi|hdfc\w*|axis\w*|kotak|barodampay|idfcbank|jupiteraxis|fbl|pthdfc|ptsbi|ptyes|ptaxis)\b', caseSensitive: false)),
    ('CARD', RegExp(r'\b(?:\d[ -]?){13,19}\b')),
    ('AADHAAR', RegExp(r'\b\d{4}[ -]?\d{4}[ -]?\d{4}\b')),
    ('PAN', RegExp(r'\b[A-Z]{5}\d{4}[A-Z]\b')),
    ('IFSC', RegExp(r'\b[A-Z]{4}0[A-Z0-9]{6}\b')),
    ('PHONE', RegExp(r'(?<![\w])(?:\+?91[ -]?)?[6-9]\d{4}[ -]?\d{5}(?!\d)')),
    ('PHONE', RegExp(r'(?<![\w])\+\d{1,3}[ -]?\d{6,12}(?!\d)')),
    ('ACCOUNT', RegExp(r'(?<=\b(?:account|a/c|acc)\s*(?:no\.?|number)?\s*(?:is|:)?\s*)\d{9,18}\b', caseSensitive: false)),
    // Standalone 4–8 digit codes said as codes ("it's 482913") — but not times/years/prices.
    ('OTP', RegExp(r'(?<![\d:₹$.,/])\b\d{6}\b(?![:\d])')),
  ];

  /// [messageBodies] false keeps dictated message text and quotes (needed when asking the model to
  /// WRITE something) while still masking numbers, emails, OTPs and IDs.
  static Redaction redact(String input, {bool messageBodies = true}) {
    var text = input;
    final secrets = <String, String>{};
    final counters = <String, int>{};
    for (final (kind, re) in _rules) {
      if (!messageBodies && (kind == 'MESSAGE' || kind == 'QUOTE')) continue;
      text = text.replaceAllMapped(re, (m) {
        final original = m.group(0)!;
        if (original.trim().isEmpty || original.startsWith('<')) return original;
        // Same value twice → same placeholder.
        final existing = secrets.entries.where((e) => e.value == original).firstOrNull;
        if (existing != null) return existing.key;
        final n = (counters[kind] ?? 0) + 1;
        counters[kind] = n;
        final ph = '<${kind}_$n>';
        secrets[ph] = original;
        return ph;
      });
    }
    return Redaction(text, secrets);
  }
}
