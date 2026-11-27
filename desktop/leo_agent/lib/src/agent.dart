import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ai/qwen.dart';
import 'approval_manager.dart';
import 'audit_log.dart';
import 'git/git.dart';
import 'git/secret_scan.dart';
import 'ipc_server.dart';
import 'paths.dart';
import 'projects/project_detector.dart';
import 'task_engine.dart';
import 'tasks/git_tasks.dart';
import 'tasks/self_test_task.dart';

const agentVersion = '0.2.0';

/// The LEO Desktop agent service: owns tasks, approvals, projects, Git and the audit log, and
/// serves local clients (desktop UI, VS Code extension, `leo` CLI, later the TFT bridge).
class LeoAgent {
  final LeoPaths paths;
  late final AuditLog audit;
  late final ApprovalManager approvals;
  late final TaskEngine engine;
  late final IpcServer ipc;
  final Git git;
  late final ProjectDetector projects;
  final Qwen qwen;
  late final CommitMessageWriter writer;
  RandomAccessFile? _lock;

  LeoAgent(this.paths,
      {Duration approvalTimeout = const Duration(minutes: 10), List<String>? projectRoots, Git? git, Qwen? qwen})
      : git = git ?? Git(),
        qwen = qwen ?? Qwen() {
    paths.ensure();
    audit = AuditLog(paths.auditDir);
    approvals = ApprovalManager(audit, timeout: approvalTimeout);
    engine = TaskEngine(approvals, audit);
    ipc = IpcServer();
    projects = ProjectDetector(this.git, roots: projectRoots ?? ProjectDetector.defaultRoots());
    writer = CommitMessageWriter(this.qwen);
  }

  /// Task kinds a client may start (allowlist).
  static const kinds = ['selftest', 'git.commit', 'git.push', 'git.pull', 'git.branch'];

  Future<TaskDefinition> _makeTask(String kind, Map<String, Object?> prm) async {
    if (!kinds.contains(kind)) throw RpcError('kind_not_allowed', kind);
    if (kind == 'selftest') {
      return SelfTestTask(paths.workDir,
          count: (prm['count'] as int?)?.clamp(1, 100) ?? 10,
          tick: Duration(milliseconds: (prm['tickMs'] as int?)?.clamp(10, 5000) ?? 700));
    }
    final repo = await _repo(prm);
    switch (kind) {
      case 'git.commit':
        final files = prm['files'];
        if (files is! List || files.isEmpty || files.any((f) => f is! String)) throw RpcError('bad_params', 'files');
        final msg = prm['message'];
        return GitCommitTask(git, writer, repo: repo, files: files.cast<String>(), message: msg is String ? msg : null);
      case 'git.push':
        return GitPushTask(git, repo: repo);
      case 'git.pull':
        return GitPullTask(git, repo: repo);
      default:
        final name = prm['name'];
        if (name is! String || name.isEmpty) throw RpcError('bad_params', 'name');
        return GitBranchTask(git, repo: repo, name: name);
    }
  }

  /// A repository named by a client — only known repositories are accepted, never arbitrary paths.
  Future<String> _repo(Map<String, Object?> prm) async {
    final r = prm['repo'];
    if (r is! String || r.isEmpty) throw RpcError('bad_params', 'repo');
    final root = await projects.resolve(r);
    if (root == null) throw RpcError('unknown_repo', r);
    return root;
  }

  static List<String> _strings(Object? v) => v is List ? v.whereType<String>().take(500).toList() : const [];

  Future<void> start({int port = 0}) async {
    // Single instance per user.
    _lock = File(paths.lockFile).openSync(mode: FileMode.write);
    try {
      _lock!.lockSync(FileLock.exclusive);
    } on FileSystemException {
      _lock!.closeSync();
      _lock = null;
      throw StateError('Another LEO agent is already running for this user.');
    }

    ipc.onSecurityEvent = (e, f) => audit.record(e, actor: 'ipc', fields: f);
    engine.addListener((s) => ipc.broadcast('task', TaskEngine.toJson(s)));
    approvals.addListener((e, d) => ipc.broadcast(e, d));
    audit.addListener((e) => ipc.broadcast('audit', e));
    _registerMethods();
    await ipc.start(port: port);

    // Discovery file for local clients: written atomically, inside the user's own profile.
    final tmp = File('${paths.discoveryFile}.tmp');
    tmp.writeAsStringSync(jsonEncode({'port': ipc.port, 'token': ipc.token, 'pid': pid, 'version': agentVersion}), flush: true);
    if (File(paths.discoveryFile).existsSync()) File(paths.discoveryFile).deleteSync();
    tmp.renameSync(paths.discoveryFile);
    audit.record('agent.started', fields: {'version': agentVersion, 'port': ipc.port});
  }

  void _registerMethods() {
    String src(IpcClient c) => c.name;
    int id(Map<String, Object?> prm) {
      final v = prm['id'];
      if (v is! int) throw RpcError('bad_params', 'id must be an integer');
      return v;
    }

    void ok(String? err) {
      if (err != null) throw RpcError(err);
    }

    ipc.method('hello', (c, prm) {
      final name = '${prm['client'] ?? 'unknown'}';
      if (!RegExp(r'^[a-z0-9_-]{1,32}$').hasMatch(name)) throw RpcError('bad_params', 'client');
      c.name = name;
      audit.record('client.connected', actor: name);
      return {
        'version': agentVersion,
        'tasks': [for (final t in engine.tasks) TaskEngine.toJson(t)],
        'approvals': [for (final a in approvals.pending) a.toJson()],
        'kinds': kinds,
      };
    });
    ipc.method('ping', (c, prm) => {'pong': DateTime.now().toIso8601String()});

    // ---- tasks ----
    ipc.method('task.start', (c, prm) async {
      final params = prm['params'] is Map ? Map<String, Object?>.from(prm['params'] as Map) : <String, Object?>{};
      final def = await _makeTask('${prm['kind']}', params);
      return TaskEngine.toJson(engine.start(def, source: src(c)));
    });
    ipc.method('task.pause', (c, prm) => ok(engine.pause(id(prm), source: src(c))));
    ipc.method('task.resume', (c, prm) => ok(engine.resume(id(prm), source: src(c))));
    ipc.method('task.stop', (c, prm) => ok(engine.stop(id(prm), source: src(c))));
    ipc.method('task.cancel', (c, prm) => ok(engine.stop(id(prm), cancel: true, source: src(c))));
    ipc.method('task.stopAll', (c, prm) => engine.stopAll(source: src(c)));
    ipc.method('approval.respond', (c, prm) {
      final rid = prm['id'], fp = prm['fingerprint'], approve = prm['approve'];
      if (rid is! String || fp is! String || approve is! bool) throw RpcError('bad_params');
      ok(approvals.respond(id: rid, fingerprint: fp, approve: approve, source: src(c)));
      return null;
    });

    // ---- projects ----
    ipc.method('project.list', (c, prm) async => [
          for (final r in await projects.knownRepos()) {'name': p.basename(r), 'root': r}
        ]);
    ipc.method('project.detect', (c, prm) async {
      final d = await projects.detect();
      return {...d.toJson(), 'info': d.root == null ? null : await projects.info(d.root!)};
    });
    ipc.method('project.select', (c, prm) async {
      final t = prm['target'];
      if (t is! String) throw RpcError('bad_params', 'target');
      try {
        final root = await projects.select(t);
        audit.record('project.selected', actor: src(c), fields: {'project': p.basename(root)});
        return await projects.info(root);
      } on GitError catch (e) {
        throw RpcError('unknown_repo', e.message);
      }
    });
    ipc.method('project.info', (c, prm) async => projects.info(await _repo(prm)));
    ipc.method('context.report', (c, prm) {
      // Only the editor extension and the `leo here` CLI may report where the user is working.
      if (c.name != 'vscode' && c.name != 'cli') throw RpcError('not_allowed', c.name);
      final at = prm['activeFile'], tc = prm['terminalCwd'], cwd = prm['cwd'];
      projects.report(ContextReport(c.name,
          workspaceFolders: _strings(prm['workspaceFolders']).take(20).toList(),
          activeFile: at is String ? at : null,
          terminalCwd: tc is String ? tc : null,
          cwd: cwd is String ? cwd : null,
          focused: prm['focused'] == true));
      return null;
    });

    // ---- git: read-only here; writes only happen inside approved tasks ----
    ipc.method('git.status', (c, prm) async => (await git.status(await _repo(prm))).toJson());
    ipc.method('git.diff', (c, prm) async {
      final f = prm['file'];
      if (f is! String) throw RpcError('bad_params', 'file');
      return {'file': f, 'diff': await git.diff(await _repo(prm), f)};
    });
    ipc.method('git.log', (c, prm) async =>
        [for (final x in await git.log(await _repo(prm), n: ((prm['n'] as int?) ?? 10).clamp(1, 100))) x.toJson()]);
    ipc.method('git.scan', (c, prm) async {
      final repo = await _repo(prm);
      return [for (final f in await SecretScanner(git).scan(repo, _strings(prm['files']))) f.toJson()];
    });
    ipc.method('git.message', (c, prm) async {
      final repo = await _repo(prm);
      final files = _strings(prm['files']);
      final bad = {for (final f in await SecretScanner(git).scan(repo, files)) f.file};
      final okFiles = files.where((f) => !bad.contains(f)).toList();
      if (okFiles.isEmpty) throw RpcError('nothing_to_commit');
      final diffs = await Future.wait(okFiles.take(12).map((f) => git.diff(repo, f, maxBytes: 4000)));
      final (m, source) = await writer.write(stat: await git.diffStat(repo, okFiles), diff: diffs.join('\n'), files: okFiles);
      return {'message': m, 'source': source};
    });
    ipc.method('qwen.status', (c, prm) async => {'model': qwen.model, 'available': await qwen.available()});

    // ---- audit ----
    ipc.method('audit.tail', (c, prm) => audit.tail(((prm['n'] as int?) ?? 50).clamp(1, 500)));
    ipc.method('audit.verify', (c, prm) {
      final v = audit.verify();
      return {'ok': v.ok, 'checked': v.checked, 'brokenAt': v.brokenAt};
    });
  }

  Future<void> shutdown() async {
    engine.stopAll();
    approvals.denyAll('agent_shutdown');
    audit.record('agent.stopped');
    await ipc.close();
    try {
      File(paths.discoveryFile).deleteSync();
    } catch (_) {}
    try {
      _lock?.unlockSync();
      _lock?.closeSync();
    } catch (_) {}
  }
}
