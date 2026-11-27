import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class GeminiUsage {
  final int? promptTokens;
  final int? outputTokens;
  final int? thoughtsTokens;
  final int? totalTokens;
  const GeminiUsage({this.promptTokens, this.outputTokens, this.thoughtsTokens, this.totalTokens});
  bool get reported => promptTokens != null || totalTokens != null;
}

class GeminiResult {
  final String text;
  final GeminiUsage usage;
  final String? finishReason;
  const GeminiResult(this.text, this.usage, this.finishReason);
}

class GeminiException implements Exception {
  final String message;
  final int? status;
  GeminiException(this.message, {this.status});
  @override
  String toString() => status == null ? message : '$message (HTTP $status)';
}

/// Minimal REST client for the Gemini API (generativelanguage.googleapis.com).
class GeminiClient {
  static const _base = 'https://generativelanguage.googleapis.com/v1beta';
  http.Client _client = http.Client();

  /// Aborts any in-flight request (used by STOP).
  void cancelInFlight() {
    _client.close();
    _client = http.Client();
  }

  Future<GeminiResult> generate({
    required String apiKey,
    required String model,
    required String systemInstruction,
    required String userText,
    int maxOutputTokens = 512,
    double temperature = 0.6,
    bool json = false,
  }) async {
    final body = <String, dynamic>{
      'systemInstruction': {
        'parts': [
          {'text': systemInstruction}
        ]
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': userText}
          ]
        }
      ],
      'generationConfig': {
        'maxOutputTokens': maxOutputTokens,
        'temperature': temperature,
        if (json) 'responseMimeType': 'application/json',
        // Flash models think by default; for short assistant turns that only burns tokens.
        if (_supportsZeroThinking(model)) 'thinkingConfig': {'thinkingBudget': 0},
      },
    };
    final uri = Uri.parse('$_base/models/${Uri.encodeComponent(model)}:generateContent');
    final client = _client;
    final http.Response res;
    try {
      res = await client
          .post(uri, headers: {'Content-Type': 'application/json', 'x-goog-api-key': apiKey}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 45));
    } on TimeoutException {
      throw GeminiException('Gemini did not respond within 45 seconds');
    } on http.ClientException catch (e) {
      throw GeminiException('Network error talking to Gemini: ${e.message}');
    }
    final decoded = _tryJson(res.body);
    if (res.statusCode != 200) {
      final msg = (decoded?['error']?['message'] as String?) ?? 'Gemini request failed';
      throw GeminiException(msg, status: res.statusCode);
    }
    final usageJson = decoded?['usageMetadata'] as Map<String, dynamic>?;
    final usage = GeminiUsage(
      promptTokens: usageJson?['promptTokenCount'] as int?,
      outputTokens: usageJson?['candidatesTokenCount'] as int?,
      thoughtsTokens: usageJson?['thoughtsTokenCount'] as int?,
      totalTokens: usageJson?['totalTokenCount'] as int?,
    );
    final candidates = decoded?['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      final block = decoded?['promptFeedback']?['blockReason'];
      throw GeminiException(block != null ? 'Gemini blocked the request ($block)' : 'Gemini returned no answer');
    }
    final c = candidates.first as Map<String, dynamic>;
    final parts = (c['content']?['parts'] as List?) ?? const [];
    final text = parts
        .whereType<Map>()
        .where((p) => p['thought'] != true)
        .map((p) => p['text'] as String? ?? '')
        .join()
        .trim();
    return GeminiResult(text, usage, c['finishReason'] as String?);
  }

  /// Lists models available for this key — used by Settings to verify the key and model name.
  Future<List<String>> listModels(String apiKey) async {
    final res = await _client
        .get(Uri.parse('$_base/models?pageSize=200'), headers: {'x-goog-api-key': apiKey})
        .timeout(const Duration(seconds: 20));
    final decoded = _tryJson(res.body);
    if (res.statusCode != 200) {
      throw GeminiException((decoded?['error']?['message'] as String?) ?? 'Request failed', status: res.statusCode);
    }
    final models = (decoded?['models'] as List?) ?? const [];
    return [
      for (final m in models.whereType<Map>())
        if (((m['supportedGenerationMethods'] as List?) ?? const []).contains('generateContent'))
          (m['name'] as String).replaceFirst('models/', '')
    ];
  }

  static bool _supportsZeroThinking(String model) =>
      model.contains('2.5-flash'); // 2.5 Pro cannot disable thinking; other families use other knobs.

  static Map<String, dynamic>? _tryJson(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }
}
