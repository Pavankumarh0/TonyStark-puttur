import 'dart:convert';

/// A sensitive action JARVIS wants to perform, described exactly as it will be executed.
class ApprovalRequest {
  final String id;
  final String actionType; // e.g. "whatsapp.send", "memory.delete_all"
  final String title; // human-readable summary
  final String? recipientId; // stable id: phone number / "group:<name>" / null
  final String? recipientLabel;
  final String? content; // exact text that will be sent / affected
  final String? appLabel;
  final DateTime createdAt;

  ApprovalRequest({
    required this.id,
    required this.actionType,
    required this.title,
    this.recipientId,
    this.recipientLabel,
    this.content,
    this.appLabel,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Approval is bound to this exact fingerprint (action + recipient + content).
  String get fingerprint => ApprovalGate.fingerprintOf(actionType, recipientId, content);
}

enum ApprovalStatus { pending, approved, rejected, invalidated, consumed }

class ApprovalDecision {
  final ApprovalRequest request;
  final ApprovalStatus status;
  final String fingerprint;
  const ApprovalDecision(this.request, this.status, this.fingerprint);
}

/// Reusable approval mechanism. Executors must call [consume] with the fingerprint of what they
/// are about to do; it only succeeds if that exact action was approved and not yet used.
class ApprovalGate {
  ApprovalDecision? _current;

  ApprovalDecision? get current => _current;
  ApprovalRequest? get pending =>
      _current?.status == ApprovalStatus.pending ? _current!.request : null;

  static String fingerprintOf(String action, String? recipientId, String? content) {
    // Deterministic, collision-resistant enough for local binding (FNV-1a 64 over canonical JSON).
    final canonical = jsonEncode([action, recipientId ?? '', content ?? '']);
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(canonical)) {
      h ^= b;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return '${h.toRadixString(16)}:${canonical.length}';
  }

  /// Registers a new request; any previous approval (pending or granted) becomes invalid.
  void request(ApprovalRequest r) {
    _current = ApprovalDecision(r, ApprovalStatus.pending, r.fingerprint);
  }

  void approve() {
    final c = _current;
    if (c == null || c.status != ApprovalStatus.pending) {
      throw StateError('Nothing is waiting for approval');
    }
    _current = ApprovalDecision(c.request, ApprovalStatus.approved, c.fingerprint);
  }

  void reject() {
    final c = _current;
    if (c == null) return;
    _current = ApprovalDecision(c.request, ApprovalStatus.rejected, c.fingerprint);
  }

  void invalidate() {
    final c = _current;
    if (c == null) return;
    if (c.status == ApprovalStatus.pending || c.status == ApprovalStatus.approved) {
      _current = ApprovalDecision(c.request, ApprovalStatus.invalidated, c.fingerprint);
    }
  }

  /// Checks that [action]/[recipientId]/[content] match an approved request and marks it used.
  /// Returns false if anything differs, it was never approved, or it was already used.
  bool consume(String action, String? recipientId, String? content) {
    final c = _current;
    if (c == null || c.status != ApprovalStatus.approved) return false;
    if (fingerprintOf(action, recipientId, content) != c.fingerprint) {
      invalidate();
      return false;
    }
    _current = ApprovalDecision(c.request, ApprovalStatus.consumed, c.fingerprint);
    return true;
  }

  bool isApproved(String action, String? recipientId, String? content) {
    final c = _current;
    return c != null &&
        c.status == ApprovalStatus.approved &&
        fingerprintOf(action, recipientId, content) == c.fingerprint;
  }

  void clear() => _current = null;
}
