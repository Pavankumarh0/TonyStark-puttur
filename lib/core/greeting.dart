import 'dart:math';

enum DayPart { earlyMorning, morning, afternoon, evening, night, lateNight }

DayPart dayPartOf(DateTime t) {
  final h = t.hour;
  if (h >= 4 && h < 6) return DayPart.earlyMorning;
  if (h >= 6 && h < 12) return DayPart.morning;
  if (h >= 12 && h < 17) return DayPart.afternoon;
  if (h >= 17 && h < 21) return DayPart.evening;
  if (h >= 21 && h < 24) return DayPart.night;
  return DayPart.lateNight; // 00:00–03:59
}

/// Time-aware, non-repetitive greetings. Purely local — no AI call.
class GreetingGenerator {
  final Random _rng;
  String? _last;
  GreetingGenerator({Random? rng}) : _rng = rng ?? Random();

  String greet({
    required DateTime now,
    String address = 'sir',
    Duration? sinceLastInteraction,
    int? pendingTasks,
  }) {
    final a = address;
    final welcome = sinceLastInteraction == null || sinceLastInteraction > const Duration(hours: 3);
    final options = switch (dayPartOf(now)) {
      DayPart.earlyMorning => [
          'Good morning, $a. You\'re up early. What shall we tackle first?',
          'Good morning, $a. An early start, I see. How can I help?',
        ],
      DayPart.morning => [
          if (welcome) 'Good morning, $a. Welcome back. What would you like me to do today?',
          'Good morning, $a. What would you like me to do today?',
          'Good morning, $a. All systems are ready. What\'s first on the list?',
        ],
      DayPart.afternoon => [
          'Good afternoon, $a. How can I help?',
          if (welcome) 'Good afternoon, $a. Welcome back. What are we working on?',
          'Good afternoon, $a. What can I do for you?',
        ],
      DayPart.evening => [
          if (welcome) 'Good evening, $a. Welcome back. What are we working on today?',
          'Good evening, $a. How can I help?',
          'Good evening, $a. What can I do for you?',
        ],
      DayPart.night => [
          'Good evening, $a. Still working? What can I help you with?',
          'Good evening, $a. Burning the midnight oil, I see. What do you need?',
        ],
      DayPart.lateNight => [
          'It\'s rather late, $a. Still working? What can I help you with?',
          'Working late again, $a? How can I help?',
        ],
    };
    final pool = options.where((o) => o != _last).toList();
    var g = pool[_rng.nextInt(pool.length)];
    if (pendingTasks != null && pendingTasks > 0) {
      g += pendingTasks == 1
          ? ' You also have one unfinished task from earlier.'
          : ' You also have $pendingTasks unfinished tasks from earlier.';
    }
    _last = g;
    return g;
  }

  /// Short acknowledgement when the user wakes LEO mid-conversation.
  String shortAck({String address = 'sir'}) {
    final opts = ['Yes, $address?', 'At your service, $address.', 'Listening, $address.', 'Go ahead, $address.'];
    final pool = opts.where((o) => o != _last).toList();
    final g = pool[_rng.nextInt(pool.length)];
    _last = g;
    return g;
  }
}
