import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/memory_repository.dart';
import '../orchestrator/jarvis_orchestrator.dart';
import 'theme.dart';

/// Memory controls: explicit facts the user asked LEO to remember, plus deletion of history.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  List<Fact> _facts = [];
  int _sessions = 0;
  int _lastCount = -1;
  final _add = TextEditingController();

  Future<void> _load() async {
    final m = context.read<MemoryRepository>();
    final f = await m.facts();
    final s = await m.sessions();
    if (mounted) setState(() {
      _facts = f;
      _sessions = s.length;
    });
  }

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final o = context.watch<JarvisOrchestrator>();
    final memory = context.read<MemoryRepository>();
    if (_lastCount != o.messages.length) {
      _lastCount = o.messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('MEMORY', style: TextStyle(letterSpacing: 4, fontSize: 18, color: JColors.cyan)),
        const SizedBox(height: 6),
        const Text(
          'Everything is stored only on this phone. When Gemini is needed, LEO sends just a few relevant snippets — never the whole history.',
          style: TextStyle(color: JColors.dim, fontSize: 12),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Things you asked me to remember', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text('Say "Remember that …" or add one here.', style: TextStyle(color: JColors.dim, fontSize: 12)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: _add, decoration: const InputDecoration(hintText: 'e.g. I prefer short emails'))),
                IconButton(
                  icon: const Icon(Icons.add_circle, color: JColors.cyan),
                  onPressed: () async {
                    if (_add.text.trim().isEmpty) return;
                    await memory.addFact(_add.text.trim());
                    _add.clear();
                    await _load();
                  },
                ),
              ]),
              const SizedBox(height: 8),
              if (_facts.isEmpty) const Text('Nothing yet.', style: TextStyle(color: JColors.dim)),
              for (final f in _facts)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bookmark_outline, color: JColors.cyan),
                  title: Text(f.text),
                  subtitle: Text('${f.createdAt.day}/${f.createdAt.month}/${f.createdAt.year}', style: const TextStyle(color: JColors.dim, fontSize: 11)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: JColors.red),
                    onPressed: () async {
                      await memory.deleteFact(f.id);
                      await _load();
                    },
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Conversation history', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('$_sessions stored conversations. Browse and search them in History.', style: const TextStyle(color: JColors.dim, fontSize: 12)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: JColors.red),
                icon: const Icon(Icons.delete_forever),
                label: const Text('Delete all history & memory'),
                onPressed: () => o.submitText('delete all conversation history'),
              ),
              const SizedBox(height: 4),
              const Text('Goes through the approval system — you will be asked to confirm.', style: TextStyle(color: JColors.dim, fontSize: 11)),
            ]),
          ),
        ),
      ],
    );
  }
}
