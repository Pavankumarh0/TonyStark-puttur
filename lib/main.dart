import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'ai/ai_service.dart';
import 'data/context_builder.dart';
import 'data/database.dart';
import 'data/memory_repository.dart';
import 'data/settings_store.dart';
import 'device/app_resolver.dart';
import 'device/device_bridge.dart';
import 'orchestrator/jarvis_orchestrator.dart';
import 'ui/assist_panel.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';
import 'voice/mic_engine.dart';
import 'voice/sarvam_client.dart';
import 'voice/speech_input.dart';
import 'voice/speech_output.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: JColors.bg,
    systemNavigationBarColor: JColors.navy,
    statusBarIconBrightness: Brightness.light,
  ));

  final settings = SettingsStore();
  await settings.load();
  final db = JarvisDatabase();
  await db.open();
  final memory = MemoryRepository(db);
  final sarvam = SarvamClient();
  final mic = MicEngine();
  final speechIn = SpeechInput(mic, sarvam, settings, memory);
  // Separate Sarvam client for TTS so cancelling speech does not abort transcription and vice versa.
  final speechOut = SpeechOutput(settings, SarvamClient(), memory);
  final device = DeviceBridge();
  final orchestrator = JarvisOrchestrator(
    settings: settings,
    memory: memory,
    contextBuilder: ContextBuilder(memory),
    ai: AiService(settings, memory),
    mic: mic,
    speechIn: speechIn,
    speechOut: speechOut,
    device: device,
    apps: AppResolver(device),
  );

  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider.value(value: orchestrator),
      ChangeNotifierProvider.value(value: mic),
      Provider.value(value: memory),
      Provider.value(value: device),
    ],
    child: const JarvisApp(),
  ));
  await orchestrator.init();
}

class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Assistant role: the translucent AssistActivity shows a half-screen panel instead of the full app.
    final assist = context.select<JarvisOrchestrator, bool>((o) => o.assistMode);
    return MaterialApp(
      title: 'JARVIS',
      debugShowCheckedModeBanner: false,
      theme: jarvisTheme(),
      color: assist ? Colors.transparent : JColors.bg,
      home: assist ? const AssistPanel() : const JarvisShell(),
    );
  }
}
