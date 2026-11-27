import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../proc.dart';

/// Canonical form of a folder path: Windows short names (PAVANK~1) and links resolved to the real
/// long path, so the same folder always compares equal.
String canonicalPath(String path) {
  try {
    return p.normalize(Directory(path).resolveSymbolicLinksSync());
  } catch (_) {
    return p.normalize(path);
  }
}

bool samePath(String a, String b) => canonicalPath(a).toLowerCase() == canonicalPath(b).toLowerCase();

class GitError implements Exception {
  final String message;
  GitError(this.message);
  @override
  String toString() => message;
}

/// One changed path from `git status`.
class GitFile {
  final String path;
  final String index; // X: staged state
  final String worktree; // Y: working-tree state
  final String kind; // modified | added | deleted | renamed | untracked | conflict
  final String? from; // rename source
  const GitFile(this.path, this.index, this.worktree, this.kind, {this.from});

  bool get untracked => kind == 'untracked';
  bool get conflict => kind == 'conflict';
  Map<String, Object?> toJson() => {'path': path, 'index': index, 'worktree': worktree, 'kind': kind, 'from': from};
}

class GitStatus {
  final String root;
  final String? branch; // null = detached
  final String? head; // commit sha, null = no commits yet
  final String? upstream;
  final int ahead, behind;
  final List<GitFile> files;
  const GitStatus(this.root, this.branch, this.head, this.upstream, this.ahead, this.behind, this.files);

  Iterable<GitFile> get modified => files.where((f) => !f.untracked && !f.conflict);
  Iterable<GitFile> get untracked => files.where((f) => f.untracked);
  Iterable<GitFile> get conflicts => files.where((f) => f.conflict);

  Map<String, Object?> toJson() => {
        'root': root,
        'branch': branch,
        'head': head,
        'upstream': upstream,
        'ahead': ahead,
        'behind': behind,
        'files': [for (final f in files) f.toJson()],
        'modifiedCount': modified.length,
        'untrackedCount': untracked.length,
        'conflictCount': conflicts.length,
      };
}

class GitCommitInfo {
  final String hash, author, date, subject;
  const GitCommitInfo(this.hash, this.author, this.date, this.subject);
  Map<String, Object?> toJson() => {'hash': hash, 'author': author, 'date': date, 'subject': subject};
}

/// Safe Git integration: the git CLI with argument lists only, no prompts, no force options.
/// Destructive operations (force push, reset --hard, clean, branch -D) are deliberately absent.
class Git {
  final String exe;
  Git({this.exe = 'git'});

  static const _env = {
    'GIT_TERMINAL_PROMPT': '0', // never hang waiting for a password
    'GIT_OPTIONAL_LOCKS': '0', // `status` must not write to the index (safe on repos the user is editing)
    'LC_ALL': 'C',
  };

  Future<ProcResult> _git(String repo, List<String> args, {Duration timeout = const Duration(seconds: 60)}) =>
      runProc(exe, ['-c', 'core.quotepath=off', '-c', 'color.ui=false', ...args], cwd: repo, env: _env, timeout: timeout);

  Future<String> _ok(String repo, List<String> args, {Duration timeout = const Duration(seconds: 60)}) async {
    final r = await _git(repo, args, timeout: timeout);
    if (!r.ok) throw GitError(r.timedOut ? 'git ${args.first} timed out' : (r.err.trim().isEmpty ? 'git ${args.first} failed' : r.err.trim()));
    return r.out;
  }

  /// Top-level folder of the repository containing [dir], or null if it isn't in one.
  Future<String?> rootOf(String dir) async {
    if (!Directory(dir).existsSync()) return null;
    final r = await _git(dir, ['rev-parse', '--show-toplevel'], timeout: const Duration(seconds: 10));
    if (!r.ok) return null;
    return canonicalPath(r.out.trim().replaceAll('/', Platform.pathSeparator));
  }

  Future<GitStatus> status(String repo) async {
    final out = await _ok(repo, ['status', '--porcelain=v2', '-z', '--branch', '--untracked-files=all']);
    String? branch, head, upstream;
    var ahead = 0, behind = 0;
    final files = <GitFile>[];
    final parts = out.split('\x00');
    for (var i = 0; i < parts.length; i++) {
      final e = parts[i];
      if (e.isEmpty) continue;
      if (e.startsWith('# branch.oid ')) {
        final v = e.substring(13);
        head = v == '(initial)' ? null : v;
      } else if (e.startsWith('# branch.head ')) {
        final v = e.substring(14);
        branch = v == '(detached)' ? null : v;
      } else if (e.startsWith('# branch.upstream ')) {
        upstream = e.substring(18);
      } else if (e.startsWith('# branch.ab ')) {
        final m = RegExp(r'\+(\d+) -(\d+)').firstMatch(e);
        if (m != null) {
          ahead = int.parse(m.group(1)!);
          behind = int.parse(m.group(2)!);
        }
      } else if (e.startsWith('1 ')) {
        final f = e.split(' ');
        final xy = f[1];
        files.add(GitFile(f.sublist(8).join(' '), xy[0], xy[1], _kind(xy)));
      } else if (e.startsWith('2 ')) {
        final f = e.split(' ');
        final xy = f[1];
        final from = i + 1 < parts.length ? parts[++i] : null; // rename source follows as its own entry
        files.add(GitFile(f.sublist(9).join(' '), xy[0], xy[1], 'renamed', from: from));
      } else if (e.startsWith('u ')) {
        final f = e.split(' ');
        files.add(GitFile(f.sublist(10).join(' '), f[1][0], f[1][1], 'conflict'));
      } else if (e.startsWith('? ')) {
        files.add(GitFile(e.substring(2), '?', '?', 'untracked'));
      }
    }
    return GitStatus(repo, branch, head, upstream, ahead, behind, files);
  }

  static String _kind(String xy) {
    if (xy.contains('D')) return 'deleted';
    if (xy[0] == 'A') return 'added';
    if (xy.contains('R')) return 'renamed';
    return 'modified';
  }

  /// Changes of one file against HEAD (staged + unstaged). Untracked files are shown as all-new.
  Future<String> diff(String repo, String file, {int maxBytes = 200 * 1024}) async {
    final st = await status(repo);
    final f = st.files.where((x) => x.path == file).firstOrNull;
    if (f == null) return '';
    String text;
    if (f.untracked) {
      final abs = File(p.join(repo, file));
      if (!abs.existsSync()) return '';
      if (abs.lengthSync() > maxBytes) return '(new file, ${abs.lengthSync()} bytes — too large to show)';
      final bytes = abs.readAsBytesSync();
      if (bytes.contains(0)) return '(new binary file, ${bytes.length} bytes)';
      text = 'new file: $file\n${utf8.decode(bytes, allowMalformed: true).split('\n').map((l) => '+$l').join('\n')}';
    } else {
      final args = st.head == null
          ? ['diff', '--cached', '--no-ext-diff', '--', file]
          : ['diff', 'HEAD', '--no-ext-diff', '--find-renames', '--', file];
      text = await _ok(repo, args);
    }
    return text.length > maxBytes ? '${text.substring(0, maxBytes)}\n… (truncated)' : text;
  }

  Future<String> diffStat(String repo, List<String> files) async {
    final st = await status(repo);
    if (st.head == null) return files.join('\n');
    final tracked = files.where((f) => st.files.any((x) => x.path == f && !x.untracked)).toList();
    final untracked = files.where((f) => st.files.any((x) => x.path == f && x.untracked)).toList();
    final stat = tracked.isEmpty ? '' : await _ok(repo, ['diff', 'HEAD', '--stat', '--', ...tracked]);
    return [stat.trim(), for (final u in untracked) ' $u (new file)'].where((s) => s.isNotEmpty).join('\n');
  }

  Future<List<GitCommitInfo>> log(String repo, {int n = 10, String? range}) async {
    final r = await _git(repo, ['log', '--max-count=$n', '--format=%H%x1f%an%x1f%aI%x1f%s', if (range != null) range]);
    if (!r.ok) return const []; // e.g. no commits yet
    return [
      for (final l in r.out.split('\n').where((l) => l.trim().isNotEmpty))
        () {
          final f = l.split('\x1f');
          return GitCommitInfo(f[0], f[1], f[2], f.length > 3 ? f[3] : '');
        }()
    ];
  }

  Future<String?> remoteUrl(String repo, [String remote = 'origin']) async {
    final r = await _git(repo, ['remote', 'get-url', remote], timeout: const Duration(seconds: 10));
    return r.ok ? _stripCredentials(r.out.trim()) : null;
  }

  /// Never show credentials embedded in a remote URL (https://user:token@host/…).
  static String _stripCredentials(String url) => url.replaceFirst(RegExp(r'//[^/@]+@'), '//');

  Future<List<String>> remotes(String repo) async =>
      (await _ok(repo, ['remote'])).split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  Future<List<String>> branches(String repo) async => (await _ok(repo, ['branch', '--format=%(refname:short)']))
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<bool> validBranchName(String name) async =>
      (await runProc(exe, ['check-ref-format', '--branch', name], env: _env)).ok && !name.startsWith('-');

  // ---- write operations (each called only after an approval for exactly these arguments) ----

  /// Stages exactly [files] and commits ONLY those paths (`git commit -- <paths>`), even if other
  /// files were already staged. Returns the new commit hash.
  Future<String> commitOnly(String repo, List<String> files, String message) async {
    if (files.isEmpty) throw GitError('no files selected');
    final present = files.where((f) => File(p.join(repo, f)).existsSync()).toList();
    final missing = files.where((f) => !present.contains(f)).toList();
    if (present.isNotEmpty) await _ok(repo, ['add', '--', ...present]);
    // Deleted / renamed-away paths: stage the deletion only (the files are already gone from disk).
    if (missing.isNotEmpty) await _ok(repo, ['rm', '--cached', '--quiet', '--ignore-unmatch', '--', ...missing]);
    // The repository's own hooks (pre-commit, commit-msg) run as usual — LEO never skips them.
    await _ok(repo, ['commit', '-m', message, '--', ...files], timeout: const Duration(minutes: 3));
    return (await _ok(repo, ['rev-parse', 'HEAD'])).trim();
  }

  /// Files in commit [hash] (for verification).
  Future<List<String>> filesIn(String repo, String hash) async =>
      (await _ok(repo, ['show', '--name-only', '--format=', '--no-renames', hash]))
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

  Future<String> subjectOf(String repo, String hash) async => (await _ok(repo, ['log', '-1', '--format=%B', hash])).trim();

  Future<void> push(String repo, String remote, String branch, {bool setUpstream = false}) async {
    await _ok(repo, ['push', if (setUpstream) '--set-upstream', remote, 'refs/heads/$branch:refs/heads/$branch'],
        timeout: const Duration(minutes: 3));
  }

  /// The commit the remote currently has for [branch] (asks the remote itself, not the local cache).
  Future<String?> remoteHead(String repo, String remote, String branch) async {
    final out = await _ok(repo, ['ls-remote', remote, 'refs/heads/$branch'], timeout: const Duration(minutes: 1));
    final line = out.trim().split('\n').first;
    return line.isEmpty ? null : line.split(RegExp(r'\s+')).first;
  }

  Future<void> fetch(String repo, String remote) async => _ok(repo, ['fetch', remote], timeout: const Duration(minutes: 3));

  /// Fast-forward only: never creates merge commits or rewrites anything.
  Future<String> pullFastForward(String repo) async => _ok(repo, ['pull', '--ff-only'], timeout: const Duration(minutes: 3));

  Future<void> createBranch(String repo, String name) async => _ok(repo, ['switch', '-c', name]);
}
