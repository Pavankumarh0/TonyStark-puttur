import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../orchestrator/jarvis_orchestrator.dart';
import '../theme.dart';

/// LEO voice core (matches the landing page orb): glassy green sphere, radial equalizer,
/// expanding sound rings and two tilted orbits. Motion follows the REAL state; while listening
/// the equalizer is driven by the live microphone level.
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
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat();
  StreamSubscription<double>? _sub;
  double _level = 0;

  @override
  void initState() {
    super.initState();
    _sub = widget.micLevel.listen((v) => _level = _level * 0.6 + v * 0.4);
  }

  @override
  void didUpdateWidget(covariant JarvisOrb old) {
    super.didUpdateWidget(old);
    if (old.micLevel != widget.micLevel) {
      _sub?.cancel();
      _sub = widget.micLevel.listen((v) => _level = _level * 0.6 + v * 0.4);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
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
                  t: _c.value * 12, // seconds
                  state: widget.state,
                  level: widget.state == DisplayState.listening ? _level : null,
                ),
              ),
            ),
          ),
        ),
      );
}

double _seeded(int i) {
  final x = sin(i * 12.9898 + 78.233) * 43758.5453;
  return x - x.floorToDouble();
}

class _OrbPainter extends CustomPainter {
  final double t;
  final DisplayState state;
  final double? level;
  _OrbPainter({required this.t, required this.state, this.level});

  bool get _active => state != DisplayState.offline;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final w = size.shortestSide;
    final sphereR = w * 0.26;
    final accent = state.color;

    // Ambient glow
    final breathe = 0.85 + 0.15 * sin(t * 2 * pi / 4.2);
    canvas.drawCircle(
      c,
      w * 0.62,
      Paint()
        ..shader = RadialGradient(colors: [
          accent.withValues(alpha: _active ? 0.26 * breathe : 0.08),
          accent.withValues(alpha: _active ? 0.07 : 0.02),
          Colors.transparent,
        ], stops: const [0, 0.38, 0.68])
            .createShader(Rect.fromCircle(center: c, radius: w * 0.62)),
    );

    // Expanding sound rings
    if (_active) {
      for (var i = 0; i < 3; i++) {
        final p = ((t + i * 1.2) % 3.6) / 3.6;
        canvas.drawCircle(
            c,
            sphereR * (1 + p * 0.95),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2
              ..color = accent.withValues(alpha: 0.55 * (1 - p)));
      }
    }

    _orbits(canvas, c, w, accent, back: true);

    // Radial equalizer (84 bars)
    const bars = 84;
    final barPaint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = max(1.5, w * 0.008);
    final ringR = w * 0.305;
    for (var i = 0; i < bars; i++) {
      final a = i / bars * 2 * pi - pi / 2;
      final base = 0.025 + _seeded(i) * 0.075;
      double amp;
      if (level != null) {
        amp = base * (0.35 + level! * 2.4 * (0.6 + 0.4 * sin(t * 9 + i * 0.8)));
      } else if (state == DisplayState.speaking) {
        amp = base * (0.5 + 0.5 * (0.5 + 0.5 * sin(t * (6 + _seeded(i + 100) * 6) + i)));
      } else if (_active) {
        amp = base * (0.28 + 0.72 * (0.5 + 0.5 * sin(t * 2 * pi / (0.7 + _seeded(i + 100) * 1.1) + _seeded(i + 200) * 6)));
      } else {
        amp = base * 0.22;
      }
      final dir = Offset(cos(a), sin(a));
      barPaint.color = accent.withValues(alpha: (0.3 + _seeded(i + 300) * 0.55) * (_active ? 1 : 0.5));
      canvas.drawLine(c + dir * ringR, c + dir * (ringR + amp * w), barPaint);
    }

    // Glass sphere
    final pulse = _active ? 1 + 0.03 * sin(t * 2 * pi / 2.6) : 1.0;
    final r = sphereR * pulse;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, 0.16),
          colors: _active
              ? const [Color(0xFFC8FFD9), Color(0xFF5DFF94), Color(0xFF0F8A3A), Color(0xFF063D1A), Color(0xFF032611), Color(0xFF021108)]
              : const [Color(0xFF5F8A6C), Color(0xFF2C5A3A), Color(0xFF123C20), Color(0xFF07240F), Color(0xFF041A0B), Color(0xFF021108)],
          stops: const [0, 0.16, 0.34, 0.58, 0.8, 1],
        ).createShader(rect),
    );
    canvas.save();
    canvas.clipPath(Path()..addOval(rect));
    final blob = Paint()..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.35);
    canvas.drawCircle(c + Offset(sin(t * 0.9) * r * 0.25, cos(t * 0.7) * r * 0.22), r * 0.55,
        blob..color = const Color(0xFFB4FFCB).withValues(alpha: _active ? 0.45 : 0.12));
    canvas.drawCircle(c + Offset(cos(t * 0.6) * r * 0.3, sin(t * 0.8) * r * 0.25), r * 0.5,
        blob..color = JColors.volt.withValues(alpha: _active ? 0.35 : 0.08));
    if (state == DisplayState.speaking || state == DisplayState.listening || state == DisplayState.thinking) {
      final env = state == DisplayState.listening
          ? (0.2 + (level ?? 0) * 2.5).clamp(0.2, 1.0)
          : 0.45 + 0.55 * (sin(t * 1.9) * sin(t * 0.73 + 1.2)).abs();
      const waves = [
        (1.6, 3.1, 0.0, 0.24, Color(0xBFFFFFFF)),
        (2.3, -2.4, 1.7, 0.18, Color(0x8C04190C)),
        (3.1, 4.2, 3.1, 0.13, Color(0xB3B4FFD2)),
      ];
      for (final (freq, speed, phase, amp, color) in waves) {
        final path = Path();
        for (var i = 0; i <= 48; i++) {
          final u = i / 48;
          final taper = pow(sin(pi * u), 2).toDouble();
          final x = c.dx - r * 0.88 + u * r * 1.76;
          final y = c.dy + sin(u * freq * pi * 2 + t * speed + phase) * amp * r * taper * env;
          if (i == 0) {
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = color);
      }
    }
    canvas.restore();
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6)], stops: const [0.52, 1])
              .createShader(rect));
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFFB4FFD2).withValues(alpha: 0.28));
    canvas.save();
    canvas.translate(c.dx - r * 0.32, c.dy - r * 0.55);
    canvas.rotate(-28 * pi / 180);
    canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: r * 0.68, height: r * 0.4),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.33)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    canvas.restore();

    _orbits(canvas, c, w, accent, back: false);
  }

  /// Two tilted elliptical orbits; the back half is drawn under the sphere, the front over it.
  void _orbits(Canvas canvas, Offset c, double w, Color accent, {required bool back}) {
    const rings = [(0.56, 0.24, -14.0, 9.0, 1.0), (0.46, 0.17, 24.0, 13.0, -1.0)];
    for (final (rx, ry, tiltDeg, speed, dir) in rings) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(tiltDeg * pi / 180);
      final rect = Rect.fromCenter(center: Offset.zero, width: w * rx * 2, height: w * ry * 2);
      canvas.drawArc(
          rect,
          back ? pi : 0,
          pi,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = accent.withValues(alpha: 0.15));
      final ang = (t / speed) * 2 * pi * dir;
      final p = Offset(cos(ang) * w * rx, sin(ang) * w * ry);
      final inBack = sin(ang) < 0;
      if (inBack == back && _active) {
        canvas.drawCircle(
            p,
            w * 0.016,
            Paint()
              ..color = accent.withValues(alpha: 0.4)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
        canvas.drawCircle(p, w * 0.011, Paint()..color = accent);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) => true;
}

/// Small static orb used for the logo, avatars and the voice bar (".orb-mini" on the site).
class OrbMini extends StatelessWidget {
  final double size;
  const OrbMini({super.key, this.size = 24});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const RadialGradient(
            center: Alignment(0, 0.2),
            colors: [Color(0xFFC8FFD9), JColors.voltDeep, Color(0xFF063D1A), Color(0xFF021108)],
            stops: [0, 0.38, 0.75, 1],
          ),
          boxShadow: [BoxShadow(color: JColors.volt.withValues(alpha: 0.45), blurRadius: size * 0.6)],
        ),
        child: Align(
          alignment: const Alignment(-0.35, -0.45),
          child: Container(
            width: size * 0.32,
            height: size * 0.22,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(size)),
          ),
        ),
      );
}

/// Row of equalizer bars ("Waveform" on the site). Animated only while [active].
class Waveform extends StatefulWidget {
  final int bars;
  final int seed;
  final bool active;
  final Color color;
  final double height;
  const Waveform({super.key, this.bars = 6, this.seed = 9, this.active = true, this.color = JColors.volt, this.height = 16});

  @override
  State<Waveform> createState() => _WaveformState();
}

class _WaveformState extends State<Waveform> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < widget.bars; i++)
              Container(
                width: 3,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                height: widget.height *
                    (widget.active
                        ? 0.28 + 0.72 * (0.5 + 0.5 * sin(_c.value * 2 * pi * 4 / (0.65 + _seeded(i + widget.seed * 97 + 41) * 0.9) + _seeded(i + widget.seed * 13) * 6))
                        : 0.22) *
                    (0.4 + _seeded(i + widget.seed * 97) * 0.6),
                decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(2)),
              ),
          ],
        ),
      );
}
