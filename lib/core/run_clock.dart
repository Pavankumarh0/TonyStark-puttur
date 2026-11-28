import 'package:flutter/foundation.dart';

enum RunPhase { idle, running, waiting, done, failed }

/// Measures how long LEO takes to handle one request: from the end of the user's speech (or the
/// typed request) until the work is finished. Time spent waiting for the user (an approval, a
/// "which one?") is not counted. Notifies only on phase changes — the on-screen chip ticks itself.
class RunClock extends ChangeNotifier {
  RunClock({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;

  RunPhase _phase = RunPhase.idle;
  Duration _acc = Duration.zero;
  DateTime? _segment; // start of the current running stretch

  RunPhase get phase => _phase;
  bool get active => _phase == RunPhase.running || _phase == RunPhase.waiting;
  Duration get elapsed => _acc + (_segment == null ? Duration.zero : _now().difference(_segment!));

  /// A new request. Ignored while one is in progress (e.g. the user answering LEO's question).
  void start() {
    if (active) return;
    _acc = Duration.zero;
    _segment = _now();
    _set(RunPhase.running);
  }

  /// LEO is waiting for the user: stop counting.
  void wait() {
    if (_phase != RunPhase.running) return;
    _acc += _now().difference(_segment!);
    _segment = null;
    _set(RunPhase.waiting);
  }

  /// The user answered: count again.
  void resume() {
    if (_phase != RunPhase.waiting) return;
    _segment = _now();
    _set(RunPhase.running);
  }

  /// Done. [at] lets the caller end the count earlier (e.g. when LEO began its final spoken
  /// confirmation, which isn't part of doing the task).
  void finish({bool ok = true, DateTime? at}) {
    if (!active) return;
    if (_segment != null) {
      var end = at ?? _now();
      if (end.isBefore(_segment!)) end = _segment!;
      _acc += end.difference(_segment!);
      _segment = null;
    }
    _set(ok ? RunPhase.done : RunPhase.failed);
  }

  void _set(RunPhase p) {
    _phase = p;
    notifyListeners();
  }

  /// "0.8s", "12.4s", "1m 05s".
  static String format(Duration d) {
    final ms = d.inMilliseconds;
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
    final s = d.inSeconds;
    return '${s ~/ 60}m ${(s % 60).toString().padLeft(2, '0')}s';
  }
}
