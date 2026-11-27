import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:leo_agent/leo_agent.dart';
import 'package:leo_core/leo_core.dart';
import 'package:test/test.dart';

/// Minimal client that speaks the agent's IPC protocol (same as the desktop UI).
class TestClient {
  final WebSocket ws;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final events = StreamController<Map<String, dynamic>>.broadcast();
  final seen = <Map<String, dynamic>>[];
  int _id = 0;

  TestClient(this.ws) {
    ws.listen((d) {
      final m = jsonDecode(d as String) as Map<String, dynamic>;
      if (m.containsKey('event')) {
        seen.add(m);
        events.add(m);
      } else {
        _pending.remove(m['id'])?.complete(m);
      }
    });
  }

  static Future<TestClient> connect(LeoAgent a) async => TestClient(await WebSocket.connect(
      'ws://127.0.0.1:${a.ipc.port}/ws',
      headers: {'Authorization': 'Bearer ${a.ipc.token}'}));

  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> params = const {}]) {
    final id = ++_id;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    ws.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return c.future.timeout(const Duration(seconds: 5));
  }

  Future<Map<String, dynamic>> waitFor(bool Function(Map<String, dynamic>) test, {int seconds = 10}) async {
    for (final e in seen) {
      if (test(e)) return e;
    }
    return events.stream.firstWhere(test).timeout(Duration(seconds: seconds));
  }

  Map<String, dynamic>? lastTask(int id) {
    for (final e in seen.reversed) {
      if (e['event'] == 'task' && e['data']['id'] == id) return e['data'] as Map<String, dynamic>;
    }
    return null;
  }

  Future<void> close() => ws.close();
}

void main() {
  late Directory tmp;
  late LeoAgent agent;
  late TestClient c;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('leo_agent_test');
    agent = LeoAgent(LeoPaths(tmp.path));
    await agent.start();
    c = await TestClient.connect(agent);
    await c.call('hello', {'client': 'test'});
  });

  tearDown(() async {
    await c.close();
    await agent.shutdown();
    tmp.deleteSync(recursive: true);
  });

  Future<int> startSelfTest({int count = 6, int tickMs = 80}) async {
    final r = await c.call('task.start', {'kind': 'selftest', 'params': {'count': count, 'tickMs': tickMs}});
    return r['result']['id'] as int;
  }

  String countDetail(int id) {
    final steps = (c.lastTask(id)?['steps'] as List?) ?? const [];
    return '${steps.firstWhere((s) => s['id'] == 'count', orElse: () => {})['detail'] ?? ''}';
  }

  group('IPC security', () {
    test('wrong token is refused', () async {
      expect(
          () => WebSocket.connect('ws://127.0.0.1:${agent.ipc.port}/ws', headers: {'Authorization': 'Bearer nope'}),
          throwsA(isA<WebSocketException>()));
    });

    test('a browser (Origin header) is refused even with the token', () async {
      expect(
          () => WebSocket.connect('ws://127.0.0.1:${agent.ipc.port}/ws',
              headers: {'Authorization': 'Bearer ${agent.ipc.token}', 'Origin': 'https://evil.example'}),
          throwsA(isA<WebSocketException>()));
    });

    test('only registered methods and allowlisted task kinds exist', () async {
      expect((await c.call('shell.exec', {'cmd': 'whoami'}))['error']['code'], 'unknown_method');
      expect((await c.call('task.start', {'kind': 'format_disk'}))['error']['code'], 'kind_not_allowed');
    });

    test('discovery file holds port + token and lives in the agent folder', () {
      final j = jsonDecode(File(agent.paths.discoveryFile).readAsStringSync()) as Map;
      expect(j['port'], agent.ipc.port);
      expect(j['token'], agent.ipc.token);
    });

    test('a second agent for the same user is refused', () async {
      expect(() => LeoAgent(LeoPaths(tmp.path)).start(), throwsStateError);
    });
  });

  group('task controls', () {
    test('full run: approve → file written → verified', () async {
      final id = await startSelfTest();
      final ap = await c.waitFor((e) => e['event'] == 'approval.pending');
      final req = ap['data'] as Map<String, dynamic>;
      expect(req['action'], 'file.write');
      expect((await c.call('approval.respond', {'id': req['id'], 'fingerprint': req['fingerprint'], 'approve': true}))['error'],
          isNull);
      final done = await c.waitFor((e) => e['event'] == 'task' && e['data']['id'] == id && e['data']['state'] == 'completed');
      expect(done['data']['result'], contains('verified'));
      expect(File(req['params']['path'] as String).readAsStringSync(), req['params']['content']);
    });

    test('PAUSE halts progress, RESUME continues', () async {
      final id = await startSelfTest(count: 30, tickMs: 60);
      await c.waitFor((e) => e['event'] == 'task' && e['data']['id'] == id && countDetail(id).startsWith('2 '));
      expect((await c.call('task.pause', {'id': id}))['error'], isNull);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final at = countDetail(id);
      await Future<void>.delayed(const Duration(milliseconds: 600)); // ~10 ticks would have happened
      expect(countDetail(id), at);
      expect(c.lastTask(id)!['state'], 'paused');
      expect((await c.call('task.resume', {'id': id}))['error'], isNull);
      await c.waitFor((e) => e['event'] == 'task' && e['data']['id'] == id && countDetail(id) != at);
      await c.call('task.cancel', {'id': id});
    });

    test('STOP interrupts: nothing after it runs, no file written', () async {
      final id = await startSelfTest(count: 40, tickMs: 50);
      await c.waitFor((e) => e['event'] == 'task' && e['data']['id'] == id && countDetail(id).startsWith('3 '));
      await c.call('task.stop', {'id': id});
      final end = await c.waitFor((e) => e['event'] == 'task' && e['data']['id'] == id && e['data']['state'] == 'interrupted');
      final steps = (end['data']['steps'] as List).cast<Map>();
      expect(steps.where((s) => s['id'] == 'write').single['status'], 'cancelled');
      expect(Directory('${agent.paths.workDir}/selftest').listSync(), isEmpty);
    });

    test('CANCEL while waiting for approval: request withdrawn, nothing written', () async {
      final id = await startSelfTest(count: 1, tickMs: 10);
      final ap = await c.waitFor((e) => e['event'] == 'approval.pending');
      await c.call('task.cancel', {'id': id});
      await c.waitFor((e) => e['event'] == 'task' && e['data']['id'] == id && e['data']['state'] == 'cancelled');
      final late = await c.call('approval.respond',
          {'id': ap['data']['id'], 'fingerprint': ap['data']['fingerprint'], 'approve': true});
      expect(late['error']['code'], 'unknown_or_expired_request');
      expect(Directory('${agent.paths.workDir}/selftest').listSync(), isEmpty);
    });

    test('PAUSE during approval: approving does not run the task until RESUME', () async {
      final id = await startSelfTest(count: 1, tickMs: 10);
      final ap = await c.waitFor((e) => e['event'] == 'approval.pending');
      await c.call('task.pause', {'id': id});
      await c.call('approval.respond', {'id': ap['data']['id'], 'fingerprint': ap['data']['fingerprint'], 'approve': true});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(c.lastTask(id)!['state'], 'paused');
      expect(Directory('${agent.paths.workDir}/selftest').listSync(), isEmpty);
      await c.call('task.resume', {'id': id});
      await c.waitFor((e) => e['event'] == 'task' && e['data']['id'] == id && e['data']['state'] == 'completed');
    });
  });

  group('approvals', () {
    test('deny → task cancelled, nothing written', () async {
      final id = await startSelfTest(count: 1, tickMs: 10);
      final ap = await c.waitFor((e) => e['event'] == 'approval.pending');
      await c.call('approval.respond', {'id': ap['data']['id'], 'fingerprint': ap['data']['fingerprint'], 'approve': false});
      final end = await c.waitFor((e) => e['event'] == 'task' && e['data']['id'] == id && e['data']['state'] == 'cancelled');
      expect(end['data']['result'], contains('declined'));
      expect(Directory('${agent.paths.workDir}/selftest').listSync(), isEmpty);
    });

    test('an answer with the wrong fingerprint is rejected and the request stays pending', () async {
      await startSelfTest(count: 1, tickMs: 10);
      final ap = await c.waitFor((e) => e['event'] == 'approval.pending');
      final r = await c.call('approval.respond', {'id': ap['data']['id'], 'fingerprint': 'forged', 'approve': true});
      expect(r['error']['code'], 'fingerprint_mismatch');
      expect(agent.approvals.pending.map((p) => p.id), contains(ap['data']['id']));
    });

    test('an approval ticket only works for the exact parameters approved', () async {
      final mgr = ApprovalManager(agent.audit);
      final f = mgr.request(
          taskId: 1, action: 'file.write', title: 't', risk: Risk.writeLocal, target: 'a.txt', params: {'content': 'x'});
      final v = mgr.pending.single;
      mgr.respond(id: v.id, fingerprint: v.fingerprint, approve: true, source: 'test');
      final t = await f;
      expect(t.consume('a.txt', {'content': 'y'}), isFalse); // different content → refused (and voided)
      expect(t.consume('a.txt', {'content': 'x'}), isFalse); // voided after a mismatch
    });

    test('unanswered approvals expire as denied', () async {
      final mgr = ApprovalManager(agent.audit, timeout: const Duration(milliseconds: 100));
      final t = await mgr.request(
          taskId: 1, action: 'x', title: 't', risk: Risk.writeLocal, target: 'a', params: const {});
      expect(t.approved, isFalse);
    });
  });

  group('audit log', () {
    test('records the run, verifies, and detects tampering', () async {
      final id = await startSelfTest(count: 1, tickMs: 10);
      final ap = await c.waitFor((e) => e['event'] == 'approval.pending');
      await c.call('approval.respond', {'id': ap['data']['id'], 'fingerprint': ap['data']['fingerprint'], 'approve': true});
      await c.waitFor((e) => e['event'] == 'task' && e['data']['id'] == id && e['data']['state'] == 'completed');
      final actions = [for (final e in agent.audit.tail(50)) e['action']];
      expect(actions, containsAll(['agent.started', 'task.started', 'approval.requested', 'approval.approved', 'task.completed']));
      expect(agent.audit.verify().ok, isTrue);

      // Never the file content or the token.
      final raw = Directory(agent.paths.auditDir).listSync().whereType<File>().map((f) => f.readAsStringSync()).join();
      expect(raw, isNot(contains('LEO self-test task')));
      expect(raw, isNot(contains(agent.ipc.token)));

      // Edit one line → chain broken at that entry.
      final f = Directory(agent.paths.auditDir).listSync().whereType<File>().first;
      final lines = f.readAsLinesSync();
      final edited = lines[1].replaceFirst(RegExp(r'"ts":"[^"]+"'), '"ts":"2000-01-01T00:00:00.000Z"');
      expect(edited, isNot(lines[1]));
      lines[1] = edited;
      f.writeAsStringSync('${lines.join('\n')}\n');
      final v = AuditLog(agent.paths.auditDir).verify();
      expect(v.ok, isFalse);
      expect(v.brokenAt, 2);
    });

    test('free text is masked and shortened', () {
      final e = agent.audit.record('x', fields: {'note': 'call 9845012345 ${'a' * 300}'});
      expect(e['note'], isNot(contains('9845012345')));
      expect((e['note'] as String).length, lessThanOrEqualTo(120));
    });
  });

  test('state machine is shared with Android (leo_core)', () {
    expect(TaskStateMachine.canTransition(AgentState.completed, AgentState.running), isFalse);
  });
}
