import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leo_desktop/agent_client.dart';
import 'package:leo_desktop/screens.dart';
import 'package:leo_desktop/theme.dart';

Widget _wrap(Widget w) => MaterialApp(theme: leoTheme(), home: Scaffold(body: SingleChildScrollView(child: w)));

void main() {
  testWidgets('approval card shows the exact parameters that will be executed', (t) async {
    await t.pumpWidget(_wrap(ApprovalCard(c: AgentClient(), a: {
      'id': 'ab12',
      'taskId': 3,
      'action': 'file.write',
      'title': 'Write a test file',
      'risk': 'writeLocal',
      'target': r'C:\LEO\work\task-3.txt',
      'params': {'path': r'C:\LEO\work\task-3.txt', 'content': 'hello'},
      'fingerprint': 'fp',
    })));
    expect(find.textContaining('"content": "hello"'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
  });

  testWidgets('task card offers controls that match the state', (t) async {
    Map<String, dynamic> task(String state) => {
          'id': 1,
          'title': 'Self-test',
          'state': state,
          'stateLabel': state.toUpperCase(),
          'steps': [
            {'id': 'count', 'description': 'Count', 'status': 'running', 'detail': '3 / 10'}
          ],
        };
    await t.pumpWidget(_wrap(TaskCard(c: AgentClient(), t: task('running'))));
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Resume'), findsNothing);
    expect(find.byTooltip('Stop'), findsOneWidget);
    await t.pumpWidget(_wrap(TaskCard(c: AgentClient(), t: task('paused'))));
    expect(find.byTooltip('Resume'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsNothing);
    await t.pumpWidget(_wrap(TaskCard(c: AgentClient(), t: task('completed'))));
    expect(find.byTooltip('Stop'), findsNothing);
  });
}
