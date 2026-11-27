import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/task/task_models.dart';
import '../data/memory_repository.dart';
import '../orchestrator/jarvis_orchestrator.dart';
import 'theme.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final _q = TextEditingController();
  List<SessionSummary> _sessions = [];
  List<StoredMessage>? _results;
  List<TaskSnapshot> _tasks = [];
  int _lastCount = -1;

  @override
  void dispose() {
    _tabs.dispose();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load(MemoryRepository m) async {
    final s = await m.sessions();
    final t = await m.tasks(limit: 100);
    if (mounted) setState(() {
      _sessions = s;
      _tasks = t;
    });
  }

  Future<void> _search(MemoryRepository m, String q) async {
    if (q.trim().isEmpty) {
      setState(() => _results = null);
      return;
    }
    final r = await m.search(q, limit: 50);
    if (mounted) setState(() => _results = r);
  }

  @override
  Widget build(BuildContext context) {
    final memory = context.read<MemoryRepository>();
    final o = context.watch<JarvisOrchestrator>();
    if (_lastCount != o.messages.length) {
      _lastCount = o.messages.length;
      _load(memory);
    }
    return Column(children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Row(children: [Text('HISTORY', style: TextStyle(letterSpacing: 4, fontSize: 18, color: JColors.cyan))]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: _q,
          onChanged: (v) => _search(memory, v),
          decoration: const InputDecoration(hintText: 'Search all conversations…', prefixIcon: Icon(Icons.search)),
        ),
      ),
      TabBar(controller: _tabs, tabs: const [Tab(text: 'Conversations'), Tab(text: 'Tasks')], indicatorColor: JColors.cyan, labelColor: JColors.cyan),
      Expanded(
        child: TabBarView(controller: _tabs, children: [
          _results != null ? _searchResults() : _sessionList(memory, o),
          _taskList(),
        ]),
      ),
    ]);
  }

  Widget _searchResults() {
    if (_results!.isEmpty) return const Center(child: Text('No matches', style: TextStyle(color: JColors.dim)));
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _results!.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final m = _results![i];
        return Card(
          child: ListTile(
            leading: Icon(m.isUser ? Icons.person_outline : Icons.blur_circular, color: m.isUser ? JColors.blue : JColors.cyan),
            title: Text(m.text, maxLines: 3, overflow: TextOverflow.ellipsis),
            subtitle: Text(_fmt(m.createdAt), style: const TextStyle(color: JColors.dim, fontSize: 11)),
          ),
        );
      },
    );
  }

  Widget _sessionList(MemoryRepository memory, JarvisOrchestrator o) {
    if (_sessions.isEmpty) return const Center(child: Text('No conversations yet', style: TextStyle(color: JColors.dim)));
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _sessions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final s = _sessions[i];
        final isCurrent = s.id == o.sessionId;
        return Card(
          child: ListTile(
            title: Text(s.preview ?? 'Conversation', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${_fmt(s.startedAt)} · ${s.messageCount} messages${isCurrent ? ' · current' : ''}',
                style: const TextStyle(color: JColors.dim, fontSize: 11)),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, color: JColors.red),
              onPressed: () async {
                final ok = await _confirm(context, 'Delete this conversation?', 'This cannot be undone.');
                if (!ok) return;
                await memory.deleteSession(s.id);
                if (isCurrent) await o.reloadSession();
                await _load(memory);
              },
            ),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _SessionView(session: s))),
          ),
        );
      },
    );
  }

  Widget _taskList() {
    if (_tasks.isEmpty) return const Center(child: Text('No tasks yet', style: TextStyle(color: JColors.dim)));
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _tasks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final t = _tasks[i];
        final color = switch (t.state) {
          AgentState.completed => JColors.green,
          AgentState.failed => JColors.red,
          AgentState.interrupted || AgentState.paused => JColors.amber,
          _ => JColors.dim,
        };
        return Card(
          child: ExpansionTile(
            shape: const Border(),
            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${t.state.label} · ${t.route == TaskRoute.local ? 'local' : 'AI'} · ${_fmt(t.updatedAt)}',
                style: TextStyle(color: color, fontSize: 11)),
            children: [
              for (final s in t.steps)
                ListTile(
                  dense: true,
                  title: Text(s.description),
                  subtitle: s.detail == null ? null : Text(s.detail!, style: const TextStyle(color: JColors.dim)),
                  trailing: Text(s.status.name, style: const TextStyle(color: JColors.dim, fontSize: 11)),
                ),
              if (t.result != null) Padding(padding: const EdgeInsets.all(12), child: Text(t.result!, style: const TextStyle(color: JColors.dim))),
            ],
          ),
        );
      },
    );
  }
}

class _SessionView extends StatelessWidget {
  final SessionSummary session;
  const _SessionView({required this.session});

  @override
  Widget build(BuildContext context) {
    final memory = context.read<MemoryRepository>();
    return Scaffold(
      appBar: AppBar(title: Text(_fmt(session.startedAt))),
      body: FutureBuilder<List<StoredMessage>>(
        future: memory.messagesOf(session.id),
        builder: (_, snap) {
          final list = snap.data ?? const [];
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final m = list[i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 64,
                    child: Text(m.isUser ? 'You' : 'JARVIS', style: TextStyle(color: m.isUser ? JColors.blue : JColors.cyan, fontWeight: FontWeight.w600)),
                  ),
                  Expanded(child: SelectableText(m.text)),
                ]),
              );
            },
          );
        },
      ),
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JColors.panel,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: JColors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    ) ??
    false;

String _fmt(DateTime d) =>
    '${d.day}/${d.month}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
