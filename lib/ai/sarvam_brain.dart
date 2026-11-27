import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// What Sarvam made of the user's words.
class Interpretation {
  /// Plain commands in LEO's own phrasing, run one after another by the local engine.
  final List<String> commands;

  /// Short spoken answer for questions / chit-chat (no phone action needed).
  final String? answer;

  /// A question back to the user when the request is genuinely unclear.
  final String? clarify;
  final int? inputTokens, outputTokens;
  const Interpretation({this.commands = const [], this.answer, this.clarify, this.inputTokens, this.outputTokens});

  bool get isEmpty => commands.isEmpty && answer == null && clarify == null;
}

/// Uses Sarvam's chat model to understand what the user meant (Indian English, Hindi/Kannada mix,
/// rambling or indirect requests) and rewrite it as clear commands LEO's local engine already
/// executes. It never acts by itself: every command still goes through LEO's rules and approvals.
class SarvamBrain {
  static const _url = 'https://api.sarvam.ai/v1/chat/completions';
  static const model = 'sarvam-105b-conversations'; // fast model for voice assistants
  http.Client _client = http.Client();

  void cancel() {
    _client.close();
    _client = http.Client();
  }

  static const systemPrompt = '''
You are the understanding layer of LEO, a voice assistant that controls an Android phone in India.
The user speaks Indian English, sometimes mixed with Hindi or Kannada, sometimes rambling.
Rewrite what they want into SHORT commands that LEO understands. Reply with JSON only:
{"commands": ["..."], "answer": "...", "clarify": "..."}  (omit fields you don't need)

Command phrasings LEO understands (use these exact shapes, in English):
- open <app>                         e.g. open ChatGPT, open YouTube
- play <song or video> on <youtube|spotify|youtube music>
- pause the music / resume the music / next song / volume up
- call <contact name>
- send a whatsapp message to <contact> saying <exact message>
- read my chat with <contact>
- check my messages / check my email
- ask it to <request>                 types the request into the AI/chat app on screen and sends it
- ask <ChatGPT|Claude|Gemini|Perplexity> to <request>
- click <button name>                 / scroll down / scroll up / go back / go home / read this / type <text>
- set an alarm for <time> / turn off my <time> alarm / set a timer for <duration>
- remind me to <thing> <when> / what are my reminders / delete the reminder about <thing>
- schedule a meeting with <names> <when> on google meet|zoom
- open <website.com> / search for <query> on <wikipedia|amazon|flipkart|youtube> / search google for <query>
- open my <name> pdf
- install <app>
- turn on|off wifi|bluetooth|flashlight|do not disturb|mobile data
- log in to <app> with my phone number|google
- navigate to <place>
- on the phone: <clear step-by-step goal>   ONLY for multi-step screen work none of the above covers.
  Make the goal explicit, e.g. "on the phone: open Instagram, go to Reels, tap Share on the current reel, search Pavan, select him, tap Send".

Rules:
- Keep the user's names, numbers, message text and search words exactly (translate Hindi/Kannada request words to English, but not names).
- Several things in one sentence → several commands, in order.
- "it/this/that" refers to the app on screen or the previous turn (given below).
- A question or chit-chat that needs no phone action → put a short, friendly spoken answer (max 2 sentences, Indian English, address the user as "sir") in "answer" and no commands.
- If you really can't tell what they want, ask ONE short question in "clarify".
- Never invent recipients, amounts or messages. Never add payments or deletions the user didn't ask for.
''';

  Future<Interpretation?> interpret({
    required String apiKey,
    required String utterance,
    String? screenApp,
    List<String> recentTurns = const [],
  }) async {
    final ctx = StringBuffer();
    if (screenApp != null) ctx.writeln('App on screen: $screenApp');
    if (recentTurns.isNotEmpty) ctx.writeln('Recent conversation:\n${recentTurns.join('\n')}');
    final body = {
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': '${ctx.isEmpty ? '' : '$ctx\n'}User said: "$utterance"'},
      ],
      'temperature': 0.2,
      'max_tokens': 400,
      'response_format': {'type': 'json_object'},
    };
    final http.Response res;
    try {
      res = await _client
          .post(Uri.parse(_url),
              headers: {'api-subscription-key': apiKey, 'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      return null;
    } on http.ClientException {
      return null;
    }
    if (res.statusCode != 200) {
      throw SarvamBrainException(_err(res.body) ?? 'Sarvam chat failed', res.statusCode);
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final content = (((j['choices'] as List?)?.firstOrNull as Map?)?['message'] as Map?)?['content'] as String? ?? '';
    final usage = j['usage'] as Map?;
    return parse(content, inputTokens: usage?['prompt_tokens'] as int?, outputTokens: usage?['completion_tokens'] as int?);
  }

  /// Tolerant JSON extraction (the model may wrap JSON in prose or code fences).
  static Interpretation parse(String content, {int? inputTokens, int? outputTokens}) {
    final s = content.indexOf('{'), e = content.lastIndexOf('}');
    if (s < 0 || e <= s) return Interpretation(answer: content.trim().isEmpty ? null : content.trim());
    Map<String, dynamic> m;
    try {
      m = jsonDecode(content.substring(s, e + 1)) as Map<String, dynamic>;
    } catch (_) {
      return const Interpretation();
    }
    String? str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    final cmds = ((m['commands'] as List?) ?? const [])
        .whereType<String>()
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty && c.length < 300)
        .take(4) // never a long chain
        .toList();
    return Interpretation(
        commands: cmds, answer: str(m['answer']), clarify: str(m['clarify']), inputTokens: inputTokens, outputTokens: outputTokens);
  }

  static String? _err(String body) {
    try {
      final j = jsonDecode(body);
      final e = (j as Map)['error'];
      if (e is Map) return e['message'] as String?;
      return e?.toString() ?? j['message']?.toString();
    } catch (_) {
      return null;
    }
  }
}

class SarvamBrainException implements Exception {
  final String message;
  final int status;
  SarvamBrainException(this.message, this.status);
  @override
  String toString() => '$message (HTTP $status)';
}
