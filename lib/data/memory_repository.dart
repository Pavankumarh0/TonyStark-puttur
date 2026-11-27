import 'dart:convert';

import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../core/task/task_models.dart';
import 'database.dart';
import 'vault.dart';

class StoredMessage {
  final int id;
  final int sessionId;
  final String role; // user | jarvis | system
  final String text;
  final DateTime createdAt;
  final String? source;
  final String? route;
  final String? kind;

  const StoredMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.text,
    required this.createdAt,
    this.source,
    this.route,
    this.kind,
  });

  bool get isUser => role == 'user';

  factory StoredMessage.fromRow(Map<String, Object?> r) => StoredMessage(
        id: r['id'] as int,
        sessionId: r['session_id'] as int,
        role: r['role'] as String,
        text: r['text'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        source: r['source'] as String?,
        route: r['route'] as String?,
        kind: r['kind'] as String?,
      );
}

class SessionSummary {
  final int id;
  final DateTime startedAt;
  final DateTime lastActiveAt;
  final String? title;
  final int messageCount;
  final String? preview;
  const SessionSummary(this.id, this.startedAt, this.lastActiveAt, this.title, this.messageCount, this.preview);
}

class Fact {
  final int id;
  final String text;
  final DateTime createdAt;
  const Fact(this.id, this.text, this.createdAt);
}

class UsageTotals {
  final int geminiRequests;
  final int geminiFailures;
  final int inputTokens;
  final int outputTokens;
  final int thoughtsTokens;
  final int totalTokens;
  final int unreportedRequests;
  final int localTasks;
  final int aiTasks;
  final int sttRequests;
  final double sttSeconds;
  final int ttsRequests;
  final int ttsChars;
  final Map<String, int> tokensByPurpose;
  const UsageTotals({
    required this.geminiRequests,
    required this.geminiFailures,
    required this.inputTokens,
    required this.outputTokens,
    required this.thoughtsTokens,
    required this.totalTokens,
    required this.unreportedRequests,
    required this.localTasks,
    required this.aiTasks,
    required this.sttRequests,
    required this.sttSeconds,
    required this.ttsRequests,
    required this.ttsChars,
    required this.tokensByPurpose,
  });
}

/// Persistent conversation history, task history, explicit facts and usage logs.
/// Every private field is encrypted with AES-256-GCM before it reaches SQLite (see [Vault]);
/// the search index holds only keyed HMAC tokens. Counters/timestamps stay in the clear.
class MemoryRepository {
  final JarvisDatabase _database;
  final Vault vault;
  MemoryRepository(this._database, this.vault);

  // Associated Data per column: a ciphertext only decrypts in the field it was written to.
  static const aMsg = 'messages.text', aTitle = 'sessions.title', aTaskTitle = 'tasks.title', aSteps = 'tasks.steps',
      aParams = 'tasks.params', aResult = 'tasks.result', aFact = 'facts.text', aLearned = 'learned.text',
      aCloud = 'cloud_log.sent_text';

  /// Every keyword of [text] (for the search index).
  static List<String> indexWords(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9 ]"), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.length > 2 && !_stop.contains(w))
      .toSet()
      .toList();

  /// Search tokens for [text]: every keyword, blinded with the vault's HMAC key.
  Future<String> _index(String text) async => (await vault.blind(indexWords(text))).join(' ');

  Future<List<StoredMessage>> _decryptMessages(List<Map<String, Object?>> rows) async {
    final plain = await vault.open([for (final r in rows) r['text'] as String?], aMsg);
    return [
      for (var i = 0; i < rows.length; i++)
        if (plain[i] != null) StoredMessage.fromRow({...rows[i], 'text': plain[i]})
    ];
  }

  static const sessionGap = Duration(minutes: 30);

  // ------------------------------------------------------------------ sessions
  /// Continues the most recent session if it was active recently, otherwise starts a new one.
  Future<int> resumeOrStartSession() async {
    final db = _database.db;
    final rows = await db.query('sessions', orderBy: 'last_active_at DESC', limit: 1);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (rows.isNotEmpty) {
      final last = rows.first['last_active_at'] as int;
      if (now - last < sessionGap.inMilliseconds) return rows.first['id'] as int;
    }
    return db.insert('sessions', {'started_at': now, 'last_active_at': now});
  }

  Future<DateTime?> lastInteraction() async {
    final r = await _database.db.rawQuery('SELECT MAX(created_at) m FROM messages WHERE role = ?', ['user']);
    final v = r.first['m'] as int?;
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }

  Future<List<SessionSummary>> sessions({int limit = 100}) async {
    final rows = await _database.db.rawQuery('''
      SELECT s.id, s.started_at, s.last_active_at, s.title,
        (SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id) AS cnt,
        (SELECT text FROM messages m WHERE m.session_id = s.id AND m.role = 'user' ORDER BY created_at LIMIT 1) AS preview
      FROM sessions s ORDER BY s.last_active_at DESC LIMIT ?''', [limit]);
    final live = rows.where((r) => (r['cnt'] as int) > 0).toList();
    final titles = await vault.open([for (final r in live) r['title'] as String?], aTitle);
    final previews = await vault.open([for (final r in live) r['preview'] as String?], aMsg);
    return [
      for (var i = 0; i < live.length; i++)
        SessionSummary(
          live[i]['id'] as int,
          DateTime.fromMillisecondsSinceEpoch(live[i]['started_at'] as int),
          DateTime.fromMillisecondsSinceEpoch(live[i]['last_active_at'] as int),
          titles[i],
          live[i]['cnt'] as int,
          previews[i],
        )
    ];
  }

  Future<void> deleteSession(int id) async {
    final db = _database.db;
    await db.transaction((tx) async {
      await tx.rawDelete('DELETE FROM messages_fts WHERE docid IN (SELECT id FROM messages WHERE session_id = ?)', [id]);
      await tx.delete('messages', where: 'session_id = ?', whereArgs: [id]);
      await tx.delete('sessions', where: 'id = ?', whereArgs: [id]);
    });
  }

  // ------------------------------------------------------------------ messages
  Future<StoredMessage> addMessage({
    required int sessionId,
    required String role,
    required String text,
    String? source,
    String? route,
    String? kind,
  }) async {
    final db = _database.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    final sealed = await vault.seal1(text, aMsg);
    final index = await _index(text);
    late int id;
    await db.transaction((tx) async {
      id = await tx.insert('messages', {
        'session_id': sessionId,
        'role': role,
        'text': sealed,
        'created_at': now,
        'source': source,
        'route': route,
        'kind': kind,
      });
      await tx.insert('messages_fts', {'docid': id, 'text': index});
      await tx.update('sessions', {'last_active_at': now}, where: 'id = ?', whereArgs: [sessionId]);
    });
    return StoredMessage(
        id: id, sessionId: sessionId, role: role, text: text,
        createdAt: DateTime.fromMillisecondsSinceEpoch(now), source: source, route: route, kind: kind);
  }

  Future<List<StoredMessage>> messagesOf(int sessionId, {int? limit}) async {
    final rows = await _database.db.query('messages',
        where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'created_at DESC, id DESC', limit: limit);
    return (await _decryptMessages(rows)).reversed.toList();
  }

  /// Messages from sessions other than [currentSessionId], newest first.
  Future<List<StoredMessage>> previousMessages(int currentSessionId, {int limit = 20, String? role, List<String>? kinds}) async {
    final where = StringBuffer('session_id != ?');
    final args = <Object?>[currentSessionId];
    if (role != null) {
      where.write(' AND role = ?');
      args.add(role);
    }
    if (kinds != null && kinds.isNotEmpty) {
      where.write(' AND kind IN (${List.filled(kinds.length, '?').join(',')})');
      args.addAll(kinds);
    }
    final rows = await _database.db.query('messages',
        where: where.toString(), whereArgs: args, orderBy: 'created_at DESC', limit: limit);
    return _decryptMessages(rows);
  }

  static const _stop = {
    'the', 'a', 'an', 'and', 'or', 'to', 'of', 'in', 'on', 'for', 'is', 'are', 'was', 'were', 'it', 'that', 'this',
    'with', 'my', 'me', 'i', 'you', 'we', 'our', 'what', 'how', 'can', 'do', 'did', 'please', 'jarvis', 'leo', 'about',
    'be', 'at', 'as', 'by', 'from', 'your', 'tell', 'give', 'make', 'write', 'some', 'any', 'have', 'has', 'had',
    'will', 'would', 'should', 'could', 'just', 'so', 'if', 'then', 'there', 'they', 'them', 'he', 'she', 'his',
    'her', 'its', 'im', "i'm", 'us', 'yes', 'no', 'not', 'sir', 'get', 'got', 'want', 'need', 'like',
  };

  static List<String> keywords(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9 ]"), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.length > 2 && !_stop.contains(w))
      .toSet()
      .take(8)
      .toList();

  /// Full-text search across all conversations (used by history search and context retrieval).
  Future<List<StoredMessage>> search(String query, {int limit = 30, int? excludeSessionId}) async {
    final kws = keywords(query);
    if (kws.isEmpty) return [];
    // Exact-word match on blinded tokens (the index holds no readable words, so no prefix search).
    final match = (await vault.blind(kws)).join(' OR ');
    final rows = await _database.db.rawQuery('''
      SELECT m.* FROM messages_fts f JOIN messages m ON m.id = f.docid
      WHERE messages_fts MATCH ? ${excludeSessionId != null ? 'AND m.session_id != ?' : ''}
      ORDER BY m.created_at DESC LIMIT ?''',
        [match, if (excludeSessionId != null) excludeSessionId, limit]);
    final list = await _decryptMessages(rows);
    // Rank by keyword overlap, then recency.
    int score(StoredMessage m) {
      final t = m.text.toLowerCase();
      return kws.where((k) => t.contains(k)).length;
    }

    list.sort((a, b) {
      final s = score(b).compareTo(score(a));
      return s != 0 ? s : b.createdAt.compareTo(a.createdAt);
    });
    return list;
  }

  Future<void> deleteAllConversations() async {
    final db = _database.db;
    await db.transaction((tx) async {
      await tx.delete('messages_fts');
      await tx.delete('messages');
      await tx.delete('sessions');
      await tx.delete('tasks');
    });
  }

  // ------------------------------------------------------------------ tasks
  Future<Map<String, Object?>> _sealTask(TaskSnapshot t) async => {
        'title': await vault.seal1(t.title, aTaskTitle),
        'steps_json': await vault.seal1(jsonEncode(t.steps.map((s) => s.toJson()).toList()), aSteps),
        'params_json': await vault.seal1(jsonEncode(t.params), aParams),
        'result': await vault.seal1(t.result, aResult),
      };

  Future<int> insertTask(TaskSnapshot t, int? sessionId) async => _database.db.insert('tasks', {
        'session_id': sessionId,
        ...await _sealTask(t),
        'kind': t.kind,
        'state': t.state.name,
        'route': t.route.name,
        'created_at': t.createdAt.millisecondsSinceEpoch,
        'updated_at': t.updatedAt.millisecondsSinceEpoch,
      });

  Future<void> updateTask(TaskSnapshot t) async => _database.db.update(
        'tasks',
        {
          ...await _sealTask(t),
          'state': t.state.name,
          'route': t.route.name,
          'updated_at': t.updatedAt.millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [t.id],
      );

  Future<List<TaskSnapshot>> _decryptTasks(List<Map<String, Object?>> rows) async {
    final ti = await vault.open([for (final r in rows) r['title'] as String?], aTaskTitle);
    final st = await vault.open([for (final r in rows) r['steps_json'] as String?], aSteps);
    final pa = await vault.open([for (final r in rows) r['params_json'] as String?], aParams);
    final re = await vault.open([for (final r in rows) r['result'] as String?], aResult);
    return [
      for (var i = 0; i < rows.length; i++)
        if (ti[i] != null && st[i] != null && pa[i] != null)
          _taskFromRow({...rows[i], 'title': ti[i], 'steps_json': st[i], 'params_json': pa[i], 'result': re[i]})
    ];
  }

  TaskSnapshot _taskFromRow(Map<String, Object?> r) => TaskSnapshot(
        id: r['id'] as int,
        title: r['title'] as String,
        kind: r['kind'] as String,
        state: AgentState.values.byName(r['state'] as String),
        route: TaskRoute.values.byName(r['route'] as String),
        steps: (jsonDecode(r['steps_json'] as String) as List)
            .map((e) => TaskStep.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        params: Map<String, dynamic>.from(jsonDecode(r['params_json'] as String) as Map),
        result: r['result'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
      );

  Future<List<TaskSnapshot>> tasks({int limit = 50}) async {
    final rows = await _database.db.query('tasks', orderBy: 'updated_at DESC', limit: limit);
    return _decryptTasks(rows);
  }

  /// Tasks that were stopped/paused/left waiting — candidates for "continue where you stopped".
  Future<List<TaskSnapshot>> unfinishedTasks() async {
    final rows = await _database.db.query('tasks',
        where: "state IN ('interrupted','paused','waitingForApproval','running','planning','understanding')",
        orderBy: 'updated_at DESC',
        limit: 10);
    return _decryptTasks(rows);
  }

  /// After an app restart nothing can still be executing: mark leftovers as interrupted.
  Future<void> markOrphanedTasksInterrupted() => _database.db.rawUpdate(
      "UPDATE tasks SET state = 'interrupted' WHERE state IN ('running','planning','understanding','paused','waitingForApproval')");

  // ------------------------------------------------------------------ facts (explicit, user-approved)
  Future<List<Fact>> facts() async {
    final rows = await _database.db.query('facts', orderBy: 'created_at DESC');
    final texts = await vault.open([for (final r in rows) r['text'] as String?], aFact);
    return [
      for (var i = 0; i < rows.length; i++)
        if (texts[i] != null)
          Fact(rows[i]['id'] as int, texts[i]!, DateTime.fromMillisecondsSinceEpoch(rows[i]['created_at'] as int))
    ];
  }

  Future<void> addFact(String text) async => _database.db
      .insert('facts', {'text': await vault.seal1(text, aFact), 'created_at': DateTime.now().millisecondsSinceEpoch});

  Future<void> deleteFact(int id) => _database.db.delete('facts', where: 'id = ?', whereArgs: [id]);
  Future<void> deleteAllFacts() => _database.db.delete('facts');

  // ------------------------------------------------------------------ learned intent examples
  /// Stores a (text, label) pair so the on-device intent model handles it locally next time.
  Future<void> addLearnedExample(String text, String label, {required String source}) async {
    final db = _database.db;
    // Ciphertexts differ every time, so de-duplicate on the decrypted values.
    if ((await learnedExamples()).any((e) => e.$1 == text && e.$2 == label)) return;
    await db.insert('learned_examples', {
      'text': await vault.seal1(text, aLearned), 'label': label, 'source': source,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<(String, String)>> learnedExamples() async {
    final rows = await _database.db.query('learned_examples', orderBy: 'created_at DESC', limit: 2000);
    final texts = await vault.open([for (final r in rows) r['text'] as String?], aLearned);
    return [
      for (var i = 0; i < rows.length; i++)
        if (texts[i] != null) (texts[i]!, rows[i]['label'] as String)
    ];
  }

  Future<int> learnedCount({String? source}) async {
    final r = await _database.db.rawQuery(
        'SELECT COUNT(*) c FROM learned_examples${source == null ? '' : ' WHERE source = ?'}', [if (source != null) source]);
    return (r.first['c'] as int?) ?? 0;
  }

  Future<void> deleteLearnedExamples() => _database.db.delete('learned_examples');

  // ------------------------------------------------------------------ usage
  Future<void> logTokenUsage({
    String provider = 'gemini',
    required String model,
    required String purpose,
    int? input,
    int? output,
    int? thoughts,
    int? total,
    required bool reported,
    required bool ok,
  }) =>
      _database.db.insert('token_usage', {
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'provider': provider,
        'model': model,
        'purpose': purpose,
        'input_tokens': input,
        'output_tokens': output,
        'thoughts_tokens': thoughts,
        'total_tokens': total,
        'reported': reported ? 1 : 0,
        'ok': ok ? 1 : 0,
      });

  Future<void> logCloud({
    required String provider,
    required String model,
    required String purpose,
    required String sentText,
    required int maskedCount,
    int? input,
    int? output,
    int? cached,
    double? cost,
    String? currency,
    int? latencyMs,
    required bool ok,
  }) async =>
      _database.db.insert('cloud_log', {
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'provider': provider,
        'model': model,
        'purpose': purpose,
        'sent_text': await vault.seal1(sentText, aCloud),
        'masked_count': maskedCount,
        'input_tokens': input,
        'output_tokens': output,
        'cached_tokens': cached,
        'cost': cost,
        'currency': currency,
        'latency_ms': latencyMs,
        'ok': ok ? 1 : 0,
      });

  Future<List<Map<String, Object?>>> cloudLog({int limit = 50}) async {
    final rows = await _database.db.query('cloud_log', orderBy: 'created_at DESC', limit: limit);
    final sent = await vault.open([for (final r in rows) r['sent_text'] as String?], aCloud);
    return [for (var i = 0; i < rows.length; i++) {...rows[i], 'sent_text': sent[i] ?? '(unreadable)'}];
  }

  Future<void> clearCloudLog() => _database.db.delete('cloud_log');

  Future<void> logVoiceUsage(String kind, double units, bool ok) => _database.db.insert('voice_usage', {
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'kind': kind,
        'provider': 'sarvam',
        'units': units,
        'ok': ok ? 1 : 0,
      });

  Future<UsageTotals> usageTotals() async {
    final db = _database.db;
    final t = (await db.rawQuery('''
      SELECT COUNT(*) n, SUM(CASE WHEN ok = 0 THEN 1 ELSE 0 END) f,
        COALESCE(SUM(input_tokens),0) i, COALESCE(SUM(output_tokens),0) o,
        COALESCE(SUM(thoughts_tokens),0) th, COALESCE(SUM(total_tokens),0) tot,
        SUM(CASE WHEN reported = 0 AND ok = 1 THEN 1 ELSE 0 END) u
      FROM token_usage''')).first;
    final byPurpose = await db.rawQuery(
        'SELECT purpose, COALESCE(SUM(total_tokens),0) tot FROM token_usage GROUP BY purpose ORDER BY tot DESC');
    final tasks = (await db.rawQuery('''
      SELECT SUM(CASE WHEN route='local' THEN 1 ELSE 0 END) l, SUM(CASE WHEN route='ai' THEN 1 ELSE 0 END) a
      FROM tasks WHERE state = 'completed' ''')).first;
    final v = (await db.rawQuery('''
      SELECT SUM(CASE WHEN kind='stt' THEN 1 ELSE 0 END) sn, COALESCE(SUM(CASE WHEN kind='stt' THEN units END),0) su,
             SUM(CASE WHEN kind='tts' THEN 1 ELSE 0 END) tn, COALESCE(SUM(CASE WHEN kind='tts' THEN units END),0) tu
      FROM voice_usage''')).first;
    int i(Object? o) => (o as num?)?.toInt() ?? 0;
    return UsageTotals(
      geminiRequests: i(t['n']),
      geminiFailures: i(t['f']),
      inputTokens: i(t['i']),
      outputTokens: i(t['o']),
      thoughtsTokens: i(t['th']),
      totalTokens: i(t['tot']),
      unreportedRequests: i(t['u']),
      localTasks: i(tasks['l']),
      aiTasks: i(tasks['a']),
      sttRequests: i(v['sn']),
      sttSeconds: (v['su'] as num?)?.toDouble() ?? 0,
      ttsRequests: i(v['tn']),
      ttsChars: i(v['tu']),
      tokensByPurpose: {for (final r in byPurpose) r['purpose'] as String: i(r['tot'])},
    );
  }

  // ------------------------------------------------------------------ one-time migration
  /// Encrypts rows written before encryption existed, rebuilds the search index with blinded
  /// tokens, then VACUUMs so the old plaintext is not left behind in free database pages.
  /// Idempotent: does nothing once every value is sealed. Returns the number of values encrypted.
  Future<int> migratePlaintext() async {
    final db = _database.db;
    var changed = 0;
    const cols = <(String, String, String)>[
      ('messages', 'text', aMsg), ('sessions', 'title', aTitle), ('tasks', 'title', aTaskTitle),
      ('tasks', 'steps_json', aSteps), ('tasks', 'params_json', aParams), ('tasks', 'result', aResult),
      ('facts', 'text', aFact), ('learned_examples', 'text', aLearned), ('cloud_log', 'sent_text', aCloud),
    ];
    for (final (table, col, aad) in cols) {
      final rows = await db.rawQuery("SELECT id, $col v FROM $table WHERE $col IS NOT NULL AND $col NOT LIKE 'v1:%'");
      if (rows.isEmpty) continue;
      final sealed = await vault.seal([for (final r in rows) r['v'] as String], aad);
      await db.transaction((tx) async {
        for (var i = 0; i < rows.length; i++) {
          await tx.update(table, {col: sealed[i]}, where: 'id = ?', whereArgs: [rows[i]['id']]);
        }
      });
      changed += rows.length;
    }
    await db.execute('CREATE TABLE IF NOT EXISTS security_meta(k TEXT PRIMARY KEY, v TEXT)');
    final done = await db.query('security_meta', where: 'k = ?', whereArgs: ['search_index'], limit: 1);
    if (changed > 0 || done.isEmpty || done.first['v'] != 'blind-v1') {
      await rebuildSearchIndex();
      await db.insert('security_meta', {'k': 'search_index', 'v': 'blind-v1'}, conflictAlgorithm: ConflictAlgorithm.replace);
      changed++;
    }
    if (changed > 0) await db.execute('VACUUM'); // drop old plaintext pages from the file
    return changed;
  }

  /// Recreates the full-text index from scratch with blinded tokens. (Deleting rows from an FTS4
  /// index leaves the old terms inside its segment b-trees until they merge — a fresh table doesn't.)
  Future<void> rebuildSearchIndex() async {
    final db = _database.db;
    final rows = await db.rawQuery('SELECT id, text FROM messages');
    final plain = await vault.open([for (final r in rows) r['text'] as String?], aMsg);
    final tokens = <String>[];
    for (final p in plain) {
      tokens.add(p == null ? '' : await _index(p));
    }
    await db.transaction((tx) async {
      await tx.execute('DROP TABLE IF EXISTS messages_fts');
      await tx.execute('CREATE VIRTUAL TABLE messages_fts USING fts4(text)');
      for (var i = 0; i < rows.length; i++) {
        if (tokens[i].isNotEmpty) await tx.insert('messages_fts', {'docid': rows[i]['id'], 'text': tokens[i]});
      }
    });
  }

  // ------------------------------------------------------------------ retention & deletion
  /// Deletes conversations, tasks, the privacy ledger and learned phrases older than [days].
  /// Explicit "remember this" facts are kept until the user deletes them. Returns rows removed.
  Future<int> purgeOlderThan(int days) async {
    if (days <= 0) return 0;
    final cutoff = DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch;
    var n = 0;
    await _database.db.transaction((tx) async {
      await tx.rawDelete('DELETE FROM messages_fts WHERE docid IN (SELECT id FROM messages WHERE created_at < ?)', [cutoff]);
      n += await tx.delete('messages', where: 'created_at < ?', whereArgs: [cutoff]);
      await tx.rawDelete('DELETE FROM sessions WHERE id NOT IN (SELECT DISTINCT session_id FROM messages) AND last_active_at < ?', [cutoff]);
      n += await tx.delete('tasks', where: 'updated_at < ?', whereArgs: [cutoff]);
      n += await tx.delete('cloud_log', where: 'created_at < ?', whereArgs: [cutoff]);
      n += await tx.delete('learned_examples', where: 'created_at < ?', whereArgs: [cutoff]);
    });
    return n;
  }

  /// Everything LEO stored about the user, deleted; then the encryption keys are destroyed and
  /// replaced (crypto-shredding), so even leftovers in free disk pages can never be decrypted.
  Future<void> deleteEverything() async {
    await _database.db.transaction((tx) async {
      for (final t in ['messages_fts', 'messages', 'sessions', 'tasks', 'facts', 'learned_examples', 'cloud_log', 'token_usage', 'voice_usage']) {
        await tx.delete(t);
      }
    });
    await _database.db.execute('VACUUM');
    await vault.wipe();
  }

  Future<void> resetUsage() async {
    await _database.db.delete('token_usage');
    await _database.db.delete('voice_usage');
  }
}
