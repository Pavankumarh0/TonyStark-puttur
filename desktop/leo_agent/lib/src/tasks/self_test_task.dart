import 'dart:io';

import 'package:leo_core/leo_core.dart';
import 'package:path/path.dart' as p;

import '../approval_manager.dart';
import '../task_engine.dart';

/// End-to-end check of the task pipeline with a real (harmless) side effect:
/// count (pausable) → ask approval → write a file in LEO's own work folder → read it back.
class SelfTestTask extends TaskDefinition {
  final String workDir;
  final int count;
  final Duration tick;
  SelfTestTask(this.workDir, {this.count = 10, this.tick = const Duration(milliseconds: 700)});

  @override
  String get kind => 'selftest';
  @override
  String get title => 'Self-test: count, approve, write, verify';

  @override
  List<TaskStep> plan() => [
        const TaskStep(id: 'prepare', description: 'Prepare work folder'),
        TaskStep(id: 'count', description: 'Count to $count (try PAUSE / STOP here)'),
        const TaskStep(id: 'approve', description: 'Ask your approval to write a test file'),
        const TaskStep(id: 'write', description: 'Write the test file'),
        const TaskStep(id: 'verify', description: 'Read it back and verify'),
      ];

  @override
  Future<String> run(TaskContext c) async {
    final dir = p.join(workDir, 'selftest');
    final file = p.join(dir, 'task-${c.taskId}.txt');
    final content = 'LEO self-test task ${c.taskId} at ${DateTime.now().toUtc().toIso8601String()}';

    await c.step('prepare', () async => Directory(dir).createSync(recursive: true), doneDetail: dir);

    await c.step('count', () async {
      for (var i = 1; i <= count; i++) {
        await c.checkpoint(); // PAUSE blocks here, STOP/CANCEL throws here
        await c.guard(Future<void>.delayed(tick));
        c.detail('count', '$i / $count');
      }
    });

    late ApprovalTicket ticket;
    final params = <String, Object?>{'path': file, 'bytes': content.length, 'content': content};
    await c.step('approve', () async {
      ticket = await c.approve(
          action: 'file.write', title: 'Write a test file', risk: Risk.writeLocal, target: file, params: params);
      if (!ticket.approved) throw Declined('You declined, so nothing was written.');
    }, doneDetail: 'Approved');

    await c.step('write', () async {
      // The ticket only works for exactly what was approved.
      if (!ticket.consume(file, params)) throw StateError('approval does not match this write');
      File(file).writeAsStringSync(content, flush: true);
    }, doneDetail: '${content.length} bytes');

    await c.step('verify', () async {
      final back = File(file).readAsStringSync();
      if (back != content) throw StateError('file content differs from what was written');
    }, doneDetail: 'Content matches');

    return 'Wrote and verified ${p.basename(file)} (${content.length} bytes).';
  }
}
