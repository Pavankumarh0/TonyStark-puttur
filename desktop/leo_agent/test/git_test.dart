import 'dart:io';

import 'package:leo_agent/leo_agent.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'agent_test.dart' show TestClient;

/// Real git, real files: temporary repositories with a local bare "remote".
Future<String> sh(String dir, List<String> args) async {
  final r = await Process.run('git', args, workingDirectory: dir, environment: {'GIT_TERMINAL_PROMPT': '0'});
  if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  return (r.stdout as String).trim();
}

void write(String dir, String f, String text) {
  final file = File(p.join(dir, f));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(text);
}

void main() {
  late Directory tmp;
  late String root, work, remote;
  late LeoAgent agent;
  late TestClient c;
  final git = Git();

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('leo_git');
    root = p.join(tmp.path, 'projects');
    work = p.join(root, 'demo');
    remote = p.join(tmp.path, 'remote.git');
    Directory(work).createSync(recursive: true);
    await sh(tmp.path, ['init', '--bare', '-b', 'main', remote]);
    await sh(work, ['init', '-b', 'main']);
    await sh(work, ['config', 'user.name', 'LEO Test']);
    await sh(work, ['config', 'user.email', 'leo@test.local']);
    for (final f in ['a.txt', 'g.txt', 'e.txt']) {
      write(work, f, '$f v1\n');
    }
    await sh(work, ['add', '.']);
    await sh(work, ['commit', '-m', 'initial']);
    await sh(work, ['remote', 'add', 'origin', remote]);
    await sh(work, ['push', '-u', 'origin', 'main']);

    agent = LeoAgent(LeoPaths(p.join(tmp.path, 'leo')),
        projectRoots: [root], qwen: Qwen(host: 'http://127.0.0.1:9')); // no Qwen → fallback messages
    await agent.start();
    c = await TestClient.connect(agent);
    await c.call('hello', {'client': 'desktop-ui'});
  });

  tearDown(() async {
    await c.close();
    await agent.shutdown();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {} // git may still hold a handle on Windows
  });

  Future<Map<String, dynamic>> approveAndFinish(int id, {bool approve = true}) async {
    final ap = await c.waitFor((e) => e['event'] == 'approval.pending' && e['data']['taskId'] == id);
    await c.call('approval.respond', {'id': ap['data']['id'], 'fingerprint': ap['data']['fingerprint'], 'approve': approve});
    final done = await c.waitFor((e) =>
        e['event'] == 'task' && e['data']['id'] == id && const {'completed', 'failed', 'cancelled'}.contains(e['data']['state']));
    return {'approval': ap['data'], 'task': done['data']};
  }

  Future<int> startTask(String kind, Map<String, Object?> params) async {
    final r = await c.call('task.start', {'kind': kind, 'params': params});
    expect(r['error'], isNull, reason: '$r');
    return r['result']['id'] as int;
  }

  test('status: modified, untracked (incl. subfolders), staged, renamed, deleted, upstream', () async {
    write(work, 'a.txt', 'a.txt v2\n');
    write(work, 'b.txt', 'new\n');
    write(work, 'dir/c.txt', 'new\n');
    write(work, 'd.txt', 'staged\n');
    await sh(work, ['add', 'd.txt']);
    await sh(work, ['mv', 'e.txt', 'f.txt']);
    File(p.join(work, 'g.txt')).deleteSync();
    final st = await git.status(work);
    final kinds = {for (final f in st.files) f.path: f.kind};
    expect(kinds['a.txt'], 'modified');
    expect(kinds['b.txt'], 'untracked');
    expect(kinds['dir/c.txt'], 'untracked');
    expect(kinds['d.txt'], 'added');
    expect(kinds['f.txt'], 'renamed');
    expect(st.files.firstWhere((f) => f.path == 'f.txt').from, 'e.txt');
    expect(kinds['g.txt'], 'deleted');
    expect(st.branch, 'main');
    expect(st.upstream, 'origin/main');
  });

  test('conflicts are detected and block committing', () async {
    await sh(work, ['switch', '-c', 'other']);
    write(work, 'a.txt', 'other side\n');
    await sh(work, ['commit', '-am', 'other']);
    await sh(work, ['switch', 'main']);
    write(work, 'a.txt', 'main side\n');
    await sh(work, ['commit', '-am', 'main']);
    await Process.run('git', ['merge', 'other'], workingDirectory: work);
    final st = await git.status(work);
    expect(st.conflicts.map((f) => f.path), ['a.txt']);
    final id = await startTask('git.commit', {'repo': work, 'files': ['a.txt']});
    final t = await c.waitFor((e) => e['event'] == 'task' && e['data']['id'] == id && e['data']['state'] == 'failed');
    expect(t['data']['result'], contains('conflict'));
  });

  test('secret scan: by file name and by content; placeholders and removals are fine', () async {
    write(work, '.env', 'OPENAI_API_KEY=whatever\n');
    write(work, 'server.pem', 'x');
    write(work, 'config.js', 'const key = "sk-proj-${'A1b2C3d4' * 4}";\n');
    write(work, 'creds.py', 'api_key = "Zx81kQp02LmN7vB4wE9r"\n');
    write(work, '.env.example', 'OPENAI_API_KEY=your-key-here\n');
    write(work, 'notes.md', 'just notes\n');
    final found = {
      for (final f in await SecretScanner(git).scan(work, ['.env', 'server.pem', 'config.js', 'creds.py', '.env.example', 'notes.md']))
        f.file: f.reason
    };
    expect(found.keys.toSet(), {'.env', 'server.pem', 'config.js', 'creds.py'});
    expect(found['config.js'], contains('OpenAI'));
    expect(found.values.join(), isNot(contains('A1b2C3d4'))); // never echoes the secret

    // Removing a leaked key must not be blocked.
    write(work, 'g.txt', 'token = "Zx81kQp02LmN7vB4wE9r"\n');
    await sh(work, ['commit', '-am', 'oops']);
    write(work, 'g.txt', 'token = read_from_env()\n');
    expect(await SecretScanner(git).scan(work, ['g.txt']), isEmpty);
  });

  test('COMMIT: only the selected files, secrets excluded, other staged files untouched, verified', () async {
    write(work, 'a.txt', 'a.txt v2\n');
    write(work, 'b.txt', 'new file\n');
    write(work, '.env', 'SARVAM_API_KEY=sk_abcdefghijklmnopqrstuvwx\n');
    write(work, 'd.txt', 'already staged by the user\n');
    await sh(work, ['add', 'd.txt']);
    final before = await sh(work, ['rev-parse', 'HEAD']);

    final id = await startTask('git.commit', {'repo': work, 'files': ['a.txt', 'b.txt', '.env']});
    final r = await approveAndFinish(id);
    final params = r['approval']['params'] as Map;
    expect(params['files'], ['a.txt', 'b.txt']); // .env never offered
    expect((params['excluded'] as List).single, startsWith('.env'));
    expect(params['message'], 'Update a.txt, b.txt'); // Qwen down → fallback
    expect(r['task']['state'], 'completed', reason: '${r['task']['result']}');

    final head = await sh(work, ['rev-parse', 'HEAD']);
    expect(head, isNot(before));
    expect((await sh(work, ['show', '--name-only', '--format=', 'HEAD'])).split('\n')..sort(), ['a.txt', 'b.txt']);
    expect(r['task']['result'], contains(head.substring(0, 8)));
    final st = await git.status(work);
    expect(st.files.firstWhere((f) => f.path == 'd.txt').kind, 'added'); // still staged, not committed
    expect(st.files.firstWhere((f) => f.path == '.env').kind, 'untracked');
  });

  test('COMMIT: your own message is used exactly; rename commits both paths', () async {
    await sh(work, ['mv', 'e.txt', 'renamed.txt']);
    final id = await startTask('git.commit', {'repo': work, 'files': ['renamed.txt'], 'message': 'Rename e to renamed'});
    final r = await approveAndFinish(id);
    expect(r['task']['state'], 'completed', reason: '${r['task']['result']}');
    expect(await sh(work, ['log', '-1', '--format=%s']), 'Rename e to renamed');
    expect((await git.status(work)).files, isEmpty);
  });

  test('COMMIT: deny → nothing committed', () async {
    write(work, 'a.txt', 'v2\n');
    final before = await sh(work, ['rev-parse', 'HEAD']);
    final id = await startTask('git.commit', {'repo': work, 'files': ['a.txt']});
    final r = await approveAndFinish(id, approve: false);
    expect(r['task']['state'], 'cancelled');
    expect(await sh(work, ['rev-parse', 'HEAD']), before);
  });

  test('COMMIT: a failing pre-commit hook is respected (no commit, task failed)', () async {
    write(work, '.git/hooks/pre-commit', '#!/bin/sh\necho "lint failed" >&2\nexit 1\n');
    write(work, 'a.txt', 'v2\n');
    final before = await sh(work, ['rev-parse', 'HEAD']);
    final id = await startTask('git.commit', {'repo': work, 'files': ['a.txt']});
    final r = await approveAndFinish(id);
    expect(r['task']['state'], 'failed');
    expect(await sh(work, ['rev-parse', 'HEAD']), before);
  });

  test('PUSH: outgoing commits shown, push, remote verified', () async {
    write(work, 'a.txt', 'v2\n');
    await sh(work, ['commit', '-am', 'change a']);
    final head = await sh(work, ['rev-parse', 'HEAD']);
    final id = await startTask('git.push', {'repo': work});
    final r = await approveAndFinish(id);
    expect((r['approval']['params']['commits'] as List).single, endsWith('change a'));
    expect(r['approval']['risk'], 'external');
    expect(r['task']['state'], 'completed', reason: '${r['task']['result']}');
    expect((await sh(work, ['ls-remote', 'origin', 'refs/heads/main'])).split('\t').first, head);
  });

  test('PUSH: refused when the remote is ahead (never force-pushes)', () async {
    final other = p.join(tmp.path, 'other');
    await sh(tmp.path, ['clone', remote, other]);
    await sh(other, ['config', 'user.name', 'Other']);
    await sh(other, ['config', 'user.email', 'o@test.local']);
    write(other, 'z.txt', 'from elsewhere\n');
    await sh(other, ['add', '.']);
    await sh(other, ['commit', '-m', 'remote change']);
    await sh(other, ['push']);
    write(work, 'a.txt', 'v2\n');
    await sh(work, ['commit', '-am', 'local change']);
    await sh(work, ['fetch']);
    final id = await startTask('git.push', {'repo': work});
    final t = await c.waitFor((e) => e['event'] == 'task' && e['data']['id'] == id && e['data']['state'] == 'failed');
    expect(t['data']['result'], contains('pull first'));
  });

  test('PULL: fast-forward only, verified', () async {
    final other = p.join(tmp.path, 'other');
    await sh(tmp.path, ['clone', remote, other]);
    await sh(other, ['config', 'user.name', 'Other']);
    await sh(other, ['config', 'user.email', 'o@test.local']);
    write(other, 'z.txt', 'new\n');
    await sh(other, ['add', '.']);
    await sh(other, ['commit', '-m', 'incoming']);
    await sh(other, ['push']);
    final id = await startTask('git.pull', {'repo': work});
    final r = await approveAndFinish(id);
    expect(r['task']['state'], 'completed', reason: '${r['task']['result']}');
    expect(File(p.join(work, 'z.txt')).existsSync(), isTrue);
  });

  test('BRANCH: invalid name refused; valid one created and verified', () async {
    final bad = await startTask('git.branch', {'repo': work, 'name': 'bad..name'});
    await c.waitFor((e) => e['event'] == 'task' && e['data']['id'] == bad && e['data']['state'] == 'failed');
    final id = await startTask('git.branch', {'repo': work, 'name': 'feature/login'});
    final r = await approveAndFinish(id);
    expect(r['task']['state'], 'completed');
    expect(await sh(work, ['branch', '--show-current']), 'feature/login');
  });

  test('only known repositories: an arbitrary folder is refused', () async {
    final outside = p.join(tmp.path, 'outside');
    Directory(outside).createSync();
    await sh(outside, ['init']);
    final r = await c.call('git.status', {'repo': outside});
    expect(r['error']['code'], 'unknown_repo');
    final r2 = await c.call('task.start', {'kind': 'git.commit', 'params': {'repo': 'C:\\Windows', 'files': ['x']}});
    expect(r2['error']['code'], 'unknown_repo');
  });

  test('project names resolve ("demo"), remote URL never shows credentials', () async {
    final info = await c.call('project.select', {'target': 'demo'});
    expect(samePath(info['result']['root'] as String, work), isTrue, reason: '$info');
    await sh(work, ['remote', 'set-url', 'origin', 'https://user:ghp_secret123@github.com/x/y.git']);
    expect(await git.remoteUrl(work), 'https://github.com/x/y.git');
  });

  test('detection: VS Code file → that repo; conflicting signals → ambiguous; selection wins', () async {
    final second = p.join(root, 'second');
    Directory(second).createSync();
    await sh(second, ['init']);
    final d = ProjectDetector(git, roots: [root]);
    d.report(ContextReport('vscode', activeFile: p.join(work, 'a.txt'), workspaceFolders: [work], focused: true));
    var r = await d.detect();
    expect(samePath(r.root!, work), isTrue);
    expect(r.ambiguous, isFalse);
    d.report(ContextReport('cli', cwd: second));
    d.report(ContextReport('vscode', activeFile: p.join(work, 'a.txt'), focused: true)); // focused editor file: 4 = leo here: 4
    r = await d.detect();
    expect(r.ambiguous, isTrue, reason: '${r.toJson()}'); // vscode says demo, terminal says second → ask
    await d.select('second');
    r = await d.detect();
    expect(p.basename(r.root!), 'second');
  });

  test('only the editor extension / CLI may report context', () async {
    final r = await c.call('context.report', {'cwd': work});
    expect(r['error']['code'], 'not_allowed'); // this client is the desktop UI
  });

  test('commit messages: prompt echoes and diff stats are dropped (seen on real Qwen output)', () {
    expect(
        CommitMessageWriter.clean(
            'Add login screen validation\n\nFiles changed:\nlogin.dart | 3 ++-\n 1 file changed, 2 insertions(+), 1 deletion(-)'),
        'Add login screen validation');
    expect(CommitMessageWriter.clean('```\nCommit message: "Fix crash on start"\n\n- Guard null user\n- Add test\n```'),
        'Fix crash on start\n\n- Guard null user\n- Add test');
    expect(CommitMessageWriter.clean('A' * 90).length, lessThanOrEqualTo(72));
  });
}
