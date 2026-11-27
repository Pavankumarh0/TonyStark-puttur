package com.jarvis.jarvis

import android.content.ComponentName
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build

/**
 * Talks to whatever app is playing (YouTube, Spotify, …) through its media session, so LEO
 * knows the real playback state and title, and can pause/resume precisely.
 *
 * While LEO listens it holds TRANSIENT audio focus (like Google Assistant/Gemini): music pauses
 * so the mic hears you, and resumes automatically afterwards — unless you told LEO to pause it.
 */
object MediaBridge {
    private var focusRequest: AudioFocusRequest? = null
    @Volatile var playingBeforeListen = false
    @Volatile private var pausedByUserDuringListen = false

    private fun am(ctx: Context) = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun controllers(ctx: Context): List<MediaController> = try {
        val msm = ctx.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
        msm.getActiveSessions(ComponentName(ctx, JarvisNotificationListener::class.java))
    } catch (_: SecurityException) { emptyList() } // needs notification access

    private fun isPlaying(c: MediaController) = c.playbackState?.state == PlaybackState.STATE_PLAYING

    /** The session the user means: the one playing, else the most recently active one. */
    private fun target(ctx: Context): MediaController? {
        val list = controllers(ctx)
        return list.firstOrNull { isPlaying(it) }
            ?: list.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PAUSED }
            ?: list.firstOrNull()
    }

    private fun describe(c: MediaController?): Map<String, Any?> {
        val md = c?.metadata
        return mapOf(
            "title" to md?.getString(MediaMetadata.METADATA_KEY_TITLE),
            "artist" to md?.getString(MediaMetadata.METADATA_KEY_ARTIST),
            "app" to c?.packageName,
            "playing" to (c?.let { isPlaying(it) } ?: false),
        )
    }

    /** Waits until [pkg]'s media session reports PLAYING; returns its description, or null on timeout. */
    fun waitForPlaying(ctx: Context, pkg: String, timeoutMs: Long): Map<String, Any?>? {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            // Only the target app's own PLAYING session counts. (isMusicActive is NOT used: LEO's own
            // voice also counts as "music" and would produce a false "now playing".)
            val c = controllers(ctx).firstOrNull { it.packageName == pkg && isPlaying(it) }
            if (c != null) return describe(c)
            Thread.sleep(400)
        }
        return null
    }

    fun nowPlaying(ctx: Context): Map<String, Any?> = describe(target(ctx)) + mapOf(
        "playingBeforeListen" to playingBeforeListen,
    )

    // ------------------------------------------------------------------ listening focus
    fun beginListening(ctx: Context) {
        if (focusRequest != null) return
        val am = am(ctx)
        playingBeforeListen = am.isMusicActive || (target(ctx)?.let { isPlaying(it) } ?: false)
        pausedByUserDuringListen = false
        if (Build.VERSION.SDK_INT >= 26) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setOnAudioFocusChangeListener { }
                .build()
            am.requestAudioFocus(req)
            focusRequest = req
        }
    }

    fun endListening(ctx: Context) {
        val req = focusRequest ?: return
        focusRequest = null
        if (Build.VERSION.SDK_INT >= 26) am(ctx).abandonAudioFocusRequest(req)
        // The playing app resumes by itself after transient focus loss, unless the user paused it.
        playingBeforeListen = false
    }

    // ------------------------------------------------------------------ commands
    /** Returns {status, title, artist, app}. status: paused|playing|done|not_playing|already_playing|nothing_to_resume|unchanged|no_session */
    fun control(ctx: Context, action: String): Map<String, Any?> {
        val c = target(ctx)
        if (c == null) return mapOf("status" to fallbackKey(ctx, action))
        val tc = c.transportControls
        val playingNow = isPlaying(c) || (focusRequest != null && playingBeforeListen)
        val status = when (action) {
            "pause" -> {
                if (!playingNow) "not_playing" else {
                    tc.pause()
                    pausedByUserDuringListen = true
                    playingBeforeListen = false
                    Thread.sleep(500)
                    if (!isPlaying(c)) "paused" else "unchanged"
                }
            }
            "play" -> {
                if (isPlaying(c) || (focusRequest != null && playingBeforeListen)) "already_playing" else {
                    endListening(ctx) // give focus back so the player can actually start
                    tc.play()
                    Thread.sleep(900)
                    if (isPlaying(c)) "playing" else "nothing_to_resume"
                }
            }
            "next" -> { tc.skipToNext(); Thread.sleep(1200); "done" }
            "previous" -> { tc.skipToPrevious(); Thread.sleep(1200); "done" }
            else -> "unchanged"
        }
        return describe(target(ctx) ?: c) + mapOf("status" to status)
    }

    /** No media-session access: fall back to media keys + isMusicActive (less precise). */
    private fun fallbackKey(ctx: Context, action: String): String {
        val am = am(ctx)
        val key = when (action) {
            "pause" -> android.view.KeyEvent.KEYCODE_MEDIA_PAUSE
            "play" -> android.view.KeyEvent.KEYCODE_MEDIA_PLAY
            "next" -> android.view.KeyEvent.KEYCODE_MEDIA_NEXT
            "previous" -> android.view.KeyEvent.KEYCODE_MEDIA_PREVIOUS
            else -> return "unchanged"
        }
        val was = am.isMusicActive || playingBeforeListen
        if (action == "pause" && !was) return "not_playing"
        am.dispatchMediaKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, key))
        am.dispatchMediaKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_UP, key))
        if (action == "pause") playingBeforeListen = false
        Thread.sleep(800)
        return when (action) {
            "pause" -> "paused"
            "play" -> if (am.isMusicActive) "playing" else "nothing_to_resume"
            else -> "done"
        }
    }
}
