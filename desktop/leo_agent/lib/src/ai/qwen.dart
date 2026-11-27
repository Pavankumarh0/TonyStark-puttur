import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:leo_core/leo_core.dart';

/// Qwen running locally in Ollama (http://127.0.0.1:11434). Prompts never leave this PC.
class Qwen {
  final String model;
  final Uri base;
  final Duration timeout;
  Qwen({this.model = 'qwen2.5:3b', String host = 'http://127.0.0.1:11434', this.timeout = const Duration(seconds: 45)})
      : base = Uri.parse(host);

  Future<bool> available() async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final r = await (await c.getUrl(base.resolve('/api/tags'))).close().timeout(const Duration(seconds: 3));
      await r.drain<void>();
      c.close();
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// One chat completion. Throws on failure so callers can fall back.
  Future<String> chat(String system, String user, {int maxTokens = 120, double temperature = 0.2}) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await c.postUrl(base.resolve('/api/chat'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'model': model,
        'stream': false,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
        'options': {'temperature': temperature, 'num_predict': maxTokens},
      }));
      final res = await req.close().timeout(timeout);
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      if (res.statusCode != 200) throw StateError('Ollama ${res.statusCode}');
      return ((jsonDecode(body) as Map)['message'] as Map)['content'] as String;
    } finally {
      c.close(force: true);
    }
  }
}

/// Writes commit messages with Qwen from a diff summary; deterministic fallback if Qwen is down.
class CommitMessageWriter {
  final Qwen qwen;
  CommitMessageWriter(this.qwen);

  static const _system =
      'You write git commit messages. Reply with ONLY the message: an imperative subject line of at most '
      '72 characters (e.g. "Add login screen validation"), then optionally a blank line and up to 3 short '
      'bullet lines. No quotes, no code fences, no prefix like "Commit message:".';

  static String fallback(List<String> files) {
    final names = files.map((f) => f.split(RegExp(r'[\\/]')).last).toList();
    final shown = names.take(3).join(', ');
    return names.length <= 3 ? 'Update $shown' : 'Update $shown and ${names.length - 3} more';
  }

  static String clean(String raw) {
    var s = raw.trim().replaceAll(RegExp(r'^```[a-z]*\n?|```$', multiLine: true), '').trim();
    s = s.replaceFirst(RegExp(r'^(commit message|message)\s*:\s*', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'''^["'`]+|["'`]+$'''), '').trim();
    final lines = s.split('\n');
    var subject = lines.first.trim().replaceAll(RegExp(r'''^["'`]+|["'`]+$'''), '').trim();
    if (subject.length > 72) subject = '${subject.substring(0, 69).trimRight()}...';
    // Body: bullet lines only. Small models sometimes echo the prompt ("Files changed:", diff stat
    // lines with "|", "+/-" diff lines) — none of that belongs in a commit message.
    final body = lines
        .skip(1)
        .map((l) => l.trimRight())
        .where((l) => RegExp(r'^\s*[-*•] \S').hasMatch(l) && !l.contains('|') && !RegExp(r'files? changed|insertion|deletion', caseSensitive: false).hasMatch(l))
        .take(3)
        .toList();
    return body.isEmpty ? subject : '$subject\n\n${body.join('\n')}';
  }

  /// Returns (message, source) where source is "qwen" or "fallback".
  Future<(String, String)> write({required String stat, required String diff, required List<String> files}) async {
    // Masked like any model input (local, but logs/prompts should still not carry identifiers).
    final masked = PrivacyFilter.redact(diff.length > 6000 ? '${diff.substring(0, 6000)}\n…' : diff, messageBodies: false).text;
    try {
      final out = await qwen.chat(_system, 'Files changed:\n$stat\n\nDiff:\n$masked');
      final msg = clean(out);
      if (msg.length >= 8) return (msg, 'qwen');
    } catch (_) {}
    return (fallback(files), 'fallback');
  }
}
