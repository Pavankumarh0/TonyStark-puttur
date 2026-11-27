import 'dart:io';

import 'package:path/path.dart' as p;

import '../git/git.dart';
import '../proc.dart';

/// A context report from a client: the VS Code extension or `leo here` in a terminal.
class ContextReport {
  final String source; // vscode | cli
  final List<String> workspaceFolders;
  final String? activeFile;
  final String? terminalCwd;
  final String? cwd;
  final bool focused;
  final DateTime at;
  ContextReport(this.source,
      {this.workspaceFolders = const [], this.activeFile, this.terminalCwd, this.cwd, this.focused = false, DateTime? at})
      : at = at ?? DateTime.now();
}

class Candidate {
  final String root;
  int score;
  final List<String> why;
  Candidate(this.root, this.score, this.why);
  String get name => p.basename(root);
  Map<String, Object?> toJson() => {'root': root, 'name': name, 'score': score, 'why': why};
}

class Detection {
  final String? root; // null = none or ambiguous
  final bool ambiguous;
  final List<Candidate> candidates;
  const Detection(this.root, this.ambiguous, this.candidates);
  Map<String, Object?> toJson() =>
      {'root': root, 'ambiguous': ambiguous, 'candidates': [for (final c in candidates) c.toJson()]};
}

/// Finds the project the user is working on. It never trusts a single weak signal: the VS Code
/// window title is only a hint. When the signals point at different repositories, it reports the
/// result as ambiguous so the user is asked.
class ProjectDetector {
  final Git git;
  final List<String> roots; // configured project folders (scanned one level deep)
  final Duration fresh;
  final _reports = <String, ContextReport>{};
  String? _selected;
  DateTime? _selectedAt;
  List<String>? _known;
  DateTime? _knownAt;

  ProjectDetector(this.git, {required this.roots, this.fresh = const Duration(minutes: 15)});

  static List<String> defaultRoots() {
    final home = Platform.environment['USERPROFILE'] ?? '';
    return [p.join(home, 'Documents', 'projects')];
  }

  void report(ContextReport r) => _reports[r.source] = r;

  /// The user picked a project explicitly — strongest signal until they pick another.
  Future<String> select(String pathOrName) async {
    final root = await resolve(pathOrName);
    if (root == null) throw GitError('Not a known git repository: $pathOrName');
    _selected = root;
    _selectedAt = DateTime.now();
    return root;
  }

  /// Git repositories under the configured folders (cached for a minute).
  Future<List<String>> knownRepos() async {
    if (_known != null && DateTime.now().difference(_knownAt!) < const Duration(minutes: 1)) return _known!;
    final out = <String>[];
    for (final r in roots) {
      final d = Directory(r);
      if (!d.existsSync()) continue;
      for (final e in d.listSync().whereType<Directory>()) {
        if (Directory(p.join(e.path, '.git')).existsSync() || File(p.join(e.path, '.git')).existsSync()) {
          out.add(canonicalPath(e.path));
        }
      }
    }
    out.sort((a, b) => p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
    _known = out;
    _knownAt = DateTime.now();
    return out;
  }

  /// Accepts a repository path or a project name ("nocom", "Kadamly"). Returns its git root only
  /// if it is a known repository or one a client reported — never an arbitrary folder.
  Future<String?> resolve(String pathOrName) async {
    final known = await knownRepos();
    final lower = pathOrName.toLowerCase().trim();
    for (final k in known) {
      if (p.basename(k).toLowerCase() == lower) return k;
    }
    final reported = <String>{
      for (final r in _reports.values) ...[...r.workspaceFolders, if (r.cwd != null) r.cwd!, if (r.terminalCwd != null) r.terminalCwd!]
    };
    final root = await git.rootOf(pathOrName);
    if (root == null) return null;
    final norm = canonicalPath(root).toLowerCase();
    final allowed = known.any((k) => k.toLowerCase() == norm) ||
        (await Future.wait(reported.map(git.rootOf))).whereType<String>().any((r) => canonicalPath(r).toLowerCase() == norm);
    return allowed ? canonicalPath(root) : null;
  }

  Future<Detection> detect() async {
    final now = DateTime.now();
    final cands = <String, Candidate>{};
    Future<void> add(String? dir, int score, String why) async {
      if (dir == null || dir.isEmpty) return;
      final root = await git.rootOf(dir);
      if (root == null) return;
      final key = p.normalize(root).toLowerCase();
      final c = cands.putIfAbsent(key, () => Candidate(p.normalize(root), 0, []));
      c.score += score;
      c.why.add(why);
    }

    if (_selected != null && now.difference(_selectedAt!) < const Duration(hours: 8)) await add(_selected, 6, 'selected by you');
    final vs = _reports['vscode'];
    if (vs != null && now.difference(vs.at) < fresh) {
      if (vs.activeFile != null) await add(p.dirname(vs.activeFile!), vs.focused ? 4 : 3, 'file open in VS Code');
      if (vs.terminalCwd != null) await add(vs.terminalCwd, 2, 'VS Code terminal folder');
      if (vs.workspaceFolders.length == 1) await add(vs.workspaceFolders.single, 2, 'VS Code workspace');
    }
    final cli = _reports['cli'];
    if (cli != null && now.difference(cli.at) < fresh) await add(cli.cwd, 4, '"leo here" in a terminal');
    for (final t in await _vsCodeTitles()) {
      for (final k in await knownRepos()) {
        if (t.contains(' - ${p.basename(k)} - ') || t.endsWith(' - ${p.basename(k)}')) await add(k, 1, 'VS Code window title (hint)');
      }
    }

    final list = cands.values.toList()..sort((a, b) => b.score.compareTo(a.score));
    if (list.isEmpty) return Detection(null, false, list);
    final top = list.first;
    final tie = list.length > 1 && list[1].score == top.score;
    if (top.score < 2 || tie) return Detection(null, true, list); // only hints, or disagreement → ask
    return Detection(top.root, false, list);
  }

  /// Visible VS Code window titles ("file - folder - Visual Studio Code"). Hints only.
  Future<List<String>> _vsCodeTitles() async {
    if (!Platform.isWindows) return const [];
    final r = await runProc('tasklist', ['/v', '/fo', 'csv', '/nh', '/fi', 'imagename eq Code.exe'],
        timeout: const Duration(seconds: 8));
    if (!r.ok) return const [];
    return [
      for (final l in r.out.split('\n'))
        if (l.contains('Visual Studio Code'))
          RegExp(r'"([^"]*)"\s*$').firstMatch(l.trim())?.group(1) ?? ''
    ].where((t) => t.isNotEmpty).toList();
  }

  /// Everything the UI / TFT shows about a project.
  Future<Map<String, Object?>> info(String root) async {
    final st = await git.status(root);
    final last = await git.log(root, n: 1);
    return {
      'name': p.basename(root),
      'root': root,
      'remote': await git.remoteUrl(root),
      ...st.toJson(),
      'latestCommit': last.isEmpty ? null : last.first.toJson(),
    };
  }
}
