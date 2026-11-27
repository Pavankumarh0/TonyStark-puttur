import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/time_parser.dart';

void main() {
  // Thursday 27 Nov 2026, 16:30
  final now = DateTime(2026, 11, 27, 16, 30);
  DateTime w(String s, {bool pm = false}) => TimeParser.when(s, now: now, preferPm: pm)!.at;

  test('6:30 am → tomorrow (already past today)', () => expect(w('set alarm for 6:30 am'), DateTime(2026, 11, 28, 6, 30)));
  test('6.30 pm → today', () => expect(w('wake me at 6.30 pm'), DateTime(2026, 11, 27, 18, 30)));
  test('7 tomorrow → 7 AM tomorrow', () => expect(w('wake me up at 7 tomorrow'), DateTime(2026, 11, 28, 7, 0)));
  test('at 8 (no am/pm, 8 AM passed) → 8 PM today', () => expect(w('alarm at 8'), DateTime(2026, 11, 27, 20, 0)));
  test('meeting tomorrow at 3 → 3 PM', () => expect(w('meeting tomorrow at 3', pm: true), DateTime(2026, 11, 28, 15, 0)));
  test('tomorrow at 10 am', () => expect(w('tomorrow at 10 am'), DateTime(2026, 11, 28, 10, 0)));
  test('in 10 minutes', () => expect(w('remind me in 10 minutes'), DateTime(2026, 11, 27, 16, 40)));
  test('in 2 hours', () => expect(w('in 2 hours'), DateTime(2026, 11, 27, 18, 30)));
  test('next monday at 9:15 am', () => expect(w('next monday at 9:15 am'), DateTime(2026, 11, 30, 9, 15)));
  test('on friday evening', () => expect(w('call on friday evening'), DateTime(2026, 12, 4, 18, 0)));
  test('5th december at 4 pm', () => expect(w('on 5th december at 4 pm'), DateTime(2026, 12, 5, 16, 0)));
  test('december 1 at 11', () => expect(w('december 1 at 11 am'), DateTime(2026, 12, 1, 11, 0)));
  test('tonight at 9', () => expect(w('tonight at 9'), DateTime(2026, 11, 27, 21, 0)));
  test('noon tomorrow', () => expect(w('tomorrow noon'), DateTime(2026, 11, 28, 12, 0)));
  test('six thirty pm (words)', () => expect(w('at six thirty pm'), DateTime(2026, 11, 27, 18, 30)));
  test('no time → null', () => expect(TimeParser.when('hello there', now: now), isNull));
  test('"in 5 people" not a time', () => expect(TimeParser.when('meeting for 5 people', now: now), isNull));

  test('durations', () {
    expect(TimeParser.duration('set a timer for 10 minutes'), const Duration(minutes: 10));
    expect(TimeParser.duration('1 hour 30 minutes'), const Duration(minutes: 90));
    expect(TimeParser.duration('timer for 90 seconds'), const Duration(seconds: 90));
    expect(TimeParser.duration('half an hour'), const Duration(minutes: 30));
    expect(TimeParser.duration('five minutes'), const Duration(minutes: 5));
  });

  test('spoken', () {
    expect(TimeParser.spoken(DateTime(2026, 11, 28, 6, 30), now: now), '6:30 AM tomorrow');
    expect(TimeParser.spoken(DateTime(2026, 11, 27, 15, 0), now: now), '3 PM today');
  });
}
