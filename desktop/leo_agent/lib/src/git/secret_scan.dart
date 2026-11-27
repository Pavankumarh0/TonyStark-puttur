import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'git.dart';

class SecretFinding {
  final String file;
  final String reason; // what was detected — never the secret itself
  final int? line;
  const SecretFinding(this.file, this.reason, {this.line});
  Map<String, Object?> toJson() => {'file': file, 'reason': reason, 'line': line};
}

/// Detects files that must never be committed automatically: by file name, and by scanning the
/// content that would be committed (new lines of a tracked file, or the whole of a new file).
/// A flagged file is excluded from the selection; LEO does not offer to include it.
class SecretScanner {
  static final _blockedNames = <RegExp>[
    RegExp(r'^\.env(\..+)?$', caseSensitive: false),
    RegExp(r'\.(pem|key|p12|pfx|jks|keystore|ppk|dpapi|kdbx)$', caseSensitive: false),
    RegExp(r'^id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$', caseSensitive: false),
    RegExp(r'^(credentials|service[-_]?account|client_secret)[^/]*\.json$', caseSensitive: false),
    RegExp(r'^(secrets?|jarvis_defines|google-services)\.json$', caseSensitive: false),
    RegExp(r'^\.(netrc|pgpass|git-credentials)$', caseSensitive: false),
  ];
  // Templates meant to be committed (contents are still scanned).
  static final _templates = RegExp(r'\.(example|sample|template|dist)$', caseSensitive: false);

  static final _patterns = <(String, RegExp)>[
    ('private key', RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----')),
    ('OpenAI-style API key', RegExp(r'\bsk-(proj-)?[A-Za-z0-9_\-]{20,}')),
    ('API key (sk_…)', RegExp(r'\bsk_[A-Za-z0-9]{20,}')),
    ('GitHub token', RegExp(r'\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{40,}')),
    ('AWS access key', RegExp(r'\b(AKIA|ASIA)[0-9A-Z]{16}\b')),
    ('Google API key', RegExp(r'\bAIza[0-9A-Za-z_\-]{35}\b')),
    ('Slack token', RegExp(r'\bxox[baprs]-[A-Za-z0-9\-]{10,}')),
    ('JSON Web Token', RegExp(r'\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}')),
  ];
  static final _assignment = RegExp(
      r'''(api[_-]?key|secret|token|passw(or)?d|access[_-]?key|auth|private[_-]?key)["']?\s*[:=]\s*["']?([A-Za-z0-9/+_\-\.]{16,})''',
      caseSensitive: false);

  final Git git;
  SecretScanner(this.git);

  static String? nameReason(String path) {
    final name = p.basename(path);
    if (_templates.hasMatch(name)) return null;
    for (final r in _blockedNames) {
      if (r.hasMatch(name)) return 'secret file type ($name)';
    }
    return null;
  }

  static double _entropy(String s) {
    final counts = <int, int>{};
    for (final c in s.codeUnits) {
      counts[c] = (counts[c] ?? 0) + 1;
    }
    var h = 0.0;
    for (final n in counts.values) {
      final pr = n / s.length;
      h -= pr * log(pr) / ln2;
    }
    return h;
  }

  /// Checks text for secrets. Returns (reason, line) of the first hit, or null.
  static (String, int)? scanText(String text) {
    final lines = const LineSplitter().convert(text);
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      for (final (name, re) in _patterns) {
        if (re.hasMatch(l)) return (name, i + 1);
      }
      final m = _assignment.firstMatch(l);
      if (m != null) {
        final v = m.group(3)!;
        final looksPlaceholder = RegExp(r'^(x+|your|example|changeme|placeholder|dummy|test)', caseSensitive: false).hasMatch(v);
        if (!looksPlaceholder && _entropy(v) >= 3.5) return ('high-entropy value assigned to "${m.group(1)}"', i + 1);
      }
    }
    return null;
  }

  /// Scans what would be committed for each of [files] in [repo].
  Future<List<SecretFinding>> scan(String repo, List<String> files) async {
    final out = <SecretFinding>[];
    final st = await git.status(repo);
    for (final f in files) {
      final byName = nameReason(f);
      if (byName != null) {
        out.add(SecretFinding(f, byName));
        continue;
      }
      final entry = st.files.where((x) => x.path == f).firstOrNull;
      if (entry == null || entry.kind == 'deleted') continue;
      String added;
      if (entry.untracked) {
        final file = File(p.join(repo, f));
        if (!file.existsSync() || file.lengthSync() > 2 * 1024 * 1024) continue;
        final bytes = file.readAsBytesSync();
        if (bytes.contains(0)) continue; // binary
        added = utf8.decode(bytes, allowMalformed: true);
      } else {
        // Only lines being added: removing a leaked secret must not be blocked.
        added = (await git.diff(repo, f, maxBytes: 2 * 1024 * 1024))
            .split('\n')
            .where((l) => l.startsWith('+') && !l.startsWith('+++'))
            .map((l) => l.substring(1))
            .join('\n');
      }
      final hit = scanText(added);
      if (hit != null) out.add(SecretFinding(f, hit.$1, line: entry.untracked ? hit.$2 : null));
    }
    return out;
  }
}
