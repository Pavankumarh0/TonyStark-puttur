import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:leo_core/leo_core.dart';

import 'audit_log.dart';

enum Risk { read, writeLocal, external }

/// A request the user must approve. [params] are shown to the user exactly as executed.
class ApprovalRequestView {
  final String id;
  final int taskId;
  final String action; // e.g. git.commit, file.write
  final String title;
  final Risk risk;
  final String target; // repo / file / remote the action touches
  final Map<String, Object?> params;
  final String fingerprint; // what the approver must echo back
  final DateTime expiresAt;

  ApprovalRequestView({
    required this.id,
    required this.taskId,
    required this.action,
    required this.title,
    required this.risk,
    required this.target,
    required this.params,
    required this.fingerprint,
    required this.expiresAt,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'taskId': taskId,
        'action': action,
        'title': title,
        'risk': risk.name,
        'target': target,
        'params': params,
        'fingerprint': fingerprint,
        'expiresAt': expiresAt.toIso8601String(),
      };
}

class _Pending {
  final ApprovalRequestView view;
  final ApprovalGate gate;
  final Completer<bool> done = Completer<bool>();
  Timer? timer;
  _Pending(this.view, this.gate);
}

/// Approval decision handed to the executor. It can be used exactly once, and only for the exact
/// action + target + params that were approved ([consume] re-checks them right before executing).
class ApprovalTicket {
  final bool approved;
  final ApprovalGate _gate;
  final String _action;
  ApprovalTicket._(this.approved, this._gate, this._action);

  bool consume(String target, Map<String, Object?> params) =>
      approved && _gate.consume(_action, target, ApprovalManager.canonical(params));
}

/// Permission & Approval Manager. Approvals can come from any client (desktop UI, TFT): the
/// response must name the request id AND echo its fingerprint, so a stale or forged response
/// for different parameters is rejected.
class ApprovalManager {
  final AuditLog audit;
  final Duration timeout;
  final _pending = <String, _Pending>{};
  final _rnd = Random.secure();
  final _listeners = <void Function(String event, Map<String, Object?> data)>[];

  ApprovalManager(this.audit, {this.timeout = const Duration(minutes: 10)});

  void addListener(void Function(String event, Map<String, Object?> data) f) => _listeners.add(f);
  void _emit(String e, Map<String, Object?> d) {
    for (final l in List.of(_listeners)) {
      l(e, d);
    }
  }

  List<ApprovalRequestView> get pending => [for (final p in _pending.values) p.view];

  /// Stable text form of the parameters (sorted keys) — the thing approval is bound to.
  static String canonical(Map<String, Object?> params) {
    Object? sortDeep(Object? v) => v is Map
        ? {for (final k in (v.keys.map((e) => '$e').toList()..sort())) k: sortDeep(v[k])}
        : v is List
            ? [for (final x in v) sortDeep(x)]
            : v;
    return jsonEncode(sortDeep(params));
  }

  Future<ApprovalTicket> request({
    required int taskId,
    required String action,
    required String title,
    required Risk risk,
    required String target,
    required Map<String, Object?> params,
    TaskControl? control,
  }) async {
    final id = List.generate(8, (_) => _rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final gate = ApprovalGate();
    final content = canonical(params);
    gate.request(ApprovalRequest(id: id, actionType: action, title: title, recipientId: target, content: content));
    final view = ApprovalRequestView(
      id: id,
      taskId: taskId,
      action: action,
      title: title,
      risk: risk,
      target: target,
      params: params,
      fingerprint: ApprovalGate.fingerprintOf(action, target, content),
      expiresAt: DateTime.now().add(timeout),
    );
    final p = _Pending(view, gate);
    _pending[id] = p;
    p.timer = Timer(timeout, () => _finish(id, false, 'timeout'));
    control?.onAbort(() => _finish(id, false, 'task_stopped'));
    audit.record('approval.requested', fields: {'task': taskId, 'request': id, 'kind': action, 'risk': risk.name});
    _emit('approval.pending', view.toJson());
    final ok = await p.done.future;
    return ApprovalTicket._(ok, gate, action);
  }

  /// A client's answer. Returns null on success, or the reason it was rejected.
  String? respond({required String id, required String fingerprint, required bool approve, required String source}) {
    final p = _pending[id];
    if (p == null) return 'unknown_or_expired_request';
    if (fingerprint != p.view.fingerprint) {
      audit.record('approval.rejected_response', actor: source, fields: {'request': id, 'reason': 'fingerprint_mismatch'});
      return 'fingerprint_mismatch';
    }
    if (approve) p.gate.approve();
    _finish(id, approve, approve ? 'approved' : 'denied', source: source);
    return null;
  }

  void _finish(String id, bool ok, String reason, {String source = 'agent'}) {
    final p = _pending.remove(id);
    if (p == null) return;
    p.timer?.cancel();
    audit.record('approval.$reason', actor: source, fields: {'task': p.view.taskId, 'request': id, 'kind': p.view.action});
    _emit('approval.resolved', {'id': id, 'approved': ok, 'reason': reason, 'source': source});
    if (!p.done.isCompleted) p.done.complete(ok);
  }

  /// Denies everything still waiting (agent shutting down).
  void denyAll(String reason) {
    for (final id in _pending.keys.toList()) {
      _finish(id, false, reason);
    }
  }
}
