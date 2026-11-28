import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/run_clock.dart';
import '../theme.dart';

/// Small top-right chip: a live timer while LEO works, the total once it is done.
/// Only this chip repaints (≈10×/s, and only while running) — the rest of the screen is untouched.
class RunTimerChip extends StatefulWidget {
  final RunClock clock;
  const RunTimerChip({super.key, required this.clock});

  @override
  State<RunTimerChip> createState() => _RunTimerChipState();
}

class _RunTimerChipState extends State<RunTimerChip> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    widget.clock.addListener(_onPhase);
    _onPhase();
  }

  @override
  void didUpdateWidget(RunTimerChip old) {
    super.didUpdateWidget(old);
    if (!identical(old.clock, widget.clock)) {
      old.clock.removeListener(_onPhase);
      widget.clock.addListener(_onPhase);
      _onPhase();
    }
  }

  void _onPhase() {
    final running = widget.clock.phase == RunPhase.running;
    if (running && _tick == null) {
      _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() {});
      });
    } else if (!running) {
      _tick?.cancel();
      _tick = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tick?.cancel();
    widget.clock.removeListener(_onPhase);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.clock;
    final (IconData icon, Color color, String tip) = switch (c.phase) {
      RunPhase.idle => (Icons.timer_outlined, JColors.dim, ''),
      RunPhase.running => (Icons.timer_outlined, JColors.cyan, 'LEO is working'),
      RunPhase.waiting => (Icons.pause_rounded, JColors.amber, 'Waiting for you (not counted)'),
      RunPhase.done => (Icons.check_rounded, JColors.green, 'Time LEO took'),
      RunPhase.failed => (Icons.close_rounded, JColors.dim, 'Stopped / did not finish'),
    };
    if (c.phase == RunPhase.idle) return const SizedBox.shrink();
    final text = RunClock.format(c.elapsed);
    return Tooltip(
      message: tip,
      child: Semantics(
        label: '$tip: $text',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
            // Fixed-width digits so the chip doesn't jitter while counting.
            Text(text,
                style: monoLabel(color: color, size: 10)
                    .copyWith(letterSpacing: 0.5, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        ),
      ),
    );
  }
}
