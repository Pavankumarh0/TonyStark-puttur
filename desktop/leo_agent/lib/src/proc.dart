import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ProcResult {
  final int code;
  final String out;
  final String err;
  final bool timedOut;
  const ProcResult(this.code, this.out, this.err, {this.timedOut = false});
  bool get ok => code == 0 && !timedOut;
}

/// Runs a program with an argument LIST — never through a shell, so arguments (file names,
/// commit messages, branch names) can never be interpreted as commands.
Future<ProcResult> runProc(String exe, List<String> args,
    {String? cwd, Duration timeout = const Duration(seconds: 60), Map<String, String>? env, String? stdin}) async {
  final p = await Process.start(exe, args,
      workingDirectory: cwd, environment: env, runInShell: false, includeParentEnvironment: true);
  final out = p.stdout.transform(utf8.decoder).join();
  final err = p.stderr.transform(utf8.decoder).join();
  if (stdin != null) {
    p.stdin.add(utf8.encode(stdin));
  }
  await p.stdin.close();
  var timedOut = false;
  final code = await p.exitCode.timeout(timeout, onTimeout: () {
    timedOut = true;
    p.kill(ProcessSignal.sigkill);
    return -1;
  });
  return ProcResult(code, await out, await err, timedOut: timedOut);
}
