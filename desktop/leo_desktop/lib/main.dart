import 'package:flutter/material.dart';

import 'agent_client.dart';
import 'screens.dart';
import 'theme.dart';

void main() {
  final client = AgentClient()..start();
  runApp(LeoDesktopApp(client: client));
}

class LeoDesktopApp extends StatelessWidget {
  final AgentClient client;
  const LeoDesktopApp({super.key, required this.client});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'LEO Desktop',
        debugShowCheckedModeBanner: false,
        theme: leoTheme(),
        home: Shell(client: client),
      );
}
