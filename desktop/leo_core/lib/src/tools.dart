// Shared with the LEO Android app (copied from lib/agent/tools.dart). Keep in sync until Android adopts leo_core.
/// Tool abstraction for LEO's model-driven agents (pattern adapted from Sanna's tool registry, MIT).
///
/// A tool has a name, a description and a JSON-schema for its arguments; the model picks tools, LEO
/// executes them on the phone and feeds the result back. Results distinguish what the MODEL sees
/// ([forModel]) from what the USER should hear ([forUser]).
library;

class ToolResult {
  final String forModel;
  final String? forUser;
  final bool isError;

  /// Set by tools that end the run (finish_task, user declined …).
  final bool stop;
  const ToolResult(this.forModel, {this.forUser, this.isError = false, this.stop = false});

  factory ToolResult.error(String msg) => ToolResult('ERROR: $msg', isError: true);
}

abstract class AgentTool {
  String get name;
  String get description;
  Map<String, dynamic> get parameters;
  Future<ToolResult> execute(Map<String, dynamic> args);

  Map<String, dynamic> toOpenAi() => {
        'type': 'function',
        'function': {'name': name, 'description': description, 'parameters': parameters},
      };
}

class ToolRegistry {
  final _tools = <String, AgentTool>{};
  void register(AgentTool t) => _tools[t.name] = t;
  List<Map<String, dynamic>> definitions() => [for (final t in _tools.values) t.toOpenAi()];

  Future<ToolResult> execute(String name, Map<String, dynamic> args) async {
    final t = _tools[name];
    if (t == null) return ToolResult.error('Unknown tool "$name". Available: ${_tools.keys.join(', ')}');
    try {
      return await t.execute(args);
    } catch (e) {
      return ToolResult.error('$e');
    }
  }
}
