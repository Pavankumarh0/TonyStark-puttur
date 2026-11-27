import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../orchestrator/jarvis_orchestrator.dart';
import '../theme.dart';

/// Circular voice visualisation. Colour + motion are a function of the REAL state; the radial
/// waveform uses the live microphone level while listening.
class JarvisOrb extends StatefulWidget {
  final DisplayState state;
  final Stream<double> micLevel;
  final double size;
  final VoidCallback? onTap;
  const JarvisOrb({super.key, required this.state, required this.micLevel, this.size = 260, this.onTap});

  @override
  State<JarvisOrb> createState() => _JarvisOrbState();
}

class _JarvisOrbState extends State<JarvisOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 8))..repeat();
  final List<double> _levels = List<double>.filled(64, 0, growable: true);
  StreamSubscription<double>? _sub;
  double _smoothed = 0;

  @override
  void initState() {
    super.initState();
    _sub = widget.micLevel.listen(_onLevel);
  }

  @override
  void didUpdateWidget(covariant JarvisOrb old) {
    super.didUpdateWidget(old);
    if (old.micLevel != widget.micLevel) {
      _sub?.cancel();
      _sub = widget.micLevel.listen(_onLevel);
    }
  }

  void _onLevel(double v) {
    _smoothed = _smoothed * 0.6 + v * 0.4;
    _levels.removeAt(0);
    _levels.add(_smoothed);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'LEO status: ${widget.state.label}',
      button: widget.onTap != null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox.square(
          dimension: widget.size,
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, _) => CustomPaint(
              painter: _OrbPainter(
                t: _c.value,
                state: widget.state,
                levels: widget.state == DisplayState.listening ? _levels : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  final double t;
  final DisplayState state;
  final List<double>? levels;
  _OrbPainter({required this.t, required this.state, this.levels});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final color = state.color;
    final phase = t * 2 * pi;

    // Ambient glow
    final breathing = switch (state) {
      DisplayState.offline => 0.15,
      DisplayState.waiting => 0.35 + 0.1 * sin(phase * 2),
      DisplayState.listening => 0.55,
      DisplayState.thinking => 0.45 + 0.15 * sin(phase * 6),
      DisplayState.speaking => 0.5 + 0.2 * sin(phase * 9),
      DisplayState.executing => 0.45,
      DisplayState.approval || DisplayState.paused => 0.35 + 0.2 * sin(phase * 4),
    };
    canvas.drawCircle(
      c,
      r * 0.62,
      Paint()
        ..shader = RadialGradient(colors: [color.withValues(alpha: breathing), color.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: c, radius: r * 0.95)),
    );

    // Outer ticks ring (rotates slowly)
    final tick = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeWidth = 1.4;
    for (var i = 0; i < 72; i++) {
      final a = i / 72 * 2 * pi + phase * 0.25;
      final len = i % 6 == 0 ? 10.0 : 4.0;
      canvas.drawLine(c + Offset(cos(a), sin(a)) * (r - 4), c + Offset(cos(a), sin(a)) * (r - 4 - len), tick);
    }

    // Radial waveform: live mic levels when listening, synthetic voice envelope when speaking.
    final bars = 64;
    final barPaint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3
      ..color = color.withValues(alpha: 0.9);
    for (var i = 0; i < bars; i++) {
      final a = i / bars * 2 * pi - pi / 2;
      double amp;
      if (levels != null) {
        amp = levels![(i + levels!.length - bars) % levels!.length];
      } else if (state == DisplayState.speaking) {
        amp = 0.25 + 0.35 * (0.5 + 0.5 * sin(phase * 14 + i * 0.7)) * (0.5 + 0.5 * sin(phase * 5 + i * 0.23));
      } else if (state == DisplayState.thinking) {
        amp = 0.08 + 0.12 * (0.5 + 0.5 * sin(phase * 8 - i * 0.4));
      } else {
        amp = 0.04;
      }
      final inner = r * 0.66;
      final outer = inner + 6 + amp * r * 0.26;
      canvas.drawLine(c + Offset(cos(a), sin(a)) * inner, c + Offset(cos(a), sin(a)) * outer, barPaint);
    }

    // Arcs
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3
      ..color = color.withValues(alpha: 0.8);
    final rect1 = Rect.fromCircle(center: c, radius: r * 0.56);
    final spin = switch (state) {
      DisplayState.thinking => phase * 3,
      DisplayState.executing => phase * 2,
      DisplayState.offline => 0.0,
      _ => phase * 0.6,
    };
    canvas.drawArc(rect1, spin, pi * 0.6, false, arc);
    canvas.drawArc(rect1, spin + pi, pi * 0.6, false, arc);
    final rect2 = Rect.fromCircle(center: c, radius: r * 0.48);
    canvas.drawArc(rect2, -spin * 1.3, pi * 0.35, false, arc..color = JColors.blue.withValues(alpha: 0.7));
    canvas.drawArc(rect2, -spin * 1.3 + pi, pi * 0.35, false, arc);

    // Executing: orbiting step dots
    if (state == DisplayState.executing) {
      for (var i = 0; i < 3; i++) {
        final a = phase * 2 + i * 2 * pi / 3;
        canvas.drawCircle(c + Offset(cos(a), sin(a)) * r * 0.52, 4, Paint()..color = JColors.green);
      }
    }

    // Core
    final coreR = r * 0.34 + (state == DisplayState.listening && levels != null ? levels!.last * r * 0.06 : 0);
    canvas.drawCircle(
      c,
      coreR,
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.white.withValues(alpha: state == DisplayState.offline ? 0.15 : 0.55),
          color.withValues(alpha: 0.55),
          JColors.navy.withValues(alpha: 0.9),
        ], stops: const [0, 0.35, 1])
            .createShader(Rect.fromCircle(center: c, radius: coreR)),
    );
    canvas.drawCircle(
        c,
        coreR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) => true;
}
