package com.jarvis.jarvis

import android.content.Context
import android.content.Intent
import android.os.Bundle
import com.jarvis.jarvis.assistant.JarvisVoiceInteractionService

/**
 * "Leo" heard while no LEO screen is showing → slide up the assistant panel over whatever app is
 * open, the way "Hey Google" pops Gemini up.
 *  1. As the default digital assistant: ask the system to show our assistant session (same path as
 *     long-pressing the side key).
 *  2. Otherwise: open the panel directly (allowed from the background because LEO's accessibility
 *     service is bound).
 */
object WakePopup {
    fun show(ctx: Context): String {
        if (JarvisApplication.visibleScreens > 0) return "visible"
        JarvisVoiceInteractionService.instance?.let { vis ->
            try {
                vis.showSession(Bundle().apply { putBoolean("wake", true) }, 0)
                return "session"
            } catch (_: Exception) { /* fall through */ }
        }
        return try {
            ctx.startActivity(
                Intent(ctx, AssistActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
            )
            "activity"
        } catch (e: Exception) {
            "failed: ${e.message}"
        }
    }
}
