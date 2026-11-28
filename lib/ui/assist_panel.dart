import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/memory_repository.dart';
import '../device/device_bridge.dart';
import '../orchestrator/jarvis_orchestrator.dart';
import '../voice/mic_engine.dart';
import 'home_screen.dart';
import 'theme.dart';
import 'widgets/orb.dart';
import 'widgets/run_timer.dart';

/// Gemini-style assistant sheet shown over any app when LEO is invoked as the phone's digital
/// assistant (long-press side key / corner swipe). Shows the live conversation so follow-ups
/// ("pause the music") make sense on screen. Tap the dimmed area above to dismiss.
class AssistPanel extends StatefulWidget {
  const AssistPanel({super.key});

  @override
  State<AssistPanel> createState() => _AssistPanelState();
}

class _AssistPanelState extends State<AssistPanel> with SingleTickerProviderStateMixin {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final AnimationController _glow = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
  int _lastCount = 0;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _glow.dispose();
    super.dispose();
  }

  void _autoScroll(int count) {
    if (count == _lastCount) return;
    _lastCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final o = context.watch<JarvisOrchestrator>();
    final mic = context.watch<MicEngine>();
    final device = context.read<DeviceBridge>();
    final d = o.display;
    final task = o.task;
    final size = MediaQuery.of(context).size;
    // Recent conversation (last 8 turns) so follow-ups have visible context.
    final thread = o.messages.length > 8 ? o.messages.sublist(o.messages.length - 8) : o.messages;
    _autoScroll(o.messages.length);

    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      body: Column(
        children: [
          Expanded(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: device.closeAssist)),
          AnimatedBuilder(
            animation: _glow,
            builder: (_, child) => Container(
              height: size.height * 0.56,
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                // Animated gradient edge (Gemini-like), tinted by LEO's real state.
                gradient: SweepGradient(
                  transform: GradientRotation(_glow.value * 6.283),
                  colors: [d.color, JColors.blue, JColors.violet, JColors.cyan, d.color],
                ),
                boxShadow: [BoxShadow(color: d.color.withValues(alpha: 0.35), blurRadius: 32, spreadRadius: 1)],
              ),
              padding: const EdgeInsets.only(top: 2),
              child: child,
            ),
            child: Container(
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF0B1834), JColors.bg]),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    Container(width: 40, height: 4, decoration: BoxDecoration(color: JColors.line, borderRadius: BorderRadius.circular(2))),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                      child: Row(children: [
                        JarvisOrb(state: d, micLevel: mic.level, size: 56, onTap: o.tapMic),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('LEO', style: TextStyle(color: JColors.cyan, letterSpacing: 5, fontWeight: FontWeight.w300, fontSize: 18)),
                            Text(d.label, style: TextStyle(color: d.color, letterSpacing: 2, fontWeight: FontWeight.w700, fontSize: 11)),
                          ]),
                        ),
                        RunTimerChip(clock: o.runClock),
                        IconButton(tooltip: 'Open LEO', onPressed: device.openFullApp, icon: const Icon(Icons.open_in_full, color: JColors.dim)),
                        IconButton(tooltip: 'Close', onPressed: device.closeAssist, icon: const Icon(Icons.close, color: JColors.dim)),
                      ]),
                    ),
                    Expanded(
                      child: ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        children: [
                          for (final m in thread) _Line(m: m),
                          if (o.voice == VoicePhase.listening)
                            const _Live(text: 'Listening…')
                          else if (o.voice == VoicePhase.transcribing)
                            const _Live(text: 'Understanding…'),
                          if (o.pendingApproval != null) ...[const SizedBox(height: 8), ApprovalCard(req: o.pendingApproval!, o: o)],
                          if (o.choice != null) ...[const SizedBox(height: 8), ChoiceCard(prompt: o.choice!, onPick: o.choose)],
                          if (task != null && task.state.isActive && o.pendingApproval == null && o.choice == null) ...[
                            const SizedBox(height: 8),
                            TaskPanel(task: task, o: o),
                          ],
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                      child: Row(children: [
                        if (o.speaking || o.voice != VoicePhase.idle || (task?.state.isActive ?? false)) ...[
                          IconButton.filled(
                            style: IconButton.styleFrom(backgroundColor: JColors.red),
                            onPressed: o.stop,
                            icon: const Icon(Icons.stop, color: Colors.white),
                            tooltip: 'Stop',
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: TextField(
                            controller: _input,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (v) {
                              _input.clear();
                              o.submitText(v);
                            },
                            decoration: const InputDecoration(hintText: 'Ask LEO…', isDense: true),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton.filled(
                          style: IconButton.styleFrom(
                              backgroundColor: o.voice == VoicePhase.listening ? JColors.cyan : JColors.panelHi,
                              minimumSize: const Size(48, 48)),
                          onPressed: o.tapMic,
                          icon: Icon(o.voice == VoicePhase.listening ? Icons.graphic_eq : Icons.mic,
                              color: o.voice == VoicePhase.listening ? JColors.bg : JColors.cyan),
                          tooltip: 'Talk',
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final StoredMessage m;
  const _Line({required this.m});

  @override
  Widget build(BuildContext context) {
    final user = m.isUser;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: user ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!user)
            const Padding(padding: EdgeInsets.only(top: 3, right: 8), child: Icon(Icons.auto_awesome, size: 16, color: JColors.cyan)),
          Flexible(
            child: Container(
              padding: user ? const EdgeInsets.symmetric(horizontal: 14, vertical: 9) : EdgeInsets.zero,
              decoration: user
                  ? BoxDecoration(color: JColors.blue.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(18))
                  : null,
              child: Text(m.text,
                  style: TextStyle(fontSize: user ? 14 : 16, height: 1.35, color: user ? JColors.text : Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Live extends StatelessWidget {
  final String text;
  const _Live({required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: JColors.cyan)),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(color: JColors.dim, fontStyle: FontStyle.italic)),
        ]),
      );
}
