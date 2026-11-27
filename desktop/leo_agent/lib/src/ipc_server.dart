import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// One connected local client (desktop UI, VS Code extension, …).
class IpcClient {
  final WebSocket socket;
  final String remote;
  String name = 'unknown';
  IpcClient(this.socket, this.remote);

  /// Returns false when the client is gone (closing sockets must never crash the agent).
  bool send(Map<String, Object?> m) {
    if (socket.readyState != WebSocket.open) return false;
    try {
      socket.add(jsonEncode(m));
      return true;
    } on StateError {
      return false;
    }
  }
}

class RpcError implements Exception {
  final String code;
  final String message;
  RpcError(this.code, [this.message = '']);
}

typedef RpcHandler = FutureOr<Object?> Function(IpcClient client, Map<String, Object?> params);

/// Local JSON-RPC over WebSocket.
///
/// Security: binds to 127.0.0.1 only (not reachable from the network); every connection must present
/// the per-session bearer token (random 256-bit, rewritten at each start into the user-only
/// discovery file); requests carrying an `Origin` header are refused, so a web page in a browser
/// cannot talk to the agent even though it is on localhost; only registered methods exist.
class IpcServer {
  final String token;
  final Map<String, RpcHandler> _methods = {};
  final List<IpcClient> clients = [];
  HttpServer? _server;
  void Function(String event, Map<String, Object?> fields)? onSecurityEvent;

  IpcServer({String? token}) : token = token ?? _newToken();

  static String _newToken() {
    final r = Random.secure();
    return base64Url.encode(List.generate(32, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  int get port => _server?.port ?? 0;

  void method(String name, RpcHandler h) => _methods[name] = h;

  static bool _sameToken(String a, String b) {
    // Constant-time comparison.
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return d == 0;
  }

  Future<void> start({int port = 0}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_onRequest);
  }

  Future<void> _onRequest(HttpRequest req) async {
    final remote = req.connectionInfo?.remoteAddress.address ?? '?';
    if (req.headers.value('origin') != null) {
      onSecurityEvent?.call('ipc.refused', {'reason': 'browser_origin'});
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (!auth.startsWith('Bearer ') || !_sameToken(auth.substring(7), token)) {
      onSecurityEvent?.call('ipc.refused', {'reason': 'bad_token'});
      req.response.statusCode = HttpStatus.unauthorized;
      await req.response.close();
      return;
    }
    if (req.uri.path != '/ws' || !WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    final c = IpcClient(ws, remote);
    clients.add(c);
    ws.listen((data) => _onMessage(c, data), onDone: () => clients.remove(c), onError: (_) => clients.remove(c));
  }

  Future<void> _onMessage(IpcClient c, dynamic data) async {
    Object? id;
    try {
      if (data is! String || data.length > 64 * 1024) throw RpcError('bad_request', 'text frames up to 64 KB');
      final m = jsonDecode(data);
      if (m is! Map) throw RpcError('bad_request');
      id = m['id'];
      final name = m['method'];
      final params = m['params'] is Map ? Map<String, Object?>.from(m['params'] as Map) : <String, Object?>{};
      final h = name is String ? _methods[name] : null;
      if (h == null) throw RpcError('unknown_method', '$name');
      final result = await h(c, params);
      c.send({'id': id, 'result': result});
    } on RpcError catch (e) {
      c.send({'id': id, 'error': {'code': e.code, 'message': e.message}});
    } on FormatException {
      c.send({'id': id, 'error': {'code': 'bad_json', 'message': ''}});
    } catch (e) {
      c.send({'id': id, 'error': {'code': 'internal', 'message': e.runtimeType.toString()}});
    }
  }

  void broadcast(String event, Object? data) {
    for (final c in List.of(clients)) {
      if (!c.send({'event': event, 'data': data})) clients.remove(c);
    }
  }

  Future<void> close() async {
    for (final c in List.of(clients)) {
      await c.socket.close();
    }
    await _server?.close(force: true);
  }
}
