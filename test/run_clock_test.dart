import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/run_clock.dart';

void main() {
  late DateTime t;
  RunClock clock() => RunClock(now: () => t);
  void after(int ms) => t = t.add(Duration(milliseconds: ms));

  setUp(() => t = DateTime(2026, 11, 28, 10));

  test('counts while running and freezes the total when done', () {
    final c = clock()..start();
    after(1200);
    expect(c.phase, RunPhase.running);
    expect(c.elapsed.inMilliseconds, 1200);
    c.finish();
    after(5000);
    expect(c.phase, RunPhase.done);
    expect(c.elapsed.inMilliseconds, 1200); // stays put after finishing
  });

  test('time spent waiting for the user is not counted', () {
    final c = clock()..start();
    after(800);
    c.wait(); // "Shall I send it?"
    after(6000); // the user thinks
    c.resume();
    after(700);
    c.finish();
    expect(c.elapsed.inMilliseconds, 1500);
  });

  test('the closing spoken confirmation can be left out', () {
    final c = clock()..start();
    after(900);
    final speechStart = t;
    after(1800); // "WhatsApp is open, sir."
    c.finish(at: speechStart);
    expect(c.elapsed.inMilliseconds, 900);
  });

  test('an answer during a request does not restart it; a new request does', () {
    final c = clock()..start();
    after(500);
    c.start(); // ignored: still working
    after(500);
    expect(c.elapsed.inMilliseconds, 1000);
    c.finish(ok: false);
    expect(c.phase, RunPhase.failed);
    c.start();
    after(300);
    expect(c.elapsed.inMilliseconds, 300);
  });

  test('format is short', () {
    expect(RunClock.format(const Duration(milliseconds: 870)), '0.9s');
    expect(RunClock.format(const Duration(milliseconds: 12400)), '12.4s');
    expect(RunClock.format(const Duration(seconds: 65)), '1m 05s');
  });
}
