package com.jarvis.jarvis

import android.app.Activity
import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(JarvisApplication.ENGINE_ID)

    // The engine outlives the activity (see JarvisApplication).
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        JarvisApplication.activeHost = this
    }

    override fun onPause() {
        super.onPause()
        JarvisApplication.visibleScreens = maxOf(0, JarvisApplication.visibleScreens - 1)
    }

    override fun onResume() {
        super.onResume()
        JarvisApplication.visibleScreens++
        JarvisApplication.applySecure(this)
        // The single engine can render into one window at a time. If the assistant panel took it
        // over while we were in the background, re-attach by recreating this activity.
        val host: Activity? = JarvisApplication.activeHost
        if (host !== this) {
            recreate()
        }
    }
}
