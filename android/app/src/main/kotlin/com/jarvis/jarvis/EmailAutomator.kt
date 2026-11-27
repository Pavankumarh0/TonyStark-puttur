package com.jarvis.jarvis

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Compose an email with recipient / subject / body filled in (Gmail if installed), and — only after
 * the user approved that exact email in LEO — verify the draft on screen and press Send.
 */
object EmailAutomator {
    const val GMAIL = "com.google.android.gm"

    private fun installed(ctx: Context, pkg: String) = try {
        ctx.packageManager.getPackageInfo(pkg, 0); true
    } catch (_: Exception) { false }

    /** Opens the compose screen. Returns {ok, app}. */
    fun compose(ctx: Context, to: String, subject: String, body: String): Map<String, Any?> {
        val uri = Uri.parse("mailto:${Uri.encode(to)}?subject=${Uri.encode(subject)}&body=${Uri.encode(body)}")
        val i = Intent(Intent.ACTION_SENDTO, uri)
            .putExtra(Intent.EXTRA_EMAIL, arrayOf(to))
            .putExtra(Intent.EXTRA_SUBJECT, subject)
            .putExtra(Intent.EXTRA_TEXT, body)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val gmail = installed(ctx, GMAIL)
        if (gmail) i.setPackage(GMAIL)
        return try {
            ctx.startActivity(i)
            mapOf("ok" to true, "app" to if (gmail) GMAIL else "default")
        } catch (e: Exception) {
            mapOf("ok" to false, "reason" to (e.message ?: "No email app"))
        }
    }

    private fun allNodes(root: AccessibilityNodeInfo): List<AccessibilityNodeInfo> {
        val out = mutableListOf<AccessibilityNodeInfo>()
        val q = ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        while (q.isNotEmpty() && out.size < 2000) {
            val n = q.removeFirst(); out += n
            for (i in 0 until n.childCount) n.getChild(i)?.let { q.add(it) }
        }
        return out
    }

    private fun norm(s: String) = s.lowercase().replace(Regex("\\s+"), " ").trim()

    /**
     * Verifies the open compose screen holds [to] and [body], then taps Send.
     * Returns {ok, status: sent|not_compose|mismatch|no_send_button|tap_failed|accessibility_off, reason}.
     */
    fun send(to: String, body: String, pkg: String?): Map<String, Any?> {
        val s = JarvisAccessibilityService.instance ?: return mapOf("ok" to false, "status" to "accessibility_off")
        var root: AccessibilityNodeInfo? = null
        val end = System.currentTimeMillis() + 8000
        while (System.currentTimeMillis() < end) {
            val r = (pkg?.let { s.rootFor(it) }) ?: s.rootInActiveWindow
            if (r != null && allNodes(r).any { isSend(it) }) { root = r; break }
            Thread.sleep(300)
        }
        if (root == null) return mapOf("ok" to false, "status" to "not_compose", "reason" to "The compose screen isn't showing")
        val nodes = allNodes(root)
        val text = nodes.joinToString(" | ") { listOfNotNull(it.text?.toString(), it.contentDescription?.toString()).joinToString(" ") }
        // Safety: never send something different from what the user approved.
        val toOk = norm(text).contains(norm(to)) || norm(text).contains(norm(to.substringBefore('@')))
        val bodyProbe = norm(body).take(30)
        val bodyOk = bodyProbe.isEmpty() || norm(text).contains(bodyProbe)
        if (!toOk || !bodyOk) {
            return mapOf("ok" to false, "status" to "mismatch",
                "reason" to (if (!toOk) "The To field doesn't show $to" else "The email text on screen differs from what you approved"))
        }
        val btn = nodes.firstOrNull { isSend(it) } ?: return mapOf("ok" to false, "status" to "no_send_button")
        var target: AccessibilityNodeInfo? = btn
        while (target != null && !target.isClickable) target = target.parent
        if (target?.performAction(AccessibilityNodeInfo.ACTION_CLICK) != true) return mapOf("ok" to false, "status" to "tap_failed")
        // Sent → compose screen closes (Gmail shows "Sending…").
        val closeEnd = System.currentTimeMillis() + 5000
        while (System.currentTimeMillis() < closeEnd) {
            Thread.sleep(400)
            val r = s.rootInActiveWindow ?: continue
            if (allNodes(r).none { isSend(it) }) return mapOf("ok" to true, "status" to "sent")
        }
        return mapOf("ok" to true, "status" to "sent_unconfirmed")
    }

    private fun isSend(n: AccessibilityNodeInfo): Boolean {
        val id = n.viewIdResourceName ?: ""
        val d = (n.contentDescription?.toString() ?: n.text?.toString() ?: "").trim()
        return id.endsWith(":id/send") || d.equals("Send", ignoreCase = true) || d.equals("Send email", ignoreCase = true)
    }
}
