import 'dart:async';

import 'task_models.dart';

/// Thrown inside a running task when the user STOPs or CANCELs it.
class TaskAbort implements Exception {
  final AgentState reason; // interrupted or cancelled
  TaskAbort(this.reason);
  @override
  String toString() => 'TaskAbort(${reason.name})';
}

/// Cooperative cancellation + pause control for one task.
///
/// Every step calls [checkpoint] before doing work, and wraps long awaits in [guard] so a
/// STOP takes effect immediately instead of after the network call returns.
class TaskControl {
  AgentState? _abortReason;
  Completer<void>? _resume;
  final _abortSignal = Completer<void>();
  final List<void Function()> _onAbort = [];

  bool get isAborted => _abortReason != null;
  bool get isPaused => _resume != null;
  AgentState? get abortReason => _abortReason;

  void abort(AgentState reason) {
    if (_abortReason != null) return;
    _abortReason = reason;
    _resume?.complete();
    _resume = null;
    if (!_abortSignal.isCompleted) _abortSignal.complete();
    for (final f in List.of(_onAbort)) {
      try {
        f();
      } catch (_) {}
    }
  }

  /// Registers a hook that cancels in-flight native/network work (e.g. close an HTTP client).
  void onAbort(void Function() f) {
    if (isAborted) {
      f();
    } else {
      _onAbort.add(f);
    }
  }

  void pause() {
    if (isAborted || _resume != null) return;
    _resume = Completer<void>();
  }

  void resume() {
    _resume?.complete();
    _resume = null;
  }

  Future<void> checkpoint() async {
    if (_abortReason != null) throw TaskAbort(_abortReason!);
    while (_resume != null) {
      await _resume!.future;
      if (_abortReason != null) throw TaskAbort(_abortReason!);
    }
  }

  /// Races [f] against an abort. The underlying work may continue, but its result is ignored.
  Future<T> guard<T>(Future<T> f) async {
    await checkpoint();
    final result = await Future.any<Object?>([
      f.then<Object?>((v) => _Box(v)),
      _abortSignal.future.then<Object?>((_) => null),
    ]);
    if (_abortReason != null) throw TaskAbort(_abortReason!);
    return (result as _Box).value as T;
  }
}

class _Box {
  final Object? value;
  _Box(this.value);
}

/// Mutable holder used by the orchestrator to publish step progress.
class TaskTracker {
  TaskSnapshot snapshot;
  TaskControl control = TaskControl();
  final void Function(TaskSnapshot) onChange;

  TaskTracker(this.snapshot, this.onChange);

  void setState(AgentState s, {String? result}) {
    TaskStateMachine.require(snapshot.state, s);
    snapshot = snapshot.copyWith(state: s, result: result);
    onChange(snapshot);
  }

  void setParams(Map<String, dynamic> p) {
    snapshot = snapshot.copyWith(params: {...snapshot.params, ...p});
    onChange(snapshot);
  }

  void addStep(TaskStep step) {
    snapshot = snapshot.copyWith(steps: [...snapshot.steps, step]);
    onChange(snapshot);
  }

  void updateStep(String id, {StepStatus? status, String? detail, String? description}) {
    snapshot = snapshot.copyWith(
      steps: [
        for (final s in snapshot.steps)
          if (s.id == id) s.copyWith(status: status, detail: detail, description: description) else s
      ],
    );
    onChange(snapshot);
  }

  StepStatus? stepStatus(String id) {
    for (final s in snapshot.steps) {
      if (s.id == id) return s.status;
    }
    return null;
  }

  /// Runs a step once. If it already completed (e.g. when resuming), it is skipped.
  Future<T?> step<T>(String id, Future<T> Function() body, {String? doneDetail}) async {
    if (stepStatus(id) == StepStatus.done) return null;
    await control.checkpoint();
    updateStep(id, status: StepStatus.running);
    try {
      final r = await control.guard(body());
      updateStep(id, status: StepStatus.done, detail: doneDetail);
      return r;
    } on TaskAbort {
      updateStep(id, status: StepStatus.cancelled);
      rethrow;
    } catch (e) {
      updateStep(id, status: StepStatus.failed, detail: e.toString());
      rethrow;
    }
  }

  /// Marks remaining pending/running steps as cancelled after an abort.
  void cancelRemaining() {
    snapshot = snapshot.copyWith(steps: [
      for (final s in snapshot.steps)
        if (s.status == StepStatus.pending || s.status == StepStatus.running)
          s.copyWith(status: StepStatus.cancelled)
        else
          s
    ]);
    onChange(snapshot);
  }

  /// Re-arms cancelled steps so "continue where you stopped" can re-run them.
  /// Steps that completed (including irreversible ones like a sent message) are never re-run.
  void reopenCancelled() {
    control = TaskControl();
    snapshot = snapshot.copyWith(steps: [
      for (final s in snapshot.steps)
        if (s.status == StepStatus.cancelled || s.status == StepStatus.failed)
          s.copyWith(status: StepStatus.pending)
        else
          s
    ]);
    onChange(snapshot);
  }
}
