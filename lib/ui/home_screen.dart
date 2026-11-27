import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/approval/approval_gate.dart';
import '../core/intent/local_intent.dart';
import '../core/task/task_models.dart';
import '../data/memory_repository.dart';
import '../orchestrator/jarvis_orchestrator.dart';
import '../voice/mic_engine.dart';
import 'permissions_screen.dart';
import 'theme.dart';
import 'widgets/orb.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send(JarvisOrchestrator o) {
    final t = _input.text;
    _input.clear();
    FocusScope.of(context).unfocus();
    o.submitText(t);
  }

  @override
  Widget build(BuildContext context) {
    final o = context.watch<JarvisOrchestrator>();
    final mic = context.watch<MicEngine>();
    final d = o.display;
    final task = o.task;
    final active = o.speaking ||
        o.voice != VoicePhase.idle ||
        (task != null && task.state.isActive);

    return Column(
      children: [
        _Header(o: o, mic: mic),
        if (o.banner != null) _Banner(text: o.banner!, onClose: o.dismissBanner),
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              Center(
                child: JarvisOrb(
                  state: d,
                  micLevel: mic.level,
                  size: 240,
                  onTap: o.tapMic,
                ),
              ),
              const SizedBox(height: 2),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: d.color.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(40),
                    border: Border.all(color: d.color.withValues(alpha: 0.35)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 6, height: 6, decoration: BoxDecoration(color: d.color, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text(o.voice == VoicePhase.transcribing ? 'UNDERSTANDING' : d.label, style: monoLabel(color: d.color, size: 11)),
                  ]),
                ),
              ),
              const SizedBox(height: 14),
              if (o.pendingApproval != null) ...[
                ApprovalCard(req: o.pendingApproval!, o: o),
                const SizedBox(height: 12),
              ],
              if (o.choice != null) ...[
                ChoiceCard(prompt: o.choice!, onPick: o.choose),
                const SizedBox(height: 12),
              ],
              if (o.awaitingInput) ...[
                const _InfoCard(icon: Icons.edit_note, color: JColors.amber, text: 'Waiting for the message text — say it or type it below.'),
                const SizedBox(height: 12),
              ],
              if (task != null && (task.state.isActive || task.state == AgentState.interrupted || _recent(task))) ...[
                TaskPanel(task: task, o: o),
                const SizedBox(height: 12),
              ],
              if (o.draft != null) ...[
                _DraftCard(draft: o.draft!, o: o),
                const SizedBox(height: 12),
              ],
              _Conversation(o: o),
            ],
          ),
        ),
        _InputBar(
          controller: _input,
          onSend: () => _send(o),
          onMic: o.tapMic,
          listening: o.voice == VoicePhase.listening,
          showStop: active,
          onStop: o.stop,
          heard: o.lastHeard,
        ),
      ],
    );
  }

  static bool _recent(TaskSnapshot t) => DateTime.now().difference(t.updatedAt) < const Duration(minutes: 2);
}

// ---------------------------------------------------------------------------- header
class _Header extends StatelessWidget {
  final JarvisOrchestrator o;
  final MicEngine mic;
  const _Header({required this.o, required this.mic});

  @override
  Widget build(BuildContext context) {
    final (wakeText, wakeColor) = switch (mic.wakeStatus) {
      WakeWordStatus.armed => ('"Leo" armed · on-device', JColors.green),
      WakeWordStatus.starting => ('Starting wake word…', JColors.amber),
      WakeWordStatus.error => ('Wake word error', JColors.red),
      WakeWordStatus.off => (o.listeningEnabled ? 'Mic on' : 'Not listening', JColors.dim),
    };
    // Landing-page style nav pill: orb logo + LEO wordmark, live mic/wake status, listening switch.
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: JColors.ink.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(40),
        border: Border.all(color: JColors.volt.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          const OrbMini(size: 26),
          const SizedBox(width: 10),
          const Text('LEO',
              style: TextStyle(fontFamily: JFonts.display, fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -1.3, color: JColors.bone)),
          const SizedBox(width: 12),
          Container(width: 1, height: 22, color: JColors.volt.withValues(alpha: 0.15)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(mic.running ? Icons.mic : Icons.mic_off, size: 12, color: mic.running ? JColors.volt : JColors.mute),
                  const SizedBox(width: 4),
                  Text(mic.running ? 'MIC ON' : 'MIC OFF', style: monoLabel(color: mic.running ? JColors.volt : JColors.mute, size: 9)),
                ]),
                const SizedBox(height: 3),
                Row(children: [
                  Container(width: 6, height: 6, decoration: BoxDecoration(color: wakeColor, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(wakeText.toUpperCase(),
                        overflow: TextOverflow.ellipsis, style: monoLabel(color: wakeColor, size: 9).copyWith(letterSpacing: 1.2)),
                  ),
                ]),
              ],
            ),
          ),
          Switch(
            value: o.listeningEnabled,
            onChanged: (v) => v ? o.enableListening() : o.disableListening(),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String text;
  final VoidCallback onClose;
  const _Banner({required this.text, required this.onClose});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 6, 16, 4),
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
        decoration: BoxDecoration(
          color: JColors.amber.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: JColors.amber.withValues(alpha: 0.5)),
        ),
        child: Row(children: [
          const Icon(Icons.info_outline, color: JColors.amber, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PermissionsScreen())),
            child: const Text('Permissions'),
          ),
          IconButton(onPressed: onClose, icon: const Icon(Icons.close, size: 18)),
        ]),
      );
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _InfoCard({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ]),
        ),
      );
}

// ---------------------------------------------------------------------------- approval
class ApprovalCard extends StatelessWidget {
  final ApprovalRequest req;
  final JarvisOrchestrator o;
  const ApprovalCard({required this.req, required this.o});

  Future<void> _edit(BuildContext context) async {
    final c = TextEditingController(text: req.content);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JColors.panel,
        title: const Text('Edit message'),
        content: TextField(controller: c, maxLines: 5, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Update')),
        ],
      ),
    );
    if (v != null && v.trim().isNotEmpty && v.trim() != req.content) o.editPending(v);
  }

  @override
  Widget build(BuildContext context) {
    final isMessage = req.actionType == 'whatsapp.send';
    return Container(
      decoration: BoxDecoration(
        color: JColors.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: JColors.amber, width: 1.4),
        boxShadow: [BoxShadow(color: JColors.amber.withValues(alpha: 0.15), blurRadius: 18)],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.verified_user_outlined, color: JColors.amber),
            const SizedBox(width: 8),
            const Text('APPROVAL REQUIRED', style: TextStyle(color: JColors.amber, letterSpacing: 2, fontWeight: FontWeight.w700, fontSize: 12)),
            const Spacer(),
            Text(req.appLabel ?? '', style: const TextStyle(color: JColors.dim, fontSize: 12)),
          ]),
          const SizedBox(height: 12),
          Text(req.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          if (req.recipientLabel != null) ...[
            const SizedBox(height: 10),
            _kv('To', req.recipientLabel!),
          ],
          if (req.content != null) ...[
            const SizedBox(height: 8),
            _kv(isMessage ? 'Message' : 'Affects', req.content!),
          ],
          const SizedBox(height: 6),
          const Text('Approval applies to exactly this recipient and text. Any change needs a new approval.',
              style: TextStyle(color: JColors.dim, fontSize: 11)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: JColors.amber, foregroundColor: JColors.bg),
                onPressed: o.approve,
                icon: const Icon(Icons.check),
                label: Text(isMessage ? 'Send' : 'Approve'),
              ),
            ),
            const SizedBox(width: 8),
            if (isMessage)
              OutlinedButton.icon(onPressed: () => _edit(context), icon: const Icon(Icons.edit, size: 18), label: const Text('Edit')),
            const SizedBox(width: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: JColors.red),
              onPressed: o.reject,
              child: const Text('Reject'),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 70, child: Text(k, style: const TextStyle(color: JColors.dim))),
        Expanded(child: SelectableText(v, style: const TextStyle(fontSize: 15))),
      ]);
}

class ChoiceCard extends StatelessWidget {
  final ChoicePrompt prompt;
  final void Function(int) onPick;
  const ChoiceCard({required this.prompt, required this.onPick});

  @override
  Widget build(BuildContext context) => Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: JColors.amber)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.help_outline, color: JColors.amber),
              const SizedBox(width: 8),
              Expanded(child: Text(prompt.question, style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
            const SizedBox(height: 8),
            for (var i = 0; i < prompt.options.length; i++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: CircleAvatar(radius: 13, backgroundColor: JColors.panelHi, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                title: Text(prompt.options[i]),
                subtitle: i < prompt.details.length ? Text(prompt.details[i], style: const TextStyle(color: JColors.dim)) : null,
                onTap: () => onPick(i),
              ),
          ]),
        ),
      );
}

// ---------------------------------------------------------------------------- task panel
class TaskPanel extends StatelessWidget {
  final TaskSnapshot task;
  final JarvisOrchestrator o;
  const TaskPanel({required this.task, required this.o});

  @override
  Widget build(BuildContext context) {
    final stateColor = switch (task.state) {
      AgentState.completed => JColors.green,
      AgentState.failed => JColors.red,
      AgentState.cancelled || AgentState.interrupted => JColors.dim,
      AgentState.waitingForApproval || AgentState.paused => JColors.amber,
      _ => JColors.cyan,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.bolt, size: 18, color: JColors.cyan),
            const SizedBox(width: 6),
            Expanded(child: Text(task.title, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
            StatusChip(text: task.route == TaskRoute.local ? 'LOCAL' : 'AI', color: task.route == TaskRoute.local ? JColors.green : JColors.violet),
            const SizedBox(width: 6),
            StatusChip(text: task.state.label, color: stateColor),
          ]),
          const SizedBox(height: 10),
          for (final s in task.steps) StepRow(step: s),
          if (task.result != null && task.state.isTerminal) ...[
            const SizedBox(height: 6),
            Text(task.result!, style: const TextStyle(color: JColors.dim, fontSize: 12)),
          ],
          if (task.state.isActive || task.state == AgentState.interrupted) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              if (task.state == AgentState.running || task.state == AgentState.waitingForApproval)
                OutlinedButton.icon(onPressed: o.pause, icon: const Icon(Icons.pause, size: 16), label: const Text('Pause')),
              if (task.state == AgentState.paused)
                OutlinedButton.icon(onPressed: o.resume, icon: const Icon(Icons.play_arrow, size: 16), label: const Text('Resume')),
              if (task.state == AgentState.interrupted)
                OutlinedButton.icon(onPressed: o.continueWhereStopped, icon: const Icon(Icons.replay, size: 16), label: const Text('Continue')),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: JColors.red),
                onPressed: o.cancelTask,
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Cancel task'),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

class StepRow extends StatelessWidget {
  final TaskStep step;
  const StepRow({required this.step});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (step.status) {
      StepStatus.pending => (Icons.radio_button_unchecked, JColors.dim),
      StepStatus.running => (Icons.autorenew, JColors.cyan),
      StepStatus.done => (Icons.check_circle, JColors.green),
      StepStatus.failed => (Icons.error, JColors.red),
      StepStatus.skipped => (Icons.remove_circle_outline, JColors.amber),
      StepStatus.cancelled => (Icons.cancel_outlined, JColors.dim),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        step.status == StepStatus.running
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: JColors.cyan))
            : Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(step.description + (step.irreversible ? '  ⚠' : ''),
                style: TextStyle(color: step.status == StepStatus.pending ? JColors.dim : JColors.text, fontSize: 13)),
            if (step.detail != null) Text(step.detail!, style: const TextStyle(color: JColors.dim, fontSize: 11)),
          ]),
        ),
      ]),
    );
  }
}

class StatusChip extends StatelessWidget {
  final String text;
  final Color color;
  const StatusChip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1)),
      );
}

// ---------------------------------------------------------------------------- draft
class _DraftCard extends StatefulWidget {
  final Draft draft;
  final JarvisOrchestrator o;
  const _DraftCard({required this.draft, required this.o});

  @override
  State<_DraftCard> createState() => _DraftCardState();
}

class _DraftCardState extends State<_DraftCard> {
  late TextEditingController _c = TextEditingController(text: widget.draft.content);

  @override
  void didUpdateWidget(covariant _DraftCard old) {
    super.didUpdateWidget(old);
    if (old.draft != widget.draft) _c = TextEditingController(text: widget.draft.content);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final label = switch (d.kind) {
      WritingKind.email => 'EMAIL DRAFT',
      WritingKind.message => 'MESSAGE DRAFT',
      WritingKind.rewrite => 'REWRITE',
      _ => 'DRAFT',
    };
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: JColors.violet)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_awesome, color: JColors.violet, size: 18),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: JColors.violet, letterSpacing: 2, fontWeight: FontWeight.w700, fontSize: 12)),
            const Spacer(),
            const Text('for your review', style: TextStyle(color: JColors.dim, fontSize: 11)),
            IconButton(onPressed: widget.o.dismissDraft, icon: const Icon(Icons.close, size: 18)),
          ]),
          if (d.subject != null) ...[
            Text('Subject: ${d.subject}', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
          ],
          TextField(
            controller: _c,
            maxLines: null,
            style: const TextStyle(fontSize: 14, height: 1.4),
            decoration: const InputDecoration(
              filled: true,
              fillColor: JColors.navy,
              border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)), borderSide: BorderSide(color: JColors.line)),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _c.text));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy'),
            ),
            OutlinedButton.icon(
              onPressed: () => SharePlus.instance.share(ShareParams(text: _c.text, subject: d.subject)),
              icon: const Icon(Icons.share, size: 16),
              label: const Text('Share'),
            ),
            if (d.kind == WritingKind.email)
              FilledButton.icon(
                onPressed: () {
                  widget.o.draft = Draft(d.kind, d.subject, _c.text);
                  widget.o.emailDraft();
                },
                icon: const Icon(Icons.mail_outline, size: 16),
                label: const Text('Open in email app'),
              ),
          ]),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------- conversation
class _Conversation extends StatelessWidget {
  final JarvisOrchestrator o;
  const _Conversation({required this.o});

  @override
  Widget build(BuildContext context) {
    final current = o.messages.length > 30 ? o.messages.sublist(o.messages.length - 30) : o.messages;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (o.previousSessionTail.isNotEmpty && o.messages.length < 4) ...[
        const _SectionLabel('EARLIER CONVERSATION'),
        for (final m in o.previousSessionTail) _Bubble(m: m, faded: true),
        const SizedBox(height: 8),
      ],
      if (current.isNotEmpty) const _SectionLabel('THIS SESSION'),
      for (final m in current.reversed.toList().reversed) _Bubble(m: m),
      if (current.isEmpty && o.previousSessionTail.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('Say "Leo", tap the orb, or type below.\nTry: "Open WhatsApp" · "What is a black hole?" · "Write an email to my professor asking for leave"',
              textAlign: TextAlign.center, style: TextStyle(color: JColors.dim, height: 1.6)),
        ),
    ]);
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(color: JColors.volt.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(20)),
            child: Text(text, style: monoLabel(color: JColors.mute, size: 9)),
          ),
        ),
      );
}

class _Bubble extends StatelessWidget {
  final StoredMessage m;
  final bool faded;
  const _Bubble({required this.m, this.faded = false});

  @override
  Widget build(BuildContext context) {
    final user = m.isUser;
    // Landing style: your words = solid volt bubble; LEO = coal bubble with an orb avatar.
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: user ? JColors.volt : JColors.coal2,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(20),
          topRight: const Radius.circular(20),
          bottomLeft: Radius.circular(user ? 20 : 6),
          bottomRight: Radius.circular(user ? 6 : 20),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SelectableText(m.text,
            style: TextStyle(
                fontSize: 14, height: 1.38, color: user ? JColors.ink : JColors.bone, fontWeight: user ? FontWeight.w500 : FontWeight.w400)),
        const SizedBox(height: 4),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text(_time(m.createdAt),
              style: TextStyle(fontFamily: JFonts.mono, fontSize: 9, color: user ? JColors.ink.withValues(alpha: 0.6) : JColors.mute)),
          if (m.source == 'voice')
            Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.mic, size: 10, color: user ? JColors.ink.withValues(alpha: 0.6) : JColors.mute)),
          if (!user && m.route == 'ai')
            Padding(padding: const EdgeInsets.only(left: 6), child: Text('OPENAI', style: monoLabel(color: JColors.violet, size: 8))),
          if (!user && m.route == 'local')
            Padding(padding: const EdgeInsets.only(left: 6), child: Text('ON-DEVICE', style: monoLabel(color: JColors.volt, size: 8))),
        ]),
      ]),
    );
    return Opacity(
      opacity: faded ? 0.5 : 1,
      child: Row(
        mainAxisAlignment: user ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!user) const Padding(padding: EdgeInsets.only(right: 8, bottom: 8), child: OrbMini(size: 18)),
          Flexible(child: bubble),
        ],
      ),
    );
  }

  static String _time(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} · ${d.day}/${d.month}';
}

// ---------------------------------------------------------------------------- voice bar
/// The landing page's bottom "voice bar": orb (tap to talk), what LEO heard / text input, live waveform.
class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onMic;
  final VoidCallback onStop;
  final bool listening;
  final bool showStop;
  final String? heard;
  const _InputBar({
    required this.controller,
    required this.onSend,
    required this.onMic,
    required this.onStop,
    required this.listening,
    required this.showStop,
    this.heard,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (showStop)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: JColors.red,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 44),
                ),
                onPressed: onStop,
                icon: const Icon(Icons.stop_rounded),
                label: Text('STOP', style: monoLabel(color: Colors.white, size: 12)),
              ),
            ),
          Container(
            height: 64,
            padding: const EdgeInsets.only(left: 8, right: 6),
            decoration: BoxDecoration(
              color: JColors.coal2.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(40),
              border: Border.all(color: listening ? JColors.volt : JColors.volt.withValues(alpha: 0.10)),
              boxShadow: listening ? [BoxShadow(color: JColors.volt.withValues(alpha: 0.25), blurRadius: 24)] : null,
            ),
            child: Row(children: [
              Tooltip(
                message: listening ? 'Stop listening' : 'Talk to LEO',
                child: InkWell(onTap: onMic, customBorder: const CircleBorder(), child: const OrbMini(size: 44)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(listening ? 'LEO IS LISTENING' : (heard != null ? 'LEO HEARD' : 'TYPE OR TAP THE ORB'), style: monoLabel(size: 9)),
                    TextField(
                      controller: controller,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSend(),
                      style: const TextStyle(fontFamily: JFonts.mono, fontSize: 13, color: JColors.bone),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: false,
                        contentPadding: const EdgeInsets.only(top: 4),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: heard != null ? '“$heard”' : 'Ask LEO anything…',
                        hintStyle: TextStyle(fontFamily: JFonts.mono, fontSize: 13, color: heard != null ? JColors.bone : JColors.mute),
                        hintMaxLines: 1,
                      ),
                    ),
                  ],
                ),
              ),
              Waveform(bars: 6, seed: 9, active: listening, height: 18),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Send',
                onPressed: onSend,
                icon: const Icon(Icons.arrow_upward_rounded),
                style: IconButton.styleFrom(backgroundColor: JColors.volt, foregroundColor: JColors.ink),
              ),
            ]),
          ),
        ]),
      );
}
