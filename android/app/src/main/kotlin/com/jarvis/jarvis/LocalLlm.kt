package com.jarvis.jarvis

import android.content.Context
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * On-device language model (no API key, no network once downloaded) used as LEO's screen-agent
 * brain: Qwen2.5-1.5B-Instruct (Apache-2.0), 8-bit, run with Google's MediaPipe LLM Inference.
 */
object LocalLlm {
    const val FILE = "qwen2.5-1.5b-instruct-q8-ekv1280.task"
    const val URL_ = "https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv1280.task"
    const val SIZE = 1_597_913_616L
    const val MAX_TOKENS = 1280 // the model's KV-cache size: prompt + answer must fit

    @Volatile private var engine: LlmInference? = null
    @Volatile private var session: LlmInferenceSession? = null
    @Volatile var downloading = false
    @Volatile private var cancelDownload = false

    fun file(ctx: Context) = File(File(ctx.filesDir, "models").apply { mkdirs() }, FILE)

    fun status(ctx: Context): Map<String, Any?> {
        val f = file(ctx)
        val part = File(f.path + ".part")
        return mapOf(
            "installed" to (f.exists() && f.length() == SIZE),
            "bytes" to if (f.exists()) f.length() else part.length(),
            "total" to SIZE,
            "downloading" to downloading,
            "loaded" to (engine != null),
        )
    }

    /** Resumable download with progress events ({type: model_download, bytes, total, done, error}). */
    fun download(ctx: Context) {
        if (downloading) return
        downloading = true
        cancelDownload = false
        Thread({
            val f = file(ctx)
            val part = File(f.path + ".part")
            try {
                var have = if (part.exists()) part.length() else 0L
                val conn = (URL(URL_).openConnection() as HttpURLConnection).apply {
                    instanceFollowRedirects = true
                    connectTimeout = 20000; readTimeout = 30000
                    if (have > 0) setRequestProperty("Range", "bytes=$have-")
                }
                if (conn.responseCode == 200) have = 0 // server ignored the range: start over
                if (conn.responseCode !in listOf(200, 206)) throw IllegalStateException("HTTP ${conn.responseCode}")
                conn.inputStream.use { input ->
                    FileOutputStream(part, have > 0).use { out ->
                        val buf = ByteArray(1 shl 16)
                        var last = 0L
                        while (true) {
                            if (cancelDownload) throw InterruptedException("cancelled")
                            val n = input.read(buf); if (n < 0) break
                            out.write(buf, 0, n); have += n
                            if (have - last > 8_000_000) {
                                last = have
                                DeviceChannel.emit(mapOf("type" to "model_download", "bytes" to have, "total" to SIZE))
                            }
                        }
                    }
                }
                if (part.length() != SIZE) throw IllegalStateException("Incomplete download (${part.length()} of $SIZE bytes)")
                part.renameTo(f)
                DeviceChannel.emit(mapOf("type" to "model_download", "bytes" to SIZE, "total" to SIZE, "done" to true))
            } catch (e: Exception) {
                DeviceChannel.emit(mapOf("type" to "model_download", "error" to (e.message ?: e.javaClass.simpleName)))
            } finally {
                downloading = false
            }
        }, "leo-model-download").start()
    }

    fun cancel() { cancelDownload = true }

    fun delete(ctx: Context) {
        unload()
        file(ctx).delete(); File(file(ctx).path + ".part").delete()
    }

    @Synchronized
    private fun ensure(ctx: Context): LlmInference {
        engine?.let { return it }
        val f = file(ctx)
        if (!f.exists() || f.length() != SIZE) throw IllegalStateException("The on-device model is not downloaded")
        fun build(backend: LlmInference.Backend) = LlmInference.createFromOptions(ctx,
            LlmInference.LlmInferenceOptions.builder()
                .setModelPath(f.path)
                .setMaxTokens(MAX_TOKENS)
                .setPreferredBackend(backend)
                .build())
        val e = try { build(LlmInference.Backend.GPU) } catch (_: Throwable) { build(LlmInference.Backend.CPU) }
        engine = e
        return e
    }

    fun countTokens(ctx: Context, text: String): Int = try { ensure(ctx).sizeInTokens(text) } catch (_: Throwable) { text.length / 3 }

    /** Deterministic generation (temperature 0, top-k 1) — best for small models emitting JSON. */
    @Synchronized
    fun generate(ctx: Context, prompt: String): String {
        val e = ensure(ctx)
        session?.close()
        val s = LlmInferenceSession.createFromOptions(e,
            LlmInferenceSession.LlmInferenceSessionOptions.builder().setTopK(1).setTemperature(0.0f).setRandomSeed(1).build())
        session = s
        try {
            s.addQueryChunk(prompt)
            return s.generateResponse()
        } finally {
            s.close()
            session = null
        }
    }

    fun unload() {
        try { session?.close() } catch (_: Throwable) {}
        try { engine?.close() } catch (_: Throwable) {}
        session = null; engine = null
    }
}
