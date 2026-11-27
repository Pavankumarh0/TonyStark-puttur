import 'dart:convert';

import '../core/intent/local_intent.dart';
import '../data/memory_repository.dart';
import '../data/settings_store.dart';
import '../core/privacy_filter.dart';
import 'gemini_client.dart';
import 'openai_brain.dart';
import 'sarvam_brain.dart';

class AiNotConfigured implements Exception {
  @override
  String toString() => 'The OpenAI API key is not set. Add OPENAI_API_KEY to lib/.env and rebuild.';
}

/// A structured proposal from the AI router. The AI never executes anything: the local executor
/// validates these and runs them through the normal permission/approval checks.
sealed class AiProposal {
  const AiProposal();
}

class AiAnswer extends AiProposal {
  final String text;
  const AiAnswer(this.text);
}

class AiOpenApp extends AiProposal {
  final String app;
  const AiOpenApp(this.app);
}

class AiSendMessage extends AiProposal {
  final MessagingApp app;
  final String recipient;
  final bool isGroup;
  final String message;
  const AiSendMessage(this.app, this.recipient, this.isGroup, this.message);
}

class AiDraft extends AiProposal {
  final WritingKind kind;
  final String? subject;
  final String content;
  const AiDraft(this.kind, this.subject, this.content);
}

class AiOperatePhone extends AiProposal {
  final String goal;
  const AiOperatePhone(this.goal);
}

class AiClarify extends AiProposal {
  final String question;
  const AiClarify(this.question);
}

/// OpenAI is LEO's brain for writing, answers and fallback understanding — never for ordinary
/// device operations, wake word, STOP or task state (those run on the phone). Sarvam is voice only.
/// Phone numbers, emails, OTPs and IDs are masked before every call and restored on the phone.
class AiService {
  final SettingsStore settings;
  final MemoryRepository memory;
  final GeminiClient client; // kept for compatibility; not used
  final OpenAiBrain openai = OpenAiBrain();

  AiService(this.settings, this.memory, {GeminiClient? client}) : client = client ?? GeminiClient();

  bool get isConfigured => settings.hasSecret(SecretKey.openai);

  String get _persona =>
      'You are LEO, a calm, precise, witty-but-professional personal AI assistant. '
      'Address the user as "${settings.address}" sparingly. Indian English is fine. '
      'Never claim you performed device actions; you only write and answer. Never invent memories: '
      'only use the context provided. If unsure, say so briefly.';

  void cancel() => openai.cancel();

  Future<GeminiResult> _call(String purpose, String system, String user,
      {int maxTokens = 512, double temperature = 0.6, bool json = false}) async {
    final key = settings.secret(SecretKey.openai);
    if (key == null || key.isEmpty) throw AiNotConfigured();
    final model = settings.openAiModel;
    // Mask identifiers (keep the wording — writing needs it); restore them in the answer.
    final red = PrivacyFilter.redact(user, messageBodies: false);
    final sw = Stopwatch()..start();
    try {
      final r = await openai.chat(
          apiKey: key, model: model, system: system, user: red.text, maxTokens: maxTokens, temperature: temperature, json: json);
      final cost = Pricing.cost('openai', model, r.input, r.output, r.cached);
      await memory.logTokenUsage(
          provider: 'openai', model: model, purpose: purpose, input: r.input, output: r.output,
          total: (r.input ?? 0) + (r.output ?? 0), reported: r.input != null, ok: true);
      await memory.logCloud(
          provider: 'openai', model: model, purpose: purpose,
          sentText: red.text.length > 400 ? '${red.text.substring(0, 400)}…' : red.text, maskedCount: red.count,
          input: r.input, output: r.output, cached: r.cached, cost: cost?.amount, currency: cost?.currency,
          latencyMs: r.ms, ok: true);
      return GeminiResult(
          red.restore(r.text),
          GeminiUsage(promptTokens: r.input, outputTokens: r.output, totalTokens: (r.input ?? 0) + (r.output ?? 0)),
          r.finish);
    } catch (e) {
      await memory.logTokenUsage(provider: 'openai', model: model, purpose: purpose, reported: false, ok: false);
      await memory.logCloud(
          provider: 'openai', model: model, purpose: purpose, sentText: red.text.length > 400 ? '${red.text.substring(0, 400)}…' : red.text,
          maskedCount: red.count, latencyMs: sw.elapsedMilliseconds, ok: false);
      if (e is SarvamBrainException && (e.status == 402 || e.status == 429)) {
        throw Exception(e.message.toLowerCase().contains('quota') || e.message.toLowerCase().contains('billing')
            ? 'OpenAI credits are used up — top up at platform.openai.com.'
            : 'OpenAI is rate-limiting; try again in a moment.');
      }
      rethrow;
    }
  }

  /// General knowledge / conversation answer, suitable to be spoken.
  Future<String> answer(String question, String context) async {
    final r = await _call(
      'knowledge',
      '$_persona Answer conversationally in at most 4 short sentences unless the user asks for detail. '
          'Plain text only: no markdown, no bullet symbols, no emojis — it will be read aloud.',
      context.isEmpty ? question : '$context\n\nUser: $question',
      maxTokens: 400,
    );
    return r.text;
  }

  /// Writing assistant. Returns subject (for email) + body for review — never sends anything.
  Future<AiDraft> write(WritingKind kind, String request, String context) async {
    final kindHint = switch (kind) {
      WritingKind.email => 'an email. Return JSON {"subject": string, "content": string}. Content is the full email body with greeting and sign-off',
      WritingKind.message => 'a short chat message (WhatsApp/SMS style). Return JSON {"subject": null, "content": string}',
      WritingKind.rewrite => 'an improved rewrite of the provided text. Return JSON {"subject": null, "content": string}',
      _ => 'the requested document. Return JSON {"subject": string or null, "content": string}',
    };
    final r = await _call(
      'writing',
      '$_persona You are drafting $kindHint. Write in the user\'s voice (first person), ready to send. '
          'Do not add placeholders like [Name] unless the information is genuinely missing.',
      context.isEmpty ? request : '$context\n\nRequest: $request',
      maxTokens: 900,
      temperature: 0.7,
      json: true,
    );
    final j = _parseJson(r.text);
    final content = (j?['content'] as String?)?.trim();
    if (content == null || content.isEmpty) {
      return AiDraft(kind, null, r.text.trim());
    }
    return AiDraft(kind, (j?['subject'] as String?)?.trim(), content);
  }

  /// Composes a WhatsApp message about [topic] for [recipient].
  Future<String> composeMessage(String recipient, String topic, String context) async {
    final r = await _call(
      'writing',
      '$_persona Write ONE short, natural WhatsApp message in first person from the user to "$recipient". '
          'Return JSON {"content": string}. No greeting fluff, no emojis unless clearly appropriate.',
      context.isEmpty ? 'Topic: $topic' : '$context\n\nTopic: $topic',
      maxTokens: 200,
      json: true,
    );
    final j = _parseJson(r.text);
    return ((j?['content'] as String?) ?? r.text).trim();
  }

  /// Screen agent: given the goal, recent steps and the current screen (numbered elements), choose ONE
  /// next action. The local executor validates it, asks the user before anything sensitive, and runs it.
  Future<Map<String, dynamic>> agentStep({
    required String goal,
    required String screen,
    required String? package,
    required List<String> history,
    required List<String> apps,
  }) async {
    final r = await _call(
      'phone_agent',
      'You operate an Android phone for the user, one action at a time, using the numbered screen elements. '
          'Return ONLY JSON: {"thought": short reason, "action": {"type": "tap|long_press|type|submit|scroll|back|home|open_app|wait|notifications", '
          '"index": element number or null, "text": text to type or null, "dir": "up|down|left|right" or null, "app": app name for open_app or null}, '
          '"sensitive": true if this action sends, deletes, pays, buys, posts, submits, shares, books, uninstalls or is otherwise irreversible, '
          '"describe": one short sentence telling the user what this action does (e.g. "Tap Send to email Rahul"), '
          '"done": true when the goal is fully achieved (then action may be null), "summary": what was achieved (only when done), '
          '"ask": a question for the user if you need information (else null)}. '
          'Rules: prefer open_app to reach an app; after typing in a search box use submit; never type passwords; '
          'if a login, payment or captcha blocks you, set ask to explain. Do not repeat a failed action more than twice. '
          'Report only what the screen shows — never claim success you cannot see.',
      'Goal: $goal\n'
          'Installed apps (some): ${apps.take(60).join(', ')}\n'
          'Steps so far:\n${history.isEmpty ? '(none)' : history.join('\n')}\n'
          'Current app: ${package ?? 'unknown'}\nScreen:\n$screen',
      maxTokens: 300,
      temperature: 0.2,
      json: true,
    );
    return _parseJson(r.text) ?? const {'done': false, 'ask': 'I could not decide the next step.'};
  }

  /// Fallback understanding when the local intent engine cannot parse the request.
  Future<AiProposal> route(String utterance, String context, List<String> installedAppsSample) async {
    final r = await _call(
      'understanding',
      '$_persona Classify the user request and return ONLY JSON with one of these shapes:\n'
          '{"kind":"answer","text":string}  — questions, chit-chat, anything informational (plain text, ≤4 sentences, speakable)\n'
          '{"kind":"open_app","app":string} — user wants to open an app on the phone\n'
          '{"kind":"send_message","app":"whatsapp"|"whatsapp_business","recipient":string,"is_group":bool,"message":string} — user wants to send a WhatsApp message; message is the exact text to send, in first person\n'
          '{"kind":"write","draft_type":"email"|"message"|"document","subject":string|null,"content":string} — user wants something written for review\n'
          '{"kind":"clarify","question":string} — the request is ambiguous; ask one short question\n'
          '{"kind":"operate_phone","goal":string} — the user wants something DONE on the phone that needs operating apps (tapping/typing), e.g. delete an email, find a photo, change a setting\n'
          'Use "whatsapp_business" only if the user explicitly says business.',
      '${context.isEmpty ? '' : '$context\n\n'}Some installed apps: ${installedAppsSample.take(40).join(', ')}\n\nUser request: $utterance',
      maxTokens: 600,
      temperature: 0.3,
      json: true,
    );
    final j = _parseJson(r.text);
    if (j == null) return AiAnswer(r.text);
    switch (j['kind']) {
      case 'open_app':
        final app = (j['app'] as String?)?.trim();
        if (app != null && app.isNotEmpty) return AiOpenApp(app);
      case 'send_message':
        final recipient = (j['recipient'] as String?)?.trim();
        final message = (j['message'] as String?)?.trim();
        if (recipient != null && recipient.isNotEmpty && message != null && message.isNotEmpty) {
          return AiSendMessage(
            j['app'] == 'whatsapp_business' ? MessagingApp.whatsappBusiness : MessagingApp.whatsapp,
            recipient,
            j['is_group'] == true,
            message,
          );
        }
      case 'write':
        final content = (j['content'] as String?)?.trim();
        if (content != null && content.isNotEmpty) {
          final kind = switch (j['draft_type']) {
            'email' => WritingKind.email,
            'message' => WritingKind.message,
            _ => WritingKind.document,
          };
          return AiDraft(kind, (j['subject'] as String?)?.trim(), content);
        }
      case 'operate_phone':
        final g = (j['goal'] as String?)?.trim();
        if (g != null && g.isNotEmpty) return AiOperatePhone(g);
      case 'clarify':
        final q = (j['question'] as String?)?.trim();
        if (q != null && q.isNotEmpty) return AiClarify(q);
      case 'answer':
        final t = (j['text'] as String?)?.trim();
        if (t != null && t.isNotEmpty) return AiAnswer(t);
    }
    return AiAnswer((j['text'] as String?) ?? r.text);
  }

  static Map<String, dynamic>? _parseJson(String s) {
    var t = s.trim();
    if (t.startsWith('```')) {
      t = t.replaceFirst(RegExp(r'^```(json)?'), '').replaceFirst(RegExp(r'```$'), '').trim();
    }
    try {
      final v = jsonDecode(t);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }
}
