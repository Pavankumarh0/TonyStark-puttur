package com.jarvis.jarvis

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * Half-screen assistant panel (like Gemini's overlay). Translucent window over whatever app is
 * open; the Flutter side renders a bottom panel when it receives the "assist" event.
 * Shares the single JARVIS engine so memory, tasks and the wake word stay in one place.
 */
class AssistActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(JarvisApplication.ENGINE_ID)

    override fun shouldDestroyEngineWithHost(): Boolean = false
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        JarvisApplication.activeHost = this
        DeviceChannel.assistActivity = this
    }

    override fun onResume() {
        super.onResume()
        DeviceChannel.emit(mapOf("type" to "assist", "on" to true))
    }

    override fun onPause() {
        super.onPause()
        if (isFinishing) DeviceChannel.emit(mapOf("type" to "assist", "on" to false))
    }

    override fun onStop() {
        super.onStop()
        // Behaves like a transient overlay: leaving it closes it.
        if (!isFinishing) finish()
    }

    override fun onDestroy() {
        if (DeviceChannel.assistActivity === this) DeviceChannel.assistActivity = null
        DeviceChannel.emit(mapOf("type" to "assist", "on" to false))
        super.onDestroy()
    }
}
