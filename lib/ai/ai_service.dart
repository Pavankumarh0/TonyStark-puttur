import 'dart:convert';

import '../core/intent/local_intent.dart';
import '../data/memory_repository.dart';
import '../data/settings_store.dart';
import 'gemini_client.dart';

class AiNotConfigured implements Exception {
  @override
  String toString() => 'The Gemini API key is not set. Add it in Settings.';
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

class AiClarify extends AiProposal {
  final String question;
  const AiClarify(this.question);
}

/// Gemini is used only as writer, knowledge engine and fallback understanding — never for
/// ordinary device operations, wake word, STOP or task state.
class AiService {
  final SettingsStore settings;
  final MemoryRepository memory;
  final GeminiClient client;

  AiService(this.settings, this.memory, {GeminiClient? client}) : client = client ?? GeminiClient();

  bool get isConfigured => settings.hasSecret(SecretKey.gemini);

  String get _persona =>
      'You are JARVIS, a calm, precise, witty-but-professional personal AI assistant. '
      'Address the user as "${settings.address}" sparingly. Indian English is fine. '
      'Never claim you performed device actions; you only write and answer. Never invent memories: '
      'only use the context provided. If unsure, say so briefly.';

  void cancel() => client.cancelInFlight();

  Future<GeminiResult> _call(String purpose, String system, String user,
      {int maxTokens = 512, double temperature = 0.6, bool json = false}) async {
    final key = settings.secret(SecretKey.gemini);
    if (key == null || key.isEmpty) throw AiNotConfigured();
    final model = settings.geminiModel;
    try {
      final r = await client.generate(
        apiKey: key,
        model: model,
        systemInstruction: system,
        userText: user,
        maxOutputTokens: maxTokens,
        temperature: temperature,
        json: json,
      );
      await memory.logTokenUsage(
        model: model,
        purpose: purpose,
        input: r.usage.promptTokens,
        output: r.usage.outputTokens,
        thoughts: r.usage.thoughtsTokens,
        total: r.usage.totalTokens,
        reported: r.usage.reported,
        ok: true,
      );
      return r;
    } catch (e) {
      // Failed calls are logged (without token numbers — we never estimate them).
      await memory.logTokenUsage(model: model, purpose: purpose, reported: false, ok: false);
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
