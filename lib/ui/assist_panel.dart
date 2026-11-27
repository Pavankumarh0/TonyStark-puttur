import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../device/device_bridge.dart';
import '../orchestrator/jarvis_orchestrator.dart';
import '../voice/mic_engine.dart';
import 'home_screen.dart';
import 'theme.dart';
import 'widgets/orb.dart';

/// Half-screen assistant panel shown over other apps when JARVIS is invoked as the phone's
/// digital assistant (long-press side key / corner swipe). Tap outside to dismiss.
class AssistPanel extends StatefulWidget {
  const AssistPanel({super.key});

  @override
  State<AssistPanel> createState() => _AssistPanelState();
}

class _AssistPanelState extends State<AssistPanel> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final o = context.watch<JarvisOrchestrator>();
    final mic = context.watch<MicEngine>();
    final device = context.read<DeviceBridge>();
    final d = o.display;
    String lastOf(bool user) {
      for (var i = o.messages.length - 1; i >= 0; i--) {
        if (o.messages[i].isUser == user) return o.messages[i].text;
      }
      return '';
    }

    final lastJarvisText = lastOf(false);
    final lastUserText = lastOf(true);
    final task = o.task;
    final h = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      body: Column(
        children: [
          Expanded(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: device.closeAssist)),
          Container(
            constraints: BoxConstraints(maxHeight: h * 0.62),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [JColors.panel, JColors.bg],
              ),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(top: BorderSide(color: d.color.withValues(alpha: 0.6), width: 1.5)),
              boxShadow: [BoxShadow(color: d.color.withValues(alpha: 0.25), blurRadius: 30, spreadRadius: 2)],
            ),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                          width: 40, height: 4, decoration: BoxDecoration(color: JColors.line, borderRadius: BorderRadius.circular(2))),
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      JarvisOrb(state: d, micLevel: mic.level, size: 76, onTap: o.tapMic),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(d.label, style: TextStyle(color: d.color, letterSpacing: 2, fontWeight: FontWeight.w700, fontSize: 12)),
                          const SizedBox(height: 4),
                          if (o.voice == VoicePhase.listening)
                            const Text('Go ahead, I\'m listening…', style: TextStyle(color: JColors.dim))
                          else if (lastUserText.isNotEmpty)
                            Text('"$lastUserText"',
                                maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: JColors.dim, fontSize: 13)),
                        ]),
                      ),
                      IconButton(
                        tooltip: 'Open JARVIS',
                        onPressed: device.openFullApp,
                        icon: const Icon(Icons.open_in_full, color: JColors.dim),
                      ),
                    ]),
                    if (lastJarvisText.isNotEmpty && o.voice != VoicePhase.listening) ...[
                      const SizedBox(height: 10),
                      Text(lastJarvisText, maxLines: 8, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, height: 1.4)),
                    ],
                    if (o.pendingApproval != null) ...[
                      const SizedBox(height: 12),
                      ApprovalCard(req: o.pendingApproval!, o: o),
                    ],
                    if (o.choice != null) ...[
                      const SizedBox(height: 12),
                      ChoiceCard(prompt: o.choice!, onPick: o.choose),
                    ],
                    if (task != null && task.state.isActive && o.pendingApproval == null) ...[
                      const SizedBox(height: 12),
                      TaskPanel(task: task, o: o),
                    ],
                    const SizedBox(height: 12),
                    Row(children: [
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
                          decoration: const InputDecoration(hintText: 'Ask JARVIS…', isDense: true),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filled(
                        style: IconButton.styleFrom(backgroundColor: o.voice == VoicePhase.listening ? JColors.cyan : JColors.panelHi),
                        onPressed: o.tapMic,
                        icon: Icon(o.voice == VoicePhase.listening ? Icons.graphic_eq : Icons.mic,
                            color: o.voice == VoicePhase.listening ? JColors.bg : JColors.cyan),
                        tooltip: 'Talk',
                      ),
                    ]),
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
