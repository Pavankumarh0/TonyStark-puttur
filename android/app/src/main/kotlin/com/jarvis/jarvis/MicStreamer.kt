package com.jarvis.jarvis

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Process-scoped microphone stream (16 kHz mono PCM16, 512-sample frames) for the on-device wake
 * word and voice capture. Unlike activity-scoped plugins it keeps running when the UI is closed or
 * switches between the full app and the assistant panel; the microphone foreground service keeps
 * Android from silencing it in the background.
 */
object MicStreamer : EventChannel.StreamHandler {
    private const val SAMPLE_RATE = 16000
    private const val FRAME = 512
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null
    @Volatile private var thread: Thread? = null
    @Volatile private var running = false

    val isRunning get() = running

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }

    @SuppressLint("MissingPermission") // RECORD_AUDIO is checked by the Dart layer before start()
    @Synchronized
    fun start(): String? {
        if (running) return null
        val min = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return "Microphone not available"
        val rec = try {
            AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(min, FRAME * 2 * 8))
        } catch (e: Exception) { return e.message ?: "Could not open microphone" }
        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); return "Microphone is busy or permission missing" }
        try { rec.startRecording() } catch (e: Exception) { rec.release(); return e.message }
        running = true
        thread = Thread({
            val buf = ShortArray(FRAME)
            try {
                while (running) {
                    var off = 0
                    while (off < FRAME && running) {
                        val n = rec.read(buf, off, FRAME - off)
                        if (n < 0) throw IllegalStateException("AudioRecord read error $n")
                        off += n
                    }
                    if (!running) break
                    val bytes = ByteBuffer.allocate(FRAME * 2).order(ByteOrder.LITTLE_ENDIAN)
                    bytes.asShortBuffer().put(buf)
                    val out = bytes.array()
                    main.post { sink?.success(out) }
                }
            } catch (e: Exception) {
                main.post { sink?.error("mic_error", e.message, null) }
            } finally {
                running = false
                try { rec.stop() } catch (_: Exception) {}
                rec.release()
            }
        }, "jarvis-mic").apply { priority = Thread.MAX_PRIORITY; start() }
        return null
    }

    @Synchronized
    fun stop() {
        running = false
        thread?.join(500)
        thread = null
    }
}
