import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/memory_repository.dart';
import '../orchestrator/jarvis_orchestrator.dart';
import 'theme.dart';

/// Token & routing analytics. Token numbers come ONLY from Gemini's usageMetadata — never estimated.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  UsageTotals? _u;
  int _last = -1;

  Future<void> _load() async {
    final u = await context.read<MemoryRepository>().usageTotals();
    if (mounted) setState(() => _u = u);
  }

  @override
  Widget build(BuildContext context) {
    final o = context.watch<JarvisOrchestrator>();
    final stamp = o.messages.length + (o.task?.updatedAt.millisecondsSinceEpoch ?? 0);
    if (stamp != _last) {
      _last = stamp;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final u = _u;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('ANALYTICS', style: TextStyle(letterSpacing: 4, fontSize: 18, color: JColors.cyan)),
          const SizedBox(height: 6),
          const Text('Token figures are the provider-reported usageMetadata values. Nothing is estimated.',
              style: TextStyle(color: JColors.dim, fontSize: 12)),
          const SizedBox(height: 16),
          if (u == null)
            const Center(child: CircularProgressIndicator())
          else ...[
            _section('TASK ROUTING'),
            Row(children: [
              Expanded(child: _tile('Completed locally', '${u.localTasks}', JColors.green, 'no AI call')),
              const SizedBox(width: 10),
              Expanded(child: _tile('Needed AI', '${u.aiTasks}', JColors.violet, 'Gemini')),
            ]),
            const SizedBox(height: 10),
            _ratioBar(u.localTasks, u.aiTasks),
            const SizedBox(height: 20),
            _section('GEMINI'),
            Row(children: [
              Expanded(child: _tile('Requests', '${u.geminiRequests}', JColors.cyan, '${u.geminiFailures} failed')),
              const SizedBox(width: 10),
              Expanded(child: _tile('Total tokens', _n(u.totalTokens), JColors.cyan, 'reported')),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _tile('Input tokens', _n(u.inputTokens), JColors.blue, 'prompt')),
              const SizedBox(width: 10),
              Expanded(child: _tile('Output tokens', _n(u.outputTokens), JColors.blue, u.thoughtsTokens > 0 ? '+${_n(u.thoughtsTokens)} thinking' : 'candidates')),
            ]),
            if (u.unreportedRequests > 0) ...[
              const SizedBox(height: 8),
              Text('${u.unreportedRequests} successful request(s) returned no usage metadata and are not counted.',
                  style: const TextStyle(color: JColors.amber, fontSize: 12)),
            ],
            if (u.geminiRequests > 0) ...[
              const SizedBox(height: 10),
              Text('Average ${(u.totalTokens / (u.geminiRequests - u.geminiFailures).clamp(1, 1 << 30)).round()} tokens per successful request.',
                  style: const TextStyle(color: JColors.dim, fontSize: 12)),
            ],
            if (u.tokensByPurpose.isNotEmpty) ...[
              const SizedBox(height: 14),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Tokens by purpose', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    for (final e in u.tokensByPurpose.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(children: [Expanded(child: Text(e.key)), Text(_n(e.value), style: const TextStyle(color: JColors.cyan))]),
                      ),
                  ]),
                ),
              ),
            ],
            const SizedBox(height: 20),
            _section('SARVAM VOICE'),
            Row(children: [
              Expanded(child: _tile('Speech-to-text', '${u.sttRequests}', JColors.ice, '${u.sttSeconds.toStringAsFixed(1)} s audio')),
              const SizedBox(width: 10),
              Expanded(child: _tile('Text-to-speech', '${u.ttsRequests}', JColors.ice, '${_n(u.ttsChars)} chars')),
            ]),
            const SizedBox(height: 6),
            const Text('Wake-word detection runs on-device (Porcupine) and is never sent anywhere.',
                style: TextStyle(color: JColors.dim, fontSize: 12)),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () async {
                await context.read<MemoryRepository>().resetUsage();
                await _load();
              },
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset usage counters'),
            ),
          ],
        ],
      ),
    );
  }

  static String _n(int v) => v >= 1000000
      ? '${(v / 1000000).toStringAsFixed(2)}M'
      : v >= 10000
          ? '${(v / 1000).toStringAsFixed(1)}k'
          : '$v';

  Widget _section(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(s, style: const TextStyle(color: JColors.dim, letterSpacing: 2, fontSize: 11)),
      );

  Widget _tile(String label, String value, Color c, String sub) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: JColors.dim, fontSize: 12)),
            const SizedBox(height: 6),
            Text(value, style: TextStyle(color: c, fontSize: 26, fontWeight: FontWeight.w300)),
            Text(sub, style: const TextStyle(color: JColors.dim, fontSize: 11)),
          ]),
        ),
      );

  Widget _ratioBar(int local, int ai) {
    final total = local + ai;
    if (total == 0) return const Text('No completed tasks yet.', style: TextStyle(color: JColors.dim, fontSize: 12));
    final pct = (local / total * 100).round();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Row(children: [
          if (local > 0) Expanded(flex: local, child: Container(height: 10, color: JColors.green)),
          if (ai > 0) Expanded(flex: ai, child: Container(height: 10, color: JColors.violet)),
        ]),
      ),
      const SizedBox(height: 4),
      Text('$pct% of completed tasks needed no AI call', style: const TextStyle(color: JColors.dim, fontSize: 12)),
    ]);
  }
}
