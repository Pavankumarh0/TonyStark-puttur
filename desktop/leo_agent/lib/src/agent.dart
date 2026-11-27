import 'dart:convert';
import 'dart:io';

import 'approval_manager.dart';
import 'audit_log.dart';
import 'ipc_server.dart';
import 'paths.dart';
import 'task_engine.dart';
import 'tasks/self_test_task.dart';

const agentVersion = '0.1.0';

/// The LEO Desktop agent service: owns tasks, approvals and the audit log, and serves local clients.
class LeoAgent {
  final LeoPaths paths;
  late final AuditLog audit;
  late final ApprovalManager approvals;
  late final TaskEngine engine;
  late final IpcServer ipc;
  RandomAccessFile? _lock;

  LeoAgent(this.paths, {Duration approvalTimeout = const Duration(minutes: 10)}) {
    paths.ensure();
    audit = AuditLog(paths.auditDir);
    approvals = ApprovalManager(audit, timeout: approvalTimeout);
    engine = TaskEngine(approvals, audit);
    ipc = IpcServer();
  }

  /// Task kinds a client may start (allowlist). Later phases add git.*, code.*, …
  Map<String, TaskDefinition Function(Map<String, Object?> params)> get _kinds => {
        'selftest': (p) => SelfTestTask(paths.workDir,
            count: (p['count'] as int?)?.clamp(1, 100) ?? 10,
            tick: Duration(milliseconds: (p['tickMs'] as int?)?.clamp(10, 5000) ?? 700)),
      };

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
    int id(Map<String, Object?> p) {
      final v = p['id'];
      if (v is! int) throw RpcError('bad_params', 'id must be an integer');
      return v;
    }

    void ok(String? err) {
      if (err != null) throw RpcError(err);
    }

    ipc.method('hello', (c, p) {
      final name = '${p['client'] ?? 'unknown'}';
      if (!RegExp(r'^[a-z0-9_-]{1,32}$').hasMatch(name)) throw RpcError('bad_params', 'client');
      c.name = name;
      audit.record('client.connected', actor: name);
      return {
        'version': agentVersion,
        'tasks': [for (final t in engine.tasks) TaskEngine.toJson(t)],
        'approvals': [for (final a in approvals.pending) a.toJson()],
        'kinds': _kinds.keys.toList(),
      };
    });
    ipc.method('ping', (c, p) => {'pong': DateTime.now().toIso8601String()});
    ipc.method('task.start', (c, p) {
      final make = _kinds['${p['kind']}'];
      if (make == null) throw RpcError('kind_not_allowed', '${p['kind']}');
      final params = p['params'] is Map ? Map<String, Object?>.from(p['params'] as Map) : <String, Object?>{};
      return TaskEngine.toJson(engine.start(make(params), source: src(c)));
    });
    ipc.method('task.pause', (c, p) => ok(engine.pause(id(p), source: src(c))));
    ipc.method('task.resume', (c, p) => ok(engine.resume(id(p), source: src(c))));
    ipc.method('task.stop', (c, p) => ok(engine.stop(id(p), source: src(c))));
    ipc.method('task.cancel', (c, p) => ok(engine.stop(id(p), cancel: true, source: src(c))));
    ipc.method('task.stopAll', (c, p) => engine.stopAll(source: src(c)));
    ipc.method('approval.respond', (c, p) {
      final rid = p['id'], fp = p['fingerprint'], approve = p['approve'];
      if (rid is! String || fp is! String || approve is! bool) throw RpcError('bad_params');
      ok(approvals.respond(id: rid, fingerprint: fp, approve: approve, source: src(c)));
      return null;
    });
    ipc.method('audit.tail', (c, p) => audit.tail(((p['n'] as int?) ?? 50).clamp(1, 500)));
    ipc.method('audit.verify', (c, p) {
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
