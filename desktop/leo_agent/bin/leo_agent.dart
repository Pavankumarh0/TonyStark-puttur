import 'dart:async';
import 'dart:io';

import 'package:leo_agent/leo_agent.dart';

/// Runs the LEO Desktop agent until Ctrl+C. Prints only non-secret status (never the token).
Future<void> main(List<String> args) async {
  final agent = LeoAgent(LeoPaths.forUser());
  try {
    await agent.start();
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exit(2);
  }
  stdout.writeln('LEO agent $agentVersion listening on 127.0.0.1:${agent.ipc.port} (pid $pid)');
  final done = Completer<void>();
  for (final sig in [ProcessSignal.sigint, if (!Platform.isWindows) ProcessSignal.sigterm]) {
    sig.watch().listen((_) {
      if (!done.isCompleted) done.complete();
    });
  }
  await done.future;
  stdout.writeln('Stopping…');
  await agent.shutdown();
  exit(0);
}
