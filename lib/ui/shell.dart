import 'package:flutter/material.dart';

import 'analytics_screen.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'memory_screen.dart';
import 'privacy_screen.dart';
import 'settings_screen.dart';

class JarvisShell extends StatefulWidget {
  const JarvisShell({super.key});

  @override
  State<JarvisShell> createState() => _JarvisShellState();
}

class _JarvisShellState extends State<JarvisShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // Informed consent before any optional cloud processing (OpenAI stays off until answered).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showPrivacyConsent(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      const HomeScreen(),
      const HistoryScreen(),
      const MemoryScreen(),
      const AnalyticsScreen(),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _tab, children: pages)),
      bottomNavigationBar: NavigationBar(
        height: 64,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.blur_circular), label: 'LEO'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
          NavigationDestination(icon: Icon(Icons.psychology_outlined), label: 'Memory'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), label: 'Analytics'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
        ],
      ),
    );
  }
}
