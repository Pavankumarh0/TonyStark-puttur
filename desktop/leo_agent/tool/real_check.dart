// Read-only check against the real project folders + a real Qwen commit message on a scratch repo.
//   dart run tool/real_check.dart
import 'dart:io';

import 'package:leo_agent/leo_agent.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final git = Git();
  final det = ProjectDetector(git, roots: ProjectDetector.defaultRoots());
  final sw = Stopwatch()..start();
  final repos = await det.knownRepos();
  print('Known repos under Documents\\projects: ${repos.length} (${sw.elapsedMilliseconds} ms)');

  for (final name in ['nocom', 'kadamly']) {
    final root = await det.resolve(name);
    if (root == null) {
      print('$name: NOT FOUND');
      continue;
    }
    sw.reset();
    final info = await det.info(root);
    final st = await git.status(root);
    final scan = await SecretScanner(git).scan(root, [for (final f in st.files) f.path]);
    final last = info['latestCommit'] as Map?;
    print('\n$name  (${sw.elapsedMilliseconds} ms, read-only)');
    print('  root      ${info['root']}');
    print('  remote    ${info['remote']}');
    print('  branch    ${info['branch']}  upstream ${info['upstream']}  ahead ${info['ahead']} behind ${info['behind']}');
    print('  changes   ${info['modifiedCount']} modified, ${info['untrackedCount']} untracked, ${info['conflictCount']} conflicts');
    print('  latest    ${last == null ? '-' : '${(last['hash'] as String).substring(0, 8)} ${last['subject']}'}');
    for (final f in st.files.take(8)) {
      print('    ${f.kind.padRight(9)} ${f.path}');
    }
    if (st.files.length > 8) print('    … ${st.files.length - 8} more');
    print('  secrets   ${scan.isEmpty ? 'none in changed files' : scan.map((s) => '${s.file}: ${s.reason}').join('; ')}');
  }

  final d = await det.detect();
  print('\nActive-project detection now: ${d.root ?? (d.ambiguous ? 'ambiguous → ask' : 'none')}');
  for (final c in d.candidates.take(4)) {
    print('  ${c.name}: score ${c.score} (${c.why.join(', ')})');
  }

  // Real Qwen on a scratch repo (never on the user's projects).
  final tmp = Directory.systemTemp.createTempSync('leo_qwen');
  Future<void> g(List<String> a) => Process.run('git', a, workingDirectory: tmp.path);
  await g(['init', '-b', 'main']);
  await g(['config', 'user.name', 'LEO Test']);
  await g(['config', 'user.email', 'leo@test.local']);
  File(p.join(tmp.path, 'login.dart')).writeAsStringSync('bool validEmail(String e) => e.contains("@");\n');
  await g(['add', '.']);
  await g(['commit', '-m', 'init']);
  File(p.join(tmp.path, 'login.dart')).writeAsStringSync(
      'bool validEmail(String e) => RegExp(r"^[^@\\s]+@[^@\\s]+\\.[^@\\s]+\$").hasMatch(e);\n'
      'bool validPassword(String p) => p.length >= 8;\n');
  final q = Qwen();
  print('\nQwen ${q.model} available: ${await q.available()}');
  sw.reset();
  final w = CommitMessageWriter(q);
  final (msg, src) = await w.write(
      stat: await git.diffStat(tmp.path, ['login.dart']), diff: await git.diff(tmp.path, 'login.dart'), files: ['login.dart']);
  print('Commit message ($src, ${sw.elapsedMilliseconds} ms):\n  ${msg.replaceAll('\n', '\n  ')}');
  try {
    tmp.deleteSync(recursive: true);
  } catch (_) {}
}
