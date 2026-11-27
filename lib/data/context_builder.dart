import 'memory_repository.dart';

/// Builds a SMALL, relevant context block for an AI request instead of sending whole histories.
///
/// Layers:
///  1. Recent turns of the current session (only the last few, truncated).
///  2. Relevant snippets from older conversations (local full-text search on the query's keywords).
///  3. Unfinished tasks (titles only).
///  4. Explicit, user-approved facts.
class ContextBuilder {
  final MemoryRepository memory;
  ContextBuilder(this.memory);

  static const recentTurns = 6;
  static const maxRecentChars = 280;
  static const maxRelevant = 4;
  static const maxRelevantChars = 220;

  Future<BuiltContext> build({required int sessionId, required String query, bool includeRecent = true}) async {
    final parts = <String>[];
    final sources = <String>[];

    final facts = await memory.facts();
    if (facts.isNotEmpty) {
      parts.add('Facts the user asked you to remember:\n${facts.take(12).map((f) => '- ${f.text}').join('\n')}');
      sources.add('${facts.length.clamp(0, 12)} facts');
    }

    if (includeRecent) {
      final recent = await memory.messagesOf(sessionId, limit: recentTurns + 1);
      // The last stored message is the current query itself — drop it.
      final turns = recent.isNotEmpty && recent.last.isUser && recent.last.text == query
          ? recent.sublist(0, recent.length - 1)
          : recent;
      if (turns.isNotEmpty) {
        parts.add('Recent conversation:\n${turns.map((m) => '${m.isUser ? 'User' : 'LEO'}: ${_trim(m.text, maxRecentChars)}').join('\n')}');
        sources.add('${turns.length} recent turns');
      }
    }

    final relevant = await memory.search(query, limit: 12, excludeSessionId: sessionId);
    final picked = relevant.take(maxRelevant).toList();
    if (picked.isNotEmpty) {
      parts.add('Possibly relevant earlier conversations:\n${picked.map((m) => '- [${_date(m.createdAt)}] ${m.isUser ? 'User' : 'LEO'}: ${_trim(m.text, maxRelevantChars)}').join('\n')}');
      sources.add('${picked.length} retrieved snippets');
    }

    final unfinished = await memory.unfinishedTasks();
    if (unfinished.isNotEmpty) {
      parts.add('Unfinished tasks: ${unfinished.take(3).map((t) => '"${t.title}" (${t.state.name})').join(', ')}');
      sources.add('${unfinished.length.clamp(0, 3)} unfinished tasks');
    }

    return BuiltContext(parts.join('\n\n'), sources);
  }

  static String _trim(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
  static String _date(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class BuiltContext {
  final String text;
  final List<String> sources;
  const BuiltContext(this.text, this.sources);
  bool get isEmpty => text.isEmpty;
}
