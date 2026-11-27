import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Local, persistent store. Nothing here leaves the device.
class JarvisDatabase {
  static const _version = 3;
  Database? _db;

  Database get db => _db ?? (throw StateError('Database not opened'));


  static Future<void> _createLearned(Database d) => d.execute('''
        CREATE TABLE IF NOT EXISTS learned_examples(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          text TEXT NOT NULL,
          label TEXT NOT NULL,
          source TEXT NOT NULL,        -- local | ai (learned from an AI routing decision)
          created_at INTEGER NOT NULL
        )''');

  /// Privacy ledger: what left the phone, already redacted, and what it cost.
  static Future<void> _createCloudLog(Database d) => d.execute('''
        CREATE TABLE IF NOT EXISTS cloud_log(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          created_at INTEGER NOT NULL,
          provider TEXT NOT NULL,       -- openai (brain) | sarvam
          model TEXT NOT NULL,
          purpose TEXT NOT NULL,        -- understand
          sent_text TEXT NOT NULL,      -- exactly what was sent (after masking)
          masked_count INTEGER NOT NULL,
          input_tokens INTEGER,
          output_tokens INTEGER,
          cached_tokens INTEGER,
          cost REAL,
          currency TEXT,
          latency_ms INTEGER,
          ok INTEGER NOT NULL
        )''');

  Future<void> open() async {
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'jarvis.db'),
      version: _version,
      onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      onUpgrade: (d, from, to) async {
        if (from < 2) await _createLearned(d);
        if (from < 3) await _createCloudLog(d);
      },
      onCreate: (d, v) async {
        await d.execute('''
          CREATE TABLE sessions(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at INTEGER NOT NULL,
            last_active_at INTEGER NOT NULL,
            title TEXT
          )''');
        await d.execute('''
          CREATE TABLE messages(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            role TEXT NOT NULL,          -- user | jarvis | system
            text TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            source TEXT,                 -- voice | text
            route TEXT,                  -- local | ai
            kind TEXT                    -- intent kind, e.g. knowledge, command, statement
          )''');
        await d.execute('CREATE INDEX idx_messages_session ON messages(session_id, created_at)');
        // Full-text index for conversation search & relevant-context retrieval. docid = messages.id
        await d.execute('CREATE VIRTUAL TABLE messages_fts USING fts4(text)');
        await d.execute('''
          CREATE TABLE tasks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER,
            title TEXT NOT NULL,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            route TEXT NOT NULL,
            steps_json TEXT NOT NULL,
            params_json TEXT NOT NULL,
            result TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )''');
        await d.execute('''
          CREATE TABLE facts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )''');
        await d.execute('''
          CREATE TABLE token_usage(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at INTEGER NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            purpose TEXT NOT NULL,
            input_tokens INTEGER,
            output_tokens INTEGER,
            thoughts_tokens INTEGER,
            total_tokens INTEGER,
            reported INTEGER NOT NULL,   -- 1 = numbers came from provider usage metadata
            ok INTEGER NOT NULL
          )''');
        await d.execute('''
          CREATE TABLE voice_usage(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at INTEGER NOT NULL,
            kind TEXT NOT NULL,          -- stt | tts
            provider TEXT NOT NULL,
            units REAL NOT NULL,         -- seconds of audio (stt) or characters (tts)
            ok INTEGER NOT NULL
          )''');
        await _createLearned(d);
        await _createCloudLog(d);
      },
    );
  }
}
