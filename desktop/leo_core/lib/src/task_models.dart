// Shared with the LEO Android app (copied from lib/core/task/task_models.dart). Keep in sync until Android adopts leo_core.
/// Task lifecycle models. Pure Dart — no Flutter imports — so they are unit-testable.
library;

enum AgentState {
  idle,
  listening,
  understanding,
  planning,
  running,
  waitingForApproval,
  paused,
  interrupted,
  completed,
  failed,
  cancelled;

  bool get isTerminal => this == completed || this == failed || this == cancelled;

  /// A task in one of these states can be stopped/paused/cancelled.
  bool get isActive =>
      this == understanding ||
      this == planning ||
      this == running ||
      this == waitingForApproval ||
      this == paused;

  String get label => switch (this) {
        idle => 'IDLE',
        listening => 'LISTENING',
        understanding => 'UNDERSTANDING',
        planning => 'PLANNING',
        running => 'RUNNING',
        waitingForApproval => 'WAITING FOR APPROVAL',
        paused => 'PAUSED',
        interrupted => 'INTERRUPTED',
        completed => 'COMPLETED',
        failed => 'FAILED',
        cancelled => 'CANCELLED',
      };
}

enum StepStatus { pending, running, done, failed, skipped, cancelled }

enum TaskRoute { local, ai }

class TaskStep {
  final String id;
  final String description;
  final StepStatus status;
  final String? detail;

  /// Completing this step has an external effect that cannot be undone (e.g. a sent message).
  final bool irreversible;

  const TaskStep({
    required this.id,
    required this.description,
    this.status = StepStatus.pending,
    this.detail,
    this.irreversible = false,
  });

  TaskStep copyWith({StepStatus? status, String? detail, String? description}) => TaskStep(
        id: id,
        description: description ?? this.description,
        status: status ?? this.status,
        detail: detail ?? this.detail,
        irreversible: irreversible,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'description': description,
        'status': status.name,
        'detail': detail,
        'irreversible': irreversible,
      };

  factory TaskStep.fromJson(Map<String, dynamic> j) => TaskStep(
        id: j['id'] as String,
        description: j['description'] as String,
        status: StepStatus.values.byName(j['status'] as String),
        detail: j['detail'] as String?,
        irreversible: (j['irreversible'] as bool?) ?? false,
      );
}

class TaskSnapshot {
  final int id;
  final String title;
  final String kind;
  final AgentState state;
  final List<TaskStep> steps;
  final TaskRoute route;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? result;

  /// Opaque, JSON-serialisable parameters needed to resume the task (recipient, message, …).
  final Map<String, dynamic> params;

  const TaskSnapshot({
    required this.id,
    required this.title,
    required this.kind,
    required this.state,
    required this.steps,
    required this.route,
    required this.createdAt,
    required this.updatedAt,
    this.result,
    this.params = const {},
  });

  List<TaskStep> get completedSteps => steps.where((s) => s.status == StepStatus.done).toList();
  List<TaskStep> get remainingSteps => steps
      .where((s) => s.status == StepStatus.pending || s.status == StepStatus.running)
      .toList();
  TaskStep? get currentStep {
    for (final s in steps) {
      if (s.status == StepStatus.running) return s;
    }
    return null;
  }

  TaskSnapshot copyWith({
    AgentState? state,
    List<TaskStep>? steps,
    String? result,
    Map<String, dynamic>? params,
    TaskRoute? route,
    String? title,
  }) =>
      TaskSnapshot(
        id: id,
        title: title ?? this.title,
        kind: kind,
        state: state ?? this.state,
        steps: steps ?? this.steps,
        route: route ?? this.route,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
        result: result ?? this.result,
        params: params ?? this.params,
      );
}

class IllegalTransitionException implements Exception {
  final AgentState from;
  final AgentState to;
  IllegalTransitionException(this.from, this.to);
  @override
  String toString() => 'Illegal task transition ${from.name} -> ${to.name}';
}

/// Guards every task state change so the UI never shows a state the task is not in.
class TaskStateMachine {
  static const Map<AgentState, Set<AgentState>> _allowed = {
    AgentState.idle: {AgentState.listening, AgentState.understanding, AgentState.cancelled},
    AgentState.listening: {
      AgentState.understanding,
      AgentState.idle,
      AgentState.cancelled,
      AgentState.interrupted
    },
    AgentState.understanding: {
      AgentState.planning,
      AgentState.running,
      AgentState.completed,
      AgentState.failed,
      AgentState.cancelled,
      AgentState.interrupted
    },
    AgentState.planning: {
      AgentState.running,
      AgentState.waitingForApproval,
      AgentState.completed,
      AgentState.failed,
      AgentState.cancelled,
      AgentState.interrupted
    },
    AgentState.running: {
      AgentState.planning,
      AgentState.waitingForApproval,
      AgentState.paused,
      AgentState.interrupted,
      AgentState.completed,
      AgentState.failed,
      AgentState.cancelled
    },
    AgentState.waitingForApproval: {
      AgentState.running,
      AgentState.planning,
      AgentState.paused,
      AgentState.interrupted,
      AgentState.cancelled,
      AgentState.failed
    },
    AgentState.paused: {
      AgentState.running,
      AgentState.waitingForApproval,
      AgentState.interrupted,
      AgentState.cancelled
    },
    AgentState.interrupted: {
      AgentState.running,
      AgentState.planning,
      AgentState.waitingForApproval,
      AgentState.cancelled
    },
    AgentState.completed: {},
    AgentState.failed: {AgentState.running}, // retry from the failed step
    AgentState.cancelled: {},
  };

  static bool canTransition(AgentState from, AgentState to) =>
      from == to || (_allowed[from]?.contains(to) ?? false);

  static void require(AgentState from, AgentState to) {
    if (!canTransition(from, to)) throw IllegalTransitionException(from, to);
  }
}
