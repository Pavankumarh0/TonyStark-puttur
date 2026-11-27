package com.jarvis.jarvis

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Owns ONE long-lived Flutter engine. The activity attaches to it instead of creating its own, so
 * the Dart orchestrator (wake word, running tasks) keeps running when the activity is closed while
 * the microphone foreground service keeps the process alive.
 */
class JarvisApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this) // auto-registers all Flutter plugins
        DeviceChannel.register(this, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    companion object {
        const val ENGINE_ID = "jarvis_engine"

        /** The activity the shared engine is currently attached to (main app or assistant panel). */
        @Volatile var activeHost: android.app.Activity? = null

        /** How many LEO screens (main app / assistant panel) are on screen right now. */
        @Volatile var visibleScreens = 0
    }
}
