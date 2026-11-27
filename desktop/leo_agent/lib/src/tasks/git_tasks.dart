import 'package:leo_core/leo_core.dart';
import 'package:path/path.dart' as p;

import '../ai/qwen.dart';
import '../approval_manager.dart';
import '../git/git.dart';
import '../git/secret_scan.dart';
import '../task_engine.dart';

String _short(String h) => h.length > 8 ? h.substring(0, 8) : h;

/// COMMIT: status → secret check → message → approval (exact files + message) → stage + commit
/// only those files → verify hash, files and message.
class GitCommitTask extends TaskDefinition {
  final Git git;
  final CommitMessageWriter writer;
  final String repo;
  final List<String> files;
  final String? message;
  GitCommitTask(this.git, this.writer, {required this.repo, required this.files, this.message});

  @override
  String get kind => 'git.commit';
  @override
  String get title => 'Commit to ${p.basename(repo)}';

  @override
  List<TaskStep> plan() => const [
        TaskStep(id: 'status', description: 'Read Git status'),
        TaskStep(id: 'secrets', description: 'Check the selected files for secrets'),
        TaskStep(id: 'message', description: 'Prepare the commit message'),
        TaskStep(id: 'approve', description: 'Ask your approval'),
        TaskStep(id: 'commit', description: 'Stage only the selected files and commit'),
        TaskStep(id: 'verify', description: 'Verify the new commit'),
      ];

  @override
  Future<String> run(TaskContext c) async {
    late GitStatus st;
    late List<String> selected;
    await c.step('status', () async {
      st = await git.status(repo);
      if (st.conflicts.isNotEmpty) throw GitError('Resolve the merge conflicts first (${st.conflicts.length} files).');
      if (st.branch == null) throw GitError('HEAD is detached — check out a branch first.');
      final changed = {for (final f in st.files) f.path};
      final unknown = files.where((f) => !changed.contains(f)).toList();
      if (unknown.isNotEmpty) throw GitError('Not changed in this repo: ${unknown.take(3).join(', ')}');
      selected = files.toSet().toList()..sort();
      c.detail('status', '${st.branch} · ${selected.length} selected of ${st.files.length} changed');
    });

    var excluded = <SecretFinding>[];
    await c.step('secrets', () async {
      excluded = await SecretScanner(git).scan(repo, selected);
      final bad = {for (final e in excluded) e.file};
      selected = selected.where((f) => !bad.contains(f)).toList();
      c.detail('secrets', excluded.isEmpty ? 'None found' : 'Excluded ${excluded.length}: ${excluded.map((e) => e.file).join(', ')}');
      if (selected.isEmpty) throw Declined('Nothing left to commit: every selected file looks like it contains a secret.');
    });

    // A rename is committed with its source path, or the deletion would be left behind.
    final paths = {
      ...selected,
      for (final f in st.files)
        if (selected.contains(f.path) && f.from != null) f.from!
    }.toList()
      ..sort();

    late String msg;
    await c.step('message', () async {
      if (message != null && message!.trim().isNotEmpty) {
        msg = message!.trim();
        c.detail('message', 'Yours');
      } else {
        final (m, source) = await c.guard(writer.write(
            stat: await git.diffStat(repo, selected),
            diff: (await Future.wait(selected.take(12).map((f) => git.diff(repo, f, maxBytes: 4000)))).join('\n'),
            files: selected));
        msg = m;
        c.detail('message', source == 'qwen' ? 'Written by Qwen (local)' : 'Qwen unavailable — simple message');
      }
    });

    final params = <String, Object?>{
      'repo': repo,
      'branch': st.branch,
      'files': paths,
      'message': msg,
      'excluded': [for (final e in excluded) '${e.file} (${e.reason})'],
    };
    late ApprovalTicket ticket;
    await c.step('approve', () async {
      ticket = await c.approve(
          action: 'git.commit', title: 'Commit ${paths.length} file(s) to ${p.basename(repo)}', risk: Risk.writeLocal, target: repo, params: params);
      if (!ticket.approved) throw Declined('You declined — nothing was committed.');
    }, doneDetail: 'Approved');

    late String hash;
    await c.step('commit', () async {
      if (!ticket.consume(repo, params)) throw StateError('approval does not match this commit');
      hash = await git.commitOnly(repo, paths, msg);
    });

    await c.step('verify', () async {
      final head = (await git.log(repo, n: 1)).first.hash;
      if (head != hash) throw GitError('HEAD is ${_short(head)}, expected ${_short(hash)}');
      final inCommit = (await git.filesIn(repo, hash)).toSet();
      if (inCommit.length != paths.length || !paths.every(inCommit.contains)) {
        throw GitError('Commit contains ${inCommit.length} files, expected exactly ${paths.length}');
      }
      if (await git.subjectOf(repo, hash) != msg) throw GitError('Commit message differs from the approved one');
    }, doneDetail: _short(hash));

    return 'Committed ${_short(hash)} on ${st.branch}: "${msg.split('\n').first}" (${paths.length} file${paths.length == 1 ? '' : 's'})'
        '${excluded.isEmpty ? '' : ' — excluded ${excluded.length} with secrets'}';
  }
}

/// PUSH: branch + remote → outgoing commits → approval → push → ask the remote for its head.
class GitPushTask extends TaskDefinition {
  final Git git;
  final String repo;
  GitPushTask(this.git, {required this.repo});

  @override
  String get kind => 'git.push';
  @override
  String get title => 'Push ${p.basename(repo)}';

  @override
  List<TaskStep> plan() => const [
        TaskStep(id: 'check', description: 'Check branch, remote and outgoing commits'),
        TaskStep(id: 'approve', description: 'Ask your approval'),
        TaskStep(id: 'push', description: 'Push'),
        TaskStep(id: 'verify', description: 'Verify the remote has the new commit'),
      ];

  @override
  Future<String> run(TaskContext c) async {
    late GitStatus st;
    late String remote, branch, head;
    late bool setUpstream;
    late List<GitCommitInfo> outgoing;
    await c.step('check', () async {
      st = await git.status(repo);
      if (st.branch == null) throw GitError('HEAD is detached — nothing to push.');
      if (st.head == null) throw GitError('No commits yet.');
      branch = st.branch!;
      head = st.head!;
      if (st.upstream != null) {
        remote = st.upstream!.split('/').first;
        setUpstream = false;
        if (st.behind > 0) throw GitError('The remote has ${st.behind} commit(s) you don\'t have — pull first (LEO never force-pushes).');
        outgoing = await git.log(repo, n: 50, range: '@{u}..HEAD');
      } else {
        final rs = await git.remotes(repo);
        if (rs.isEmpty) throw GitError('This repository has no remote.');
        remote = rs.contains('origin') ? 'origin' : rs.first;
        setUpstream = true;
        outgoing = await git.log(repo, n: 50, range: 'HEAD');
      }
      c.detail('check', '$branch → $remote · ${outgoing.length} commit(s)');
    });
    if (outgoing.isEmpty) return 'Nothing to push: $branch is up to date with $remote.';

    final params = <String, Object?>{
      'repo': repo,
      'remote': remote,
      'remoteUrl': await git.remoteUrl(repo, remote),
      'branch': branch,
      'head': head,
      'setUpstream': setUpstream,
      'commits': [for (final x in outgoing.take(20)) '${_short(x.hash)} ${x.subject}'],
    };
    late ApprovalTicket ticket;
    await c.step('approve', () async {
      ticket = await c.approve(
          action: 'git.push', title: 'Push ${outgoing.length} commit(s) to $remote/$branch', risk: Risk.external, target: '$remote/$branch', params: params);
      if (!ticket.approved) throw Declined('You declined — nothing was pushed.');
    }, doneDetail: 'Approved');

    await c.step('push', () async {
      if (!ticket.consume('$remote/$branch', params)) throw StateError('approval does not match this push');
      if ((await git.status(repo)).head != head) throw GitError('New commits appeared after approval — push again to review them.');
      await git.push(repo, remote, branch, setUpstream: setUpstream);
    });

    await c.step('verify', () async {
      final remoteHead = await git.remoteHead(repo, remote, branch);
      if (remoteHead != head) throw GitError('Remote has ${remoteHead == null ? 'no branch' : _short(remoteHead)}, expected ${_short(head)}');
    }, doneDetail: '$remote/$branch = ${_short(head)}');

    return 'Pushed ${outgoing.length} commit(s) to $remote/$branch — the remote now has ${_short(head)}.';
  }
}

/// PULL (fast-forward only): fetch → show incoming → approval → pull → verify HEAD = upstream.
class GitPullTask extends TaskDefinition {
  final Git git;
  final String repo;
  GitPullTask(this.git, {required this.repo});

  @override
  String get kind => 'git.pull';
  @override
  String get title => 'Pull ${p.basename(repo)}';

  @override
  List<TaskStep> plan() => const [
        TaskStep(id: 'fetch', description: 'Fetch and list incoming commits'),
        TaskStep(id: 'approve', description: 'Ask your approval'),
        TaskStep(id: 'pull', description: 'Fast-forward (no merge commits)'),
        TaskStep(id: 'verify', description: 'Verify you are up to date'),
      ];

  @override
  Future<String> run(TaskContext c) async {
    late GitStatus st;
    late List<GitCommitInfo> incoming;
    await c.step('fetch', () async {
      st = await git.status(repo);
      if (st.upstream == null) throw GitError('This branch has no upstream to pull from.');
      await c.guard(git.fetch(repo, st.upstream!.split('/').first));
      incoming = await git.log(repo, n: 50, range: 'HEAD..@{u}');
      c.detail('fetch', '${incoming.length} incoming');
    });
    if (incoming.isEmpty) return 'Already up to date with ${st.upstream}.';
    final params = <String, Object?>{
      'repo': repo,
      'branch': st.branch,
      'upstream': st.upstream,
      'incoming': [for (final x in incoming.take(20)) '${_short(x.hash)} ${x.subject}'],
    };
    late ApprovalTicket ticket;
    await c.step('approve', () async {
      ticket = await c.approve(
          action: 'git.pull', title: 'Pull ${incoming.length} commit(s) into ${st.branch}', risk: Risk.writeLocal, target: repo, params: params);
      if (!ticket.approved) throw Declined('You declined — nothing was pulled.');
    }, doneDetail: 'Approved');
    await c.step('pull', () async {
      if (!ticket.consume(repo, params)) throw StateError('approval does not match');
      await git.pullFastForward(repo);
    });
    await c.step('verify', () async {
      final now = await git.status(repo);
      if (now.behind != 0) throw GitError('Still ${now.behind} behind ${st.upstream}');
    }, doneDetail: 'Up to date');
    return 'Pulled ${incoming.length} commit(s) into ${st.branch} (fast-forward).';
  }
}

/// NEW BRANCH: validate name → approval → create + switch → verify current branch.
class GitBranchTask extends TaskDefinition {
  final Git git;
  final String repo, name;
  GitBranchTask(this.git, {required this.repo, required this.name});

  @override
  String get kind => 'git.branch';
  @override
  String get title => 'Create branch $name';

  @override
  List<TaskStep> plan() => const [
        TaskStep(id: 'check', description: 'Check the branch name'),
        TaskStep(id: 'approve', description: 'Ask your approval'),
        TaskStep(id: 'create', description: 'Create and switch to the branch'),
        TaskStep(id: 'verify', description: 'Verify the current branch'),
      ];

  @override
  Future<String> run(TaskContext c) async {
    await c.step('check', () async {
      if (!await git.validBranchName(name)) throw GitError('"$name" is not a valid branch name.');
      if ((await git.branches(repo)).contains(name)) throw GitError('Branch "$name" already exists.');
    });
    final params = <String, Object?>{'repo': repo, 'branch': name, 'from': (await git.status(repo)).branch};
    late ApprovalTicket ticket;
    await c.step('approve', () async {
      ticket = await c.approve(action: 'git.branch', title: 'Create branch $name', risk: Risk.writeLocal, target: repo, params: params);
      if (!ticket.approved) throw Declined('You declined — no branch created.');
    }, doneDetail: 'Approved');
    await c.step('create', () async {
      if (!ticket.consume(repo, params)) throw StateError('approval does not match');
      await git.createBranch(repo, name);
    });
    await c.step('verify', () async {
      if ((await git.status(repo)).branch != name) throw GitError('Not on $name after creating it');
    }, doneDetail: 'On $name');
    return 'Created and switched to branch $name.';
  }
}
