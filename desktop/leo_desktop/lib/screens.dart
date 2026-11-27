import 'dart:convert';

import 'package:flutter/material.dart';

import 'agent_client.dart';
import 'theme.dart';

/// Runs an agent request and shows its error (if any) — nothing fails silently.
Future<void> runAct(BuildContext context, Future<String?> f) async {
  final e = await f;
  if (e != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Agent refused: $e')));
  }
}

class Shell extends StatefulWidget {
  final AgentClient client;
  const Shell({super.key, required this.client});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final c = widget.client;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: _page,
            onDestinationSelected: (i) => setState(() => _page = i),
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Text('LEO', style: TextStyle(letterSpacing: 6, fontSize: 20, color: LeoColors.accent)),
            ),
            destinations: [
              NavigationRailDestination(
                icon: Badge(
                    isLabelVisible: c.approvals.isNotEmpty,
                    label: Text('${c.approvals.length}'),
                    child: const Icon(Icons.dashboard_outlined)),
                label: const Text('Command'),
              ),
              const NavigationRailDestination(icon: Icon(Icons.receipt_long_outlined), label: Text('Audit')),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(children: [
              _Header(c: c),
              const Divider(height: 1),
              Expanded(child: _page == 0 ? CommandPage(c: c) : AuditPage(c: c)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final AgentClient c;
  const _Header({required this.c});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (c.link) {
      Link.connected => ('Agent connected · 127.0.0.1:${c.port} · v${c.agentVersion}', LeoColors.accent),
      Link.connecting => ('Connecting to agent…', LeoColors.amber),
      Link.noAgent => ('Agent not running', LeoColors.amber),
      Link.error => ('Agent error: ${c.error}', LeoColors.red),
    };
    final active = c.tasks.values.any((t) => const {'running', 'paused', 'waitingForApproval', 'planning'}.contains(t['state']));
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Row(children: [
        Icon(Icons.circle, size: 12, color: color),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: LeoColors.text)),
        const Spacer(),
        if (c.link == Link.noAgent)
          FilledButton.icon(
            onPressed: () async {
              final e = await c.startAgent();
              if (e != null && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e)));
              }
            },
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start agent'),
          ),
        if (c.link == Link.connected) ...[
          FilledButton.tonalIcon(
            onPressed: () => runAct(context, c.act('task.start', {'kind': 'selftest'})),
            icon: const Icon(Icons.science_outlined),
            label: const Text('Run self-test task'),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: LeoColors.red, foregroundColor: Colors.white),
            onPressed: active ? () => runAct(context, c.act('task.stopAll')) : null,
            icon: const Icon(Icons.stop),
            label: const Text('STOP ALL'),
          ),
        ],
      ]),
    );
  }
}

class CommandPage extends StatelessWidget {
  final AgentClient c;
  const CommandPage({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final tasks = c.tasks.values.toList()..sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
    return ListView(padding: const EdgeInsets.all(20), children: [
      if (c.approvals.isNotEmpty) ...[
        const _Label('WAITING FOR YOUR APPROVAL'),
        for (final a in c.approvals.values) ApprovalCard(c: c, a: a),
        const SizedBox(height: 16),
      ],
      const _Label('TASKS'),
      if (tasks.isEmpty)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(18),
            child: Text('No tasks yet. "Run self-test task" exercises count → approval → write → verify, '
                'and lets you try PAUSE, RESUME, STOP and CANCEL.', style: TextStyle(color: LeoColors.dim)),
          ),
        ),
      for (final t in tasks) TaskCard(c: c, t: t),
    ]);
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10, left: 2),
        child: Text(text, style: const TextStyle(letterSpacing: 2, fontSize: 12, color: LeoColors.accent)),
      );
}

class ApprovalCard extends StatelessWidget {
  final AgentClient c;
  final Map<String, dynamic> a;
  const ApprovalCard({super.key, required this.c, required this.a});

  @override
  Widget build(BuildContext context) {
    final params = Map<String, dynamic>.from(a['params'] as Map);
    final risk = a['risk'] as String;
    final riskColor = risk == 'external' ? LeoColors.red : LeoColors.amber;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: riskColor)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Icon(Icons.help_outline, color: riskColor),
              Text('${a['title']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              Chip(label: Text('${a['action']} · $risk', style: const TextStyle(fontSize: 11))),
              Text('task #${a['taskId']} · request ${a['id']}', style: const TextStyle(color: LeoColors.dim, fontSize: 11)),
            ]),
            const SizedBox(height: 6),
            Text('Target: ${a['target']}', style: const TextStyle(color: LeoColors.dim)),
            const SizedBox(height: 8),
            // Exactly what will be executed — approval is bound to these values.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: LeoColors.bg, borderRadius: BorderRadius.circular(8)),
              child: SelectableText(const JsonEncoder.withIndent('  ').convert(params),
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
            ),
            const SizedBox(height: 12),
            Row(children: [
              const Expanded(
                child: Text('Approval is bound to exactly these values and used once.',
                    style: TextStyle(color: LeoColors.dim, fontSize: 11)),
              ),
              OutlinedButton(onPressed: () => runAct(context, c.approve(a, false)), child: const Text('Deny')),
              const SizedBox(width: 10),
              FilledButton(onPressed: () => runAct(context, c.approve(a, true)), child: const Text('Approve')),
            ]),
          ]),
        ),
      ),
    );
  }
}

class TaskCard extends StatelessWidget {
  final AgentClient c;
  final Map<String, dynamic> t;
  const TaskCard({super.key, required this.c, required this.t});

  @override
  Widget build(BuildContext context) {
    final state = t['state'] as String;
    final steps = (t['steps'] as List).cast<Map>();
    final done = steps.where((s) => s['status'] == 'done').length;
    final id = t['id'] as int;
    final color = switch (state) {
      'completed' => LeoColors.accent,
      'failed' || 'interrupted' => LeoColors.red,
      'cancelled' => LeoColors.dim,
      'paused' || 'waitingForApproval' => LeoColors.amber,
      _ => LeoColors.text,
    };
    final live = const {'running', 'waitingForApproval', 'planning', 'understanding'}.contains(state);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text('#$id  ${t['title']}',
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 10),
              Text('${t['stateLabel']}', style: TextStyle(color: color, fontSize: 12, letterSpacing: 1.5)),
              const Spacer(),
              if (live) _btn(Icons.pause, 'Pause', () => runAct(context, c.act('task.pause', {'id': id}))),
              if (state == 'paused') _btn(Icons.play_arrow, 'Resume', () => runAct(context, c.act('task.resume', {'id': id}))),
              if (live || state == 'paused') ...[
                _btn(Icons.stop, 'Stop', () => runAct(context, c.act('task.stop', {'id': id})), color: LeoColors.red),
                _btn(Icons.close, 'Cancel', () => runAct(context, c.act('task.cancel', {'id': id}))),
              ],
            ]),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: steps.isEmpty ? null : done / steps.length,
              color: color,
              backgroundColor: LeoColors.panelHi,
              minHeight: 4,
            ),
            const SizedBox(height: 10),
            for (final s in steps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  _stepIcon('${s['status']}'),
                  const SizedBox(width: 8),
                  Text('${s['description']}'),
                  if (s['detail'] != null) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text('· ${s['detail']}',
                          overflow: TextOverflow.ellipsis, style: const TextStyle(color: LeoColors.dim, fontSize: 12)),
                    ),
                  ],
                ]),
              ),
            if (t['result'] != null) ...[
              const SizedBox(height: 8),
              Text('${t['result']}', style: TextStyle(color: color)),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _btn(IconData i, String tip, VoidCallback onTap, {Color? color}) =>
      IconButton(tooltip: tip, onPressed: onTap, icon: Icon(i, color: color));

  Widget _stepIcon(String s) => switch (s) {
        'done' => const Icon(Icons.check_circle, size: 16, color: LeoColors.accent),
        'running' => const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        'failed' => const Icon(Icons.error, size: 16, color: LeoColors.red),
        'cancelled' => const Icon(Icons.block, size: 16, color: LeoColors.dim),
        _ => const Icon(Icons.radio_button_unchecked, size: 16, color: LeoColors.dim),
      };
}

class AuditPage extends StatefulWidget {
  final AgentClient c;
  const AuditPage({super.key, required this.c});

  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  Map<String, dynamic>? _verify;

  Future<void> _check() async {
    final r = await widget.c.call('audit.verify');
    setState(() => _verify = r['result'] as Map<String, dynamic>?);
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.c.audit.reversed.toList();
    final v = _verify;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Row(children: [
          const Text('Hash-chained audit log — actions only, never content or keys.', style: TextStyle(color: LeoColors.dim)),
          const Spacer(),
          if (v != null)
            Text(v['ok'] == true ? 'Chain intact · ${v['checked']} entries' : 'Chain BROKEN at entry ${v['brokenAt']}',
                style: TextStyle(color: v['ok'] == true ? LeoColors.accent : LeoColors.red)),
          const SizedBox(width: 12),
          OutlinedButton.icon(onPressed: _check, icon: const Icon(Icons.verified_outlined), label: const Text('Verify chain')),
        ]),
      ),
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          itemCount: entries.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final e = entries[i];
            final extra = Map<String, dynamic>.from(e)..removeWhere((k, _) => const {'seq', 'ts', 'actor', 'action', 'prev', 'hash'}.contains(k));
            return ListTile(
              dense: true,
              leading: Text('${e['seq']}', style: const TextStyle(color: LeoColors.dim, fontFamily: 'Consolas')),
              title: Text('${e['action']}', style: const TextStyle(fontFamily: 'Consolas')),
              subtitle: Text('${e['ts']} · ${e['actor']}${extra.isEmpty ? '' : ' · ${extra.entries.map((x) => '${x.key}=${x.value}').join('  ')}'}',
                  style: const TextStyle(color: LeoColors.dim, fontSize: 11)),
              trailing: Text('${(e['hash'] as String).substring(0, 10)}…',
                  style: const TextStyle(color: LeoColors.dim, fontFamily: 'Consolas', fontSize: 11)),
            );
          },
        ),
      ),
    ]);
  }
}
