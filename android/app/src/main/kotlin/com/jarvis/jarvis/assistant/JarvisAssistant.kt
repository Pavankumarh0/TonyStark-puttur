package com.jarvis.jarvis.assistant

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService
import android.speech.RecognitionService
import com.jarvis.jarvis.AssistActivity

/**
 * Lets the user pick JARVIS under Settings → Apps → Default apps → Digital assistant app.
 * Long-pressing the side key / home (or swiping up from a bottom corner) then opens the
 * half-screen JARVIS panel instead of Google's assistant.
 */
class JarvisVoiceInteractionService : VoiceInteractionService()

class JarvisSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession = JarvisSession(this)
}

class JarvisSession(context: Context) : VoiceInteractionSession(context) {
    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        val i = Intent(context, AssistActivity::class.java)
        if (Build.VERSION.SDK_INT >= 29) {
            startAssistantActivity(i)
        } else {
            context.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        // Our own activity draws the UI; the system session window is not needed.
        hide()
    }
}

/** Required by the platform for a voice interaction service. JARVIS does its own speech recognition. */
class JarvisRecognitionService : RecognitionService() {
    override fun onStartListening(recognizerIntent: Intent?, listener: Callback?) {
        listener?.error(android.speech.SpeechRecognizer.ERROR_RECOGNIZER_BUSY)
    }
    override fun onCancel(listener: Callback?) {}
    override fun onStopListening(listener: Callback?) {}
}
