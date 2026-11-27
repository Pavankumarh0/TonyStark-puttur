import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum Link { connecting, connected, noAgent, error }

/// The desktop UI's connection to the LEO agent service. The UI holds no authority of its own:
/// every action is a request the agent validates, executes and audits.
class AgentClient extends ChangeNotifier {
  Link link = Link.connecting;
  String? error;
  int? port;
  String? agentVersion;
  final Map<int, Map<String, dynamic>> tasks = {};
  final Map<String, Map<String, dynamic>> approvals = {};
  final List<Map<String, dynamic>> audit = [];
  List<String> kinds = const [];

  WebSocket? _ws;
  int _id = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  Timer? _retry;
  bool _disposed = false;

  static String get _base => '${Platform.environment['LOCALAPPDATA']}\\LEO';
  static String get discoveryFile => '$_base\\agent.json';

  void start() => _connect();

  Future<void> _connect() async {
    _retry?.cancel();
    if (_disposed) return;
    final f = File(discoveryFile);
    if (!f.existsSync()) {
      _setLink(Link.noAgent);
      _scheduleRetry();
      return;
    }
    try {
      final d = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _setLink(Link.connecting);
      final ws = await WebSocket.connect('ws://127.0.0.1:${d['port']}/ws',
              headers: {'Authorization': 'Bearer ${d['token']}'})
          .timeout(const Duration(seconds: 3));
      _ws = ws;
      port = d['port'] as int;
      ws.listen(_onData, onDone: _onClosed, onError: (_) => _onClosed());
      final hello = await call('hello', {'client': 'desktop-ui'});
      final r = hello['result'] as Map<String, dynamic>;
      agentVersion = r['version'] as String?;
      kinds = (r['kinds'] as List).cast<String>();
      tasks
        ..clear()
        ..addEntries([for (final t in r['tasks'] as List) MapEntry(t['id'] as int, Map<String, dynamic>.from(t as Map))]);
      approvals
        ..clear()
        ..addEntries([for (final a in r['approvals'] as List) MapEntry(a['id'] as String, Map<String, dynamic>.from(a as Map))]);
      final tail = await call('audit.tail', {'n': 100});
      audit
        ..clear()
        ..addAll([for (final e in tail['result'] as List) Map<String, dynamic>.from(e as Map)]);
      error = null;
      _setLink(Link.connected);
    } catch (e) {
      // Discovery file left behind by a crashed agent, or agent still starting.
      error = e is SocketException || e is TimeoutException ? null : '$e';
      _setLink(Link.noAgent);
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _retry?.cancel();
    if (!_disposed) _retry = Timer(const Duration(seconds: 2), _connect);
  }

  void _onClosed() {
    _ws = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('disconnected'));
    }
    _pending.clear();
    _setLink(Link.noAgent);
    _scheduleRetry();
  }

  void _setLink(Link l) {
    link = l;
    if (!_disposed) notifyListeners();
  }

  void _onData(dynamic data) {
    final m = jsonDecode(data as String) as Map<String, dynamic>;
    final ev = m['event'];
    if (ev == null) {
      _pending.remove(m['id'])?.complete(m);
      return;
    }
    final d = m['data'];
    switch (ev) {
      case 'task':
        final t = Map<String, dynamic>.from(d as Map);
        tasks[t['id'] as int] = t;
      case 'approval.pending':
        final a = Map<String, dynamic>.from(d as Map);
        approvals[a['id'] as String] = a;
      case 'approval.resolved':
        approvals.remove((d as Map)['id']);
      case 'audit':
        audit.add(Map<String, dynamic>.from(d as Map));
        if (audit.length > 300) audit.removeRange(0, audit.length - 300);
    }
    notifyListeners();
  }

  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> params = const {}]) {
    final ws = _ws;
    if (ws == null) return Future.error(StateError('not connected'));
    final id = ++_id;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    ws.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return c.future.timeout(const Duration(seconds: 10));
  }

  /// Calls [method]; returns an error code, or null on success.
  Future<String?> act(String method, [Map<String, Object?> params = const {}]) async {
    try {
      final r = await call(method, params);
      final e = r['error'];
      return e == null ? null : '${(e as Map)['code']}';
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> approve(Map<String, dynamic> a, bool yes) =>
      act('approval.respond', {'id': a['id'], 'fingerprint': a['fingerprint'], 'approve': yes});

  /// Finds and launches the agent executable (detached, so it keeps running if the UI closes).
  Future<String?> startAgent() async {
    final exe = _findAgentExe();
    if (exe == null) return 'leo_agent.exe not found (set LEO_AGENT_EXE)';
    await Process.start(exe, const [], mode: ProcessStartMode.detached);
    _setLink(Link.connecting);
    _retry?.cancel();
    _retry = Timer(const Duration(milliseconds: 800), _connect);
    return null;
  }

  static String? _findAgentExe() {
    final env = Platform.environment['LEO_AGENT_EXE'];
    if (env != null && File(env).existsSync()) return env;
    for (final start in [File(Platform.resolvedExecutable).parent, Directory.current]) {
      var d = start;
      for (var i = 0; i < 8; i++) {
        for (final rel in ['leo_agent.exe', 'leo_agent\\build\\leo_agent.exe', 'desktop\\leo_agent\\build\\leo_agent.exe']) {
          final f = File('${d.path}\\$rel');
          if (f.existsSync()) return f.path;
        }
        if (d.parent.path == d.path) break;
        d = d.parent;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _ws?.close();
    super.dispose();
  }
}
