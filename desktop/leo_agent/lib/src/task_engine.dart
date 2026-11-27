import 'dart:async';

import 'package:leo_core/leo_core.dart';

import 'approval_manager.dart';
import 'audit_log.dart';

/// Thrown by a task when the user declines an approval: the task ends as cancelled, and nothing
/// after that point is executed.
class Declined implements Exception {
  final String message;
  Declined(this.message);
  @override
  String toString() => message;
}

/// What a task gets to work with. Every step goes through the shared [TaskControl] checkpoint, so
/// STOP / PAUSE / CANCEL take effect between (and during guarded waits inside) steps.
class TaskContext {
  final TaskTracker tracker;
  final ApprovalManager _approvals;
  final AuditLog audit;
  final TaskEngine _engine;
  TaskContext(this.tracker, this._approvals, this.audit, this._engine);

  int get taskId => tracker.snapshot.id;
  TaskControl get control => tracker.control;
  Future<void> checkpoint() => control.checkpoint();
  Future<T> guard<T>(Future<T> f) => control.guard(f);
  Future<T?> step<T>(String id, Future<T> Function() body, {String? doneDetail}) =>
      tracker.step(id, body, doneDetail: doneDetail);
  void detail(String stepId, String text) => tracker.updateStep(stepId, detail: text);

  /// Asks the user and waits. The returned ticket must be [ApprovalTicket.consume]d with the same
  /// target + params right before acting.
  Future<ApprovalTicket> approve({
    required String action,
    required String title,
    required Risk risk,
    required String target,
    required Map<String, Object?> params,
  }) async {
    await checkpoint();
    _engine._set(tracker, AgentState.waitingForApproval);
    final ticket = await _approvals.request(
        taskId: taskId, action: action, title: title, risk: risk, target: target, params: params, control: control);
    await checkpoint(); // paused while waiting → stays paused until RESUME
    _engine._set(tracker, AgentState.running);
    return ticket;
  }
}

/// A runnable kind of task. [plan] lists the steps up front so the user sees everything that will
/// happen; [run] must end with a verification step and return what was verified.
abstract class TaskDefinition {
  String get kind;
  String get title;
  List<TaskStep> plan();
  Future<String> run(TaskContext c);
}

/// Task Orchestrator core: lifecycle, controls and events.
class TaskEngine {
  final ApprovalManager approvals;
  final AuditLog audit;
  final _tasks = <int, TaskTracker>{};
  final _resumeTo = <int, AgentState>{};
  final _done = <int, Completer<TaskSnapshot>>{};
  final _listeners = <void Function(TaskSnapshot)>[];
  int _nextId = 1;

  TaskEngine(this.approvals, this.audit);

  void addListener(void Function(TaskSnapshot) f) => _listeners.add(f);
  List<TaskSnapshot> get tasks => [for (final t in _tasks.values) t.snapshot];
  TaskSnapshot? get(int id) => _tasks[id]?.snapshot;

  /// Completes when the task reaches a terminal or interrupted state.
  Future<TaskSnapshot> finished(int id) => _done[id]?.future ?? Future.value(_tasks[id]!.snapshot);

  void _set(TaskTracker t, AgentState s, {String? result}) {
    if (t.snapshot.state == s && result == null) return;
    t.setState(s, result: result);
  }

  TaskSnapshot start(TaskDefinition def, {String source = 'agent'}) {
    final id = _nextId++;
    final now = DateTime.now();
    late final TaskTracker tracker;
    tracker = TaskTracker(
      TaskSnapshot(
          id: id, title: def.title, kind: def.kind, state: AgentState.understanding, steps: const [],
          route: TaskRoute.local, createdAt: now, updatedAt: now),
      (s) {
        for (final l in List.of(_listeners)) {
          l(s);
        }
      },
    );
    _tasks[id] = tracker;
    _done[id] = Completer<TaskSnapshot>();
    audit.record('task.started', actor: source, fields: {'task': id, 'kind': def.kind});
    _set(tracker, AgentState.planning);
    for (final s in def.plan()) {
      tracker.addStep(s);
    }
    _set(tracker, AgentState.running);
    unawaited(_run(tracker, def));
    return tracker.snapshot;
  }

  Future<void> _run(TaskTracker t, TaskDefinition def) async {
    final ctx = TaskContext(t, approvals, audit, this);
    try {
      final result = await def.run(ctx);
      await t.control.checkpoint();
      _set(t, AgentState.completed, result: result);
      audit.record('task.completed', fields: {'task': t.snapshot.id, 'kind': def.kind});
    } on TaskAbort catch (a) {
      t.cancelRemaining();
      _set(t, a.reason, result: a.reason == AgentState.cancelled ? 'Cancelled by you' : 'Stopped by you');
      audit.record('task.${a.reason.name}', fields: {'task': t.snapshot.id, 'kind': def.kind});
    } on Declined catch (d) {
      t.cancelRemaining();
      _set(t, AgentState.cancelled, result: d.message);
      audit.record('task.declined', fields: {'task': t.snapshot.id, 'kind': def.kind});
    } catch (e) {
      t.cancelRemaining();
      _set(t, AgentState.failed, result: 'Failed: $e');
      audit.record('task.failed', fields: {'task': t.snapshot.id, 'kind': def.kind, 'error': e.runtimeType.toString()});
    }
    final c = _done[t.snapshot.id];
    if (c != null && !c.isCompleted) c.complete(t.snapshot);
  }

  /// PAUSE: the task halts at its next checkpoint (also while waiting for approval).
  String? pause(int id, {String source = 'agent'}) {
    final t = _tasks[id];
    if (t == null) return 'unknown_task';
    final s = t.snapshot.state;
    if (s != AgentState.running && s != AgentState.waitingForApproval) return 'not_running';
    _resumeTo[id] = s;
    t.control.pause();
    _set(t, AgentState.paused);
    audit.record('task.paused', actor: source, fields: {'task': id});
    return null;
  }

  String? resume(int id, {String source = 'agent'}) {
    final t = _tasks[id];
    if (t == null) return 'unknown_task';
    if (t.snapshot.state != AgentState.paused) return 'not_paused';
    _set(t, _resumeTo.remove(id) ?? AgentState.running);
    t.control.resume();
    audit.record('task.resumed', actor: source, fields: {'task': id});
    return null;
  }

  /// STOP = interrupt now (nothing further runs); CANCEL = abandon the task.
  String? stop(int id, {bool cancel = false, String source = 'agent'}) {
    final t = _tasks[id];
    if (t == null) return 'unknown_task';
    if (!t.snapshot.state.isActive) return 'not_active';
    audit.record(cancel ? 'task.cancel_requested' : 'task.stop_requested', actor: source, fields: {'task': id});
    t.control.abort(cancel ? AgentState.cancelled : AgentState.interrupted);
    return null;
  }

  /// STOP everything (shutdown, or the user says "stop").
  void stopAll({String source = 'agent'}) {
    for (final id in _tasks.keys.toList()) {
      if (_tasks[id]!.snapshot.state.isActive) stop(id, source: source);
    }
  }

  static Map<String, Object?> toJson(TaskSnapshot s) => {
        'id': s.id,
        'title': s.title,
        'kind': s.kind,
        'state': s.state.name,
        'stateLabel': s.state.label,
        'result': s.result,
        'createdAt': s.createdAt.toIso8601String(),
        'updatedAt': s.updatedAt.toIso8601String(),
        'steps': [for (final st in s.steps) st.toJson()],
      };
}
