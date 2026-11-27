import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sarvam_brain.dart';

/// Same job as [SarvamBrain] — turn what the user said into plain LEO commands — using OpenAI.
///
/// Chosen for speed and low token use:
///  * a small non-reasoning model (default gpt-4o-mini: ~0.5 s, no hidden "thinking" tokens),
///  * one short, FIXED system prompt sent first so OpenAI's automatic prompt cache can reuse it,
///  * JSON output capped at a few hundred tokens,
///  * `store: false` — the request isn't kept for OpenAI's evals/distillation products.
/// Personal identifiers are removed before this is called (see PrivacyFilter).
class OpenAiBrain {
  static const _url = 'https://api.openai.com/v1/chat/completions';

  /// After "no credits" / bad key, don't call again for a while — fail instantly instead (faster, no waste).
  static DateTime? _blockedUntil;
  static String? blockReason;
  static bool get blocked => _blockedUntil != null && DateTime.now().isBefore(_blockedUntil!);
  static void _noteFailure(int status, String msg) {
    final m = msg.toLowerCase();
    if (status == 401 || status == 403 || m.contains('credit') || m.contains('quota') || m.contains('billing')) {
      _blockedUntil = DateTime.now().add(const Duration(minutes: 2));
      blockReason = msg;
    }
  }
  http.Client _client = http.Client();

  void cancel() {
    _client.close();
    _client = http.Client();
  }

  DateTime? _warmAt;

  /// Opens the TLS connection to OpenAI ahead of a likely request (while the user is still speaking).
  /// Sends no key, text or data — just connects. At most once every 10 s.
  void warmUp() {
    final now = DateTime.now();
    if (_warmAt != null && now.difference(_warmAt!) < const Duration(seconds: 10)) return;
    _warmAt = now;
    unawaited(_client.head(Uri.parse('https://api.openai.com/v1/models')).timeout(const Duration(seconds: 5)).then((_) {}, onError: (_) {}));
  }

  /// General chat completion (writing, answers, routing, agent steps).
  Future<({String text, int? input, int? output, int? cached, String? finish, int ms})> chat({
    required String apiKey,
    required String model,
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
      'max_completion_tokens': maxTokens,
      if (json) 'response_format': {'type': 'json_object'},
      'store': false,
    };
    if (blocked) throw SarvamBrainException(blockReason ?? 'OpenAI unavailable', 429);
    final sw = Stopwatch()..start();
    final http.Response res;
    try {
      res = await _client
          .post(Uri.parse(_url),
              headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw SarvamBrainException('OpenAI took too long to answer', 408);
    } on http.ClientException catch (e) {
      throw SarvamBrainException('Network error talking to OpenAI: ${e.message}', 0);
    }
    if (res.statusCode != 200) {
      String? msg;
      try {
        msg = ((jsonDecode(res.body) as Map)['error'] as Map?)?['message'] as String?;
      } catch (_) {}
      _noteFailure(res.statusCode, msg ?? '');
      throw SarvamBrainException(msg ?? 'OpenAI request failed', res.statusCode);
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final choice = (j['choices'] as List?)?.firstOrNull as Map?;
    final usage = j['usage'] as Map?;
    return (
      text: ((choice?['message'] as Map?)?['content'] as String? ?? '').trim(),
      input: usage?['prompt_tokens'] as int?,
      output: usage?['completion_tokens'] as int?,
      cached: (usage?['prompt_tokens_details'] as Map?)?['cached_tokens'] as int?,
      finish: choice?['finish_reason'] as String?,
      ms: sw.elapsedMilliseconds,
    );
  }

  /// One step of a tool-calling conversation. [messages] are OpenAI chat messages (system/user/
  /// assistant-with-tool_calls/tool). Returns the assistant message (to append), its tool calls and usage.
  Future<
      ({
        Map<String, dynamic> message,
        List<({String id, String name, Map<String, dynamic> args})> calls,
        String text,
        int? input,
        int? output,
        int? cached,
        int ms
      })> chatTools({
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    int maxTokens = 300,
  }) async {
    if (blocked) throw SarvamBrainException(blockReason ?? 'OpenAI unavailable', 429);
    final body = {
      'model': model,
      'messages': messages,
      'tools': tools,
      'tool_choice': 'required', // agents always act through a tool (finish_task ends the run)
      'parallel_tool_calls': false, // one UI action at a time, then look again
      'temperature': 0.1,
      'max_completion_tokens': maxTokens,
      'store': false,
    };
    final sw = Stopwatch()..start();
    final http.Response res;
    try {
      res = await _client
          .post(Uri.parse(_url),
              headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw SarvamBrainException('OpenAI took too long to answer', 408);
    } on http.ClientException catch (e) {
      throw SarvamBrainException('Network error talking to OpenAI: ${e.message}', 0);
    }
    if (res.statusCode != 200) {
      String? msg;
      try {
        msg = ((jsonDecode(res.body) as Map)['error'] as Map?)?['message'] as String?;
      } catch (_) {}
      _noteFailure(res.statusCode, msg ?? '');
      throw SarvamBrainException(msg ?? 'OpenAI request failed', res.statusCode);
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final msg = ((j['choices'] as List).first as Map)['message'] as Map<String, dynamic>;
    final calls = <({String id, String name, Map<String, dynamic> args})>[];
    for (final c in (msg['tool_calls'] as List?) ?? const []) {
      final f = (c as Map)['function'] as Map;
      Map<String, dynamic> args;
      try {
        args = (jsonDecode((f['arguments'] as String?) ?? '{}') as Map).cast<String, dynamic>();
      } catch (_) {
        args = const {};
      }
      calls.add((id: c['id'] as String, name: f['name'] as String, args: args));
    }
    final usage = j['usage'] as Map?;
    return (
      message: msg,
      calls: calls,
      text: (msg['content'] as String?) ?? '',
      input: usage?['prompt_tokens'] as int?,
      output: usage?['completion_tokens'] as int?,
      cached: (usage?['prompt_tokens_details'] as Map?)?['cached_tokens'] as int?,
      ms: sw.elapsedMilliseconds,
    );
  }

  Future<Interpretation?> interpret({
    required String apiKey,
    required String model,
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
        // Fixed prefix first → cacheable across requests.
        {'role': 'system', 'content': SarvamBrain.systemPrompt},
        {'role': 'user', 'content': '${ctx.isEmpty ? '' : '$ctx\n'}User said: "$utterance"'},
      ],
      'temperature': 0.1,
      'max_completion_tokens': 300,
      'response_format': {'type': 'json_object'},
      'store': false,
      'prompt_cache_key': 'leo-understand-v1',
    };
    if (blocked) throw SarvamBrainException(blockReason ?? 'OpenAI unavailable', 429);
    final sw = Stopwatch()..start();
    final http.Response res;
    try {
      res = await _client
          .post(Uri.parse(_url),
              headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      return null;
    } on http.ClientException {
      return null;
    }
    if (res.statusCode != 200) {
      String? msg;
      try {
        msg = ((jsonDecode(res.body) as Map)['error'] as Map?)?['message'] as String?;
      } catch (_) {}
      _noteFailure(res.statusCode, msg ?? '');
      throw SarvamBrainException(msg ?? 'OpenAI request failed', res.statusCode);
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final content = (((j['choices'] as List?)?.firstOrNull as Map?)?['message'] as Map?)?['content'] as String? ?? '';
    final usage = j['usage'] as Map?;
    return SarvamBrain.parse(content,
            inputTokens: usage?['prompt_tokens'] as int?,
            outputTokens: usage?['completion_tokens'] as int?,
            cachedTokens: (usage?['prompt_tokens_details'] as Map?)?['cached_tokens'] as int?,
            provider: 'openai',
            model: model)
        .copyWith(latencyMs: sw.elapsedMilliseconds);
  }
}
