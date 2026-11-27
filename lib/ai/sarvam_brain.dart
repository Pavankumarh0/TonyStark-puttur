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
  final int? inputTokens, outputTokens, cachedTokens;
  final String provider, model;
  final int latencyMs;
  const Interpretation(
      {this.commands = const [],
      this.answer,
      this.clarify,
      this.inputTokens,
      this.outputTokens,
      this.cachedTokens,
      this.provider = '',
      this.model = '',
      this.latencyMs = 0});

  bool get isEmpty => commands.isEmpty && answer == null && clarify == null;
  int get totalTokens => (inputTokens ?? 0) + (outputTokens ?? 0);

  Interpretation copyWith({List<String>? commands, String? answer, String? clarify, String? provider, String? model, int? latencyMs}) =>
      Interpretation(
          commands: commands ?? this.commands,
          answer: answer ?? this.answer,
          clarify: clarify ?? this.clarify,
          inputTokens: inputTokens,
          outputTokens: outputTokens,
          cachedTokens: cachedTokens,
          provider: provider ?? this.provider,
          model: model ?? this.model,
          latencyMs: latencyMs ?? this.latencyMs);

  /// Cost of this one call (USD for OpenAI, INR for Sarvam), from published per-token prices.
  ({double amount, String currency})? get cost => Pricing.cost(provider, model, inputTokens, outputTokens, cachedTokens);

  /// "OpenAI · 752 tokens · \$0.00008 · 0.4 s"
  String get usageLine {
    final c = cost;
    final money = c == null ? '' : ' · ${c.currency == 'USD' ? '\$' : '₹'}${c.amount < 0.01 ? c.amount.toStringAsFixed(5) : c.amount.toStringAsFixed(3)}';
    return '${provider == 'openai' ? 'OpenAI' : 'Sarvam'} · $totalTokens tokens$money · ${(latencyMs / 1000).toStringAsFixed(1)} s';
  }
}

/// Published per-1M-token prices used to show what each request costs.
class Pricing {
  static const _table = <String, (double input, double cached, double output, String currency)>{
    'gpt-4o-mini': (0.15, 0.075, 0.60, 'USD'),
    'gpt-4.1-mini': (0.40, 0.10, 1.60, 'USD'),
    'gpt-5-nano': (0.05, 0.005, 0.40, 'USD'),
    'gpt-5-mini': (0.25, 0.025, 2.00, 'USD'),
    'sarvam-105b-conversations': (10, 0.25, 25, 'INR'),
    'sarvam-105b': (10, 0.25, 25, 'INR'),
  };

  static ({double amount, String currency})? cost(String provider, String model, int? input, int? output, int? cached) {
    final p = _table[model];
    if (p == null || input == null) return null;
    final c = (cached ?? 0).clamp(0, input);
    final amount = ((input - c) * p.$1 + c * p.$2 + (output ?? 0) * p.$3) / 1e6;
    return (amount: amount, currency: p.$4);
  }
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
Rewrite what they want into SHORT commands that LEO understands. Reply with compact JSON only, using ONE of:
{"commands": ["..."]}   or   {"answer": "..."}   or   {"clarify": "..."}
Never add "answer" next to "commands" (LEO reports results itself). No extra keys, no empty strings.
Examples:
"open that AI app and make slides on blood" → {"commands": ["open ChatGPT", "ask it to make slides on blood"]}
"capital of Karnataka?" → {"answer": "Bengaluru, sir."}
"open instagram and send a reel to Pavan" → {"commands": ["on the phone: open Instagram and send a reel to Pavan"]}

Command phrasings LEO understands (use these exact shapes, in English):
- open <app>                         e.g. open ChatGPT, open YouTube
- what time is it / what's the date today / what are my reminders / check my messages
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
- "AI app" / "that AI" / "chatbot" means ChatGPT unless the user names another.
- on the phone: <clear step-by-step goal>   ONLY for multi-step screen work none of the above covers. Put it INSIDE "commands".
  Make the goal explicit, e.g. "on the phone: open Instagram, go to Reels, tap Share on the current reel, search Pavan, select him, tap Send".

Rules:
- Keep the user's names, numbers, message text and search words exactly (translate Hindi/Kannada request words to English, but not names).
- Several things in one sentence → several commands, in order. Never drop a part of the request.
- "it/this/that" refers to the app on screen or the previous turn (given below).
- A question or chit-chat that needs no phone action → put a short, friendly spoken answer (max 2 sentences, Indian English, address the user as "sir") in "answer" and no commands.
- If you really can't tell what they want, ask ONE short question in "clarify".
- Never invent recipients, amounts or messages. Never add payments or deletions the user didn't ask for.
- Tokens like <PHONE_1>, <EMAIL_1>, <OTP_1> are private values hidden by the phone: copy them unchanged where needed.
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
    final sw = Stopwatch()..start();
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
    return parse(content,
        inputTokens: usage?['prompt_tokens'] as int?,
        outputTokens: usage?['completion_tokens'] as int?,
        cachedTokens: (usage?['prompt_tokens_details'] as Map?)?['cached_tokens'] as int?,
        provider: 'sarvam',
        model: model).copyWith(latencyMs: sw.elapsedMilliseconds);
  }

  /// General chat completion (writing, answers, routing). Returns text + usage.
  Future<({String text, int? input, int? output, int? cached, String? finish})> chat({
    required String apiKey,
    required String system,
    required String user,
    int maxTokens = 512,
    double temperature = 0.6,
    bool json = false,
  }) async {
    final body = {
      'model': model,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      'temperature': temperature,
      'max_tokens': maxTokens,
      if (json) 'response_format': {'type': 'json_object'},
    };
    final http.Response res;
    try {
      res = await _client
          .post(Uri.parse(_url),
              headers: {'api-subscription-key': apiKey, 'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw SarvamBrainException('Sarvam took too long to answer', 408);
    } on http.ClientException catch (e) {
      throw SarvamBrainException('Network error talking to Sarvam: ${e.message}', 0);
    }
    if (res.statusCode != 200) throw SarvamBrainException(_err(res.body) ?? 'Sarvam chat failed', res.statusCode);
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final choice = (j['choices'] as List?)?.firstOrNull as Map?;
    final usage = j['usage'] as Map?;
    return (
      text: ((choice?['message'] as Map?)?['content'] as String? ?? '').trim(),
      input: usage?['prompt_tokens'] as int?,
      output: usage?['completion_tokens'] as int?,
      cached: (usage?['prompt_tokens_details'] as Map?)?['cached_tokens'] as int?,
      finish: choice?['finish_reason'] as String?,
    );
  }

  /// Tolerant JSON extraction (the model may wrap JSON in prose or code fences).
  static Interpretation parse(String content,
      {int? inputTokens, int? outputTokens, int? cachedTokens, String provider = '', String model = ''}) {
    final s = content.indexOf('{'), e = content.lastIndexOf('}');
    if (s < 0 || e <= s) return Interpretation(answer: content.trim().isEmpty ? null : content.trim());
    Map<String, dynamic> m;
    try {
      m = jsonDecode(content.substring(s, e + 1)) as Map<String, dynamic>;
    } catch (_) {
      return const Interpretation();
    }
    String? str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    // Tolerate small format slips: {"on the phone": "..."} / {"command": "..."}.
    final stray = <String>[
      if (m['on the phone'] is String) 'on the phone: ${m['on the phone']}',
      if (m['command'] is String) m['command'] as String,
    ];
    final cmds = [...((m['commands'] as List?) ?? const []), ...stray]
        .whereType<String>()
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty && c.length < 300)
        .take(4) // never a long chain
        .toList();
    return Interpretation(
        commands: cmds,
        answer: str(m['answer']),
        clarify: str(m['clarify']),
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cachedTokens: cachedTokens,
        provider: provider,
        model: model);
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
