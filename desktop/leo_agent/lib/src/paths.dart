import 'dart:io';

import 'package:path/path.dart' as p;

/// Where the agent keeps its files. Everything lives under the user's own profile
/// (%LOCALAPPDATA%\LEO), which other Windows users cannot read.
class LeoPaths {
  final String root;
  LeoPaths(this.root);

  factory LeoPaths.forUser() {
    final base = Platform.environment['LOCALAPPDATA'] ?? p.join(Platform.environment['USERPROFILE'] ?? '.', 'AppData', 'Local');
    return LeoPaths(p.join(base, 'LEO'));
  }

  /// Port + session token for local clients (UI, VS Code extension). Rewritten at every start.
  String get discoveryFile => p.join(root, 'agent.json');
  String get lockFile => p.join(root, 'agent.lock');
  String get auditDir => p.join(root, 'audit');
  String get workDir => p.join(root, 'work');

  void ensure() {
    for (final d in [root, auditDir, workDir]) {
      Directory(d).createSync(recursive: true);
    }
  }
}
