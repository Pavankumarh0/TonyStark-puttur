import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:leo_core/leo_core.dart';
import 'package:path/path.dart' as p;

/// Append-only, hash-chained audit log (JSON Lines, one file per month).
///
/// Every entry carries the SHA-256 of the previous entry, so editing, deleting or reordering any
/// line breaks the chain and [verify] reports where. Entries record WHAT happened (action, task id,
/// decision, counts, commit hashes) — never prompts, diffs, file contents, messages or keys:
/// free-text fields are masked and cut to 120 characters, and only scalar values are accepted.
class AuditLog {
  final String dir;
  String _prev = '0' * 64;
  int _seq = 0;
  final _listeners = <void Function(Map<String, dynamic>)>[];

  AuditLog(this.dir) {
    Directory(dir).createSync(recursive: true);
    final last = _lastEntry();
    if (last != null) {
      _prev = last['hash'] as String;
      _seq = last['seq'] as int;
    }
  }

  void addListener(void Function(Map<String, dynamic>) f) => _listeners.add(f);

  String get _file {
    final n = DateTime.now().toUtc();
    return p.join(dir, 'audit-${n.year}-${n.month.toString().padLeft(2, '0')}.jsonl');
  }

  List<File> _files() =>
      (Directory(dir).listSync().whereType<File>().where((f) => p.basename(f.path).startsWith('audit-')).toList()
        ..sort((a, b) => a.path.compareTo(b.path)));

  Map<String, dynamic>? _lastEntry() {
    for (final f in _files().reversed) {
      final lines = f.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      if (lines.isNotEmpty) return jsonDecode(lines.last) as Map<String, dynamic>;
    }
    return null;
  }

  static Object? _clean(Object? v) {
    if (v == null || v is num || v is bool) return v;
    final s = PrivacyFilter.redact('$v').text.replaceAll(RegExp(r'\s+'), ' ');
    return s.length > 120 ? '${s.substring(0, 117)}...' : s;
  }

  static String _hash(Map<String, dynamic> e) {
    final copy = Map<String, dynamic>.from(e)..remove('hash');
    return sha256.convert(utf8.encode(jsonEncode(copy))).toString();
  }

  /// Records one event. [fields] must be scalars (strings are masked + truncated).
  Map<String, dynamic> record(String action, {String actor = 'agent', Map<String, Object?> fields = const {}}) {
    final e = <String, dynamic>{
      'seq': ++_seq,
      'ts': DateTime.now().toUtc().toIso8601String(),
      'actor': actor,
      'action': action,
      for (final kv in fields.entries) kv.key: _clean(kv.value),
      'prev': _prev,
    };
    e['hash'] = _hash(e);
    _prev = e['hash'] as String;
    File(_file).writeAsStringSync('${jsonEncode(e)}\n', mode: FileMode.append, flush: true);
    for (final l in List.of(_listeners)) {
      l(e);
    }
    return e;
  }

  List<Map<String, dynamic>> tail(int n) {
    final out = <Map<String, dynamic>>[];
    for (final f in _files().reversed) {
      final lines = f.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList().reversed;
      for (final l in lines) {
        out.add(jsonDecode(l) as Map<String, dynamic>);
        if (out.length >= n) return out.reversed.toList();
      }
    }
    return out.reversed.toList();
  }

  /// Re-computes the whole chain. Returns (ok, entries checked, first broken seq or null).
  ({bool ok, int checked, int? brokenAt}) verify() {
    var prev = '0' * 64;
    var n = 0;
    for (final f in _files()) {
      for (final l in f.readAsLinesSync().where((l) => l.trim().isNotEmpty)) {
        Map<String, dynamic> e;
        try {
          e = jsonDecode(l) as Map<String, dynamic>;
        } catch (_) {
          return (ok: false, checked: n, brokenAt: n + 1);
        }
        n++;
        if (e['prev'] != prev || e['hash'] != _hash(e)) return (ok: false, checked: n, brokenAt: e['seq'] as int? ?? n);
        prev = e['hash'] as String;
      }
    }
    return (ok: true, checked: n, brokenAt: null);
  }
}
