import 'dart:convert';

import '../core/task/task_models.dart';
import 'database.dart';

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
class MemoryRepository {
  final JarvisDatabase _database;
  MemoryRepository(this._database);

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
    return [
      for (final r in rows)
        if ((r['cnt'] as int) > 0)
          SessionSummary(
            r['id'] as int,
            DateTime.fromMillisecondsSinceEpoch(r['started_at'] as int),
            DateTime.fromMillisecondsSinceEpoch(r['last_active_at'] as int),
            r['title'] as String?,
            r['cnt'] as int,
            r['preview'] as String?,
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
    late int id;
    await db.transaction((tx) async {
      id = await tx.insert('messages', {
        'session_id': sessionId,
        'role': role,
        'text': text,
        'created_at': now,
        'source': source,
        'route': route,
        'kind': kind,
      });
      await tx.insert('messages_fts', {'docid': id, 'text': text});
      await tx.update('sessions', {'last_active_at': now}, where: 'id = ?', whereArgs: [sessionId]);
    });
    return StoredMessage(
        id: id, sessionId: sessionId, role: role, text: text,
        createdAt: DateTime.fromMillisecondsSinceEpoch(now), source: source, route: route, kind: kind);
  }

  Future<List<StoredMessage>> messagesOf(int sessionId, {int? limit}) async {
    final rows = await _database.db.query('messages',
        where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'created_at DESC, id DESC', limit: limit);
    return rows.map(StoredMessage.fromRow).toList().reversed.toList();
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
    return rows.map(StoredMessage.fromRow).toList();
  }

  static const _stop = {
    'the', 'a', 'an', 'and', 'or', 'to', 'of', 'in', 'on', 'for', 'is', 'are', 'was', 'were', 'it', 'that', 'this',
    'with', 'my', 'me', 'i', 'you', 'we', 'our', 'what', 'how', 'can', 'do', 'did', 'please', 'jarvis', 'about',
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
    final match = kws.map((k) => '$k*').join(' OR ');
    final rows = await _database.db.rawQuery('''
      SELECT m.* FROM messages_fts f JOIN messages m ON m.id = f.docid
      WHERE messages_fts MATCH ? ${excludeSessionId != null ? 'AND m.session_id != ?' : ''}
      ORDER BY m.created_at DESC LIMIT ?''',
        [match, if (excludeSessionId != null) excludeSessionId, limit]);
    final list = rows.map(StoredMessage.fromRow).toList();
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
  Future<int> insertTask(TaskSnapshot t, int? sessionId) => _database.db.insert('tasks', {
        'session_id': sessionId,
        'title': t.title,
        'kind': t.kind,
        'state': t.state.name,
        'route': t.route.name,
        'steps_json': jsonEncode(t.steps.map((s) => s.toJson()).toList()),
        'params_json': jsonEncode(t.params),
        'result': t.result,
        'created_at': t.createdAt.millisecondsSinceEpoch,
        'updated_at': t.updatedAt.millisecondsSinceEpoch,
      });

  Future<void> updateTask(TaskSnapshot t) => _database.db.update(
        'tasks',
        {
          'title': t.title,
          'state': t.state.name,
          'route': t.route.name,
          'steps_json': jsonEncode(t.steps.map((s) => s.toJson()).toList()),
          'params_json': jsonEncode(t.params),
          'result': t.result,
          'updated_at': t.updatedAt.millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [t.id],
      );

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
    return rows.map(_taskFromRow).toList();
  }

  /// Tasks that were stopped/paused/left waiting — candidates for "continue where you stopped".
  Future<List<TaskSnapshot>> unfinishedTasks() async {
    final rows = await _database.db.query('tasks',
        where: "state IN ('interrupted','paused','waitingForApproval','running','planning','understanding')",
        orderBy: 'updated_at DESC',
        limit: 10);
    return rows.map(_taskFromRow).toList();
  }

  /// After an app restart nothing can still be executing: mark leftovers as interrupted.
  Future<void> markOrphanedTasksInterrupted() => _database.db.rawUpdate(
      "UPDATE tasks SET state = 'interrupted' WHERE state IN ('running','planning','understanding','paused','waitingForApproval')");

  // ------------------------------------------------------------------ facts (explicit, user-approved)
  Future<List<Fact>> facts() async {
    final rows = await _database.db.query('facts', orderBy: 'created_at DESC');
    return [
      for (final r in rows)
        Fact(r['id'] as int, r['text'] as String, DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int))
    ];
  }

  Future<void> addFact(String text) =>
      _database.db.insert('facts', {'text': text, 'created_at': DateTime.now().millisecondsSinceEpoch});

  Future<void> deleteFact(int id) => _database.db.delete('facts', where: 'id = ?', whereArgs: [id]);
  Future<void> deleteAllFacts() => _database.db.delete('facts');

  // ------------------------------------------------------------------ learned intent examples
  /// Stores a (text, label) pair so the on-device intent model handles it locally next time.
  Future<void> addLearnedExample(String text, String label, {required String source}) async {
    final db = _database.db;
    final exists = await db.query('learned_examples', where: 'text = ? AND label = ?', whereArgs: [text, label], limit: 1);
    if (exists.isNotEmpty) return;
    await db.insert('learned_examples', {
      'text': text, 'label': label, 'source': source, 'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<(String, String)>> learnedExamples() async {
    final rows = await _database.db.query('learned_examples', orderBy: 'created_at DESC', limit: 2000);
    return [for (final r in rows) (r['text'] as String, r['label'] as String)];
  }

  Future<int> learnedCount({String? source}) async {
    final r = await _database.db.rawQuery(
        'SELECT COUNT(*) c FROM learned_examples${source == null ? '' : ' WHERE source = ?'}', [if (source != null) source]);
    return (r.first['c'] as int?) ?? 0;
  }

  Future<void> deleteLearnedExamples() => _database.db.delete('learned_examples');

  // ------------------------------------------------------------------ usage
  Future<void> logTokenUsage({
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
        'provider': 'gemini',
        'model': model,
        'purpose': purpose,
        'input_tokens': input,
        'output_tokens': output,
        'thoughts_tokens': thoughts,
        'total_tokens': total,
        'reported': reported ? 1 : 0,
        'ok': ok ? 1 : 0,
      });

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

  Future<void> resetUsage() async {
    await _database.db.delete('token_usage');
    await _database.db.delete('voice_usage');
  }
}
