package com.jarvis.jarvis

import android.app.Notification
import android.os.Build
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Reads the notifications that are currently showing for messaging/email apps so LEO can answer
 * "check my new WhatsApp messages / emails" entirely on-device (no AI, no network).
 * Requires the user to grant Notification access (Settings → Notifications → Device & app notifications).
 */
class JarvisNotificationListener : NotificationListenerService() {

    override fun onListenerConnected() { instance = this }

    /** Incoming call → tell LEO who is calling (so it can announce and accept "Leo, answer"). */
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val n = sbn?.notification ?: return
        if (n.category != Notification.CATEGORY_CALL) return
        val ex = n.extras
        val title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: return
        val text = ex.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        val incoming = text.contains("incoming", ignoreCase = true) || n.fullScreenIntent != null
        if (incoming) DeviceChannel.emit(mapOf("type" to "incoming_call", "caller" to title, "package" to sbn.packageName))
    }
    override fun onListenerDisconnected() { if (instance === this) instance = null }
    override fun onDestroy() { if (instance === this) instance = null; super.onDestroy() }

    companion object {
        @Volatile var instance: JarvisNotificationListener? = null

        val WHATSAPP = setOf("com.whatsapp", "com.whatsapp.w4b")
        val EMAIL = setOf(
            "com.google.android.gm", "com.samsung.android.email.provider", "com.microsoft.office.outlook",
            "com.yahoo.mobile.client.android.mail", "ch.protonmail.android",
        )

        /** Chats that currently offer a notification "Reply" box, matching [who] (case-insensitive). */
        fun replyTargets(who: String): List<Map<String, Any?>> {
            val svc = instance ?: return emptyList()
            val q = who.trim().lowercase()
            return svc.activeNotifications.orEmpty().mapNotNull { sbn ->
                val ex = sbn.notification.extras
                val title = (ex.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE) ?: ex.getCharSequence(Notification.EXTRA_TITLE))?.toString()
                    ?: return@mapNotNull null
                val hasReply = sbn.notification.actions?.any { a -> a.remoteInputs?.isNotEmpty() == true } == true
                if (!hasReply || !title.lowercase().contains(q)) return@mapNotNull null
                mapOf("key" to sbn.key, "title" to title, "package" to sbn.packageName)
            }.distinctBy { it["title"] to it["package"] }
        }

        /** Sends [text] through the notification's own Reply action (no app UI needed). */
        fun reply(ctx: android.content.Context, key: String, text: String): Map<String, Any?> {
            val svc = instance ?: return mapOf("ok" to false, "reason" to "Notification access is off")
            val sbn = svc.activeNotifications.orEmpty().firstOrNull { it.key == key }
                ?: return mapOf("ok" to false, "reason" to "That notification is gone (it may have been opened or cleared)")
            val action = sbn.notification.actions?.firstOrNull { a -> a.remoteInputs?.isNotEmpty() == true }
                ?: return mapOf("ok" to false, "reason" to "This chat has no reply box in its notification")
            val intent = android.content.Intent()
            val bundle = android.os.Bundle()
            for (ri in action.remoteInputs) bundle.putCharSequence(ri.resultKey, text)
            android.app.RemoteInput.addResultsToIntent(action.remoteInputs, intent, bundle)
            return try {
                action.actionIntent.send(ctx, 0, intent)
                mapOf("ok" to true, "app" to sbn.packageName)
            } catch (e: Exception) { mapOf("ok" to false, "reason" to (e.message ?: "The app rejected the reply")) }
        }

        /** Active notifications for [packages]: one map per conversation / email. */
        fun read(packages: Set<String>): List<Map<String, Any?>> {
            val svc = instance ?: return emptyList()
            val sbns: Array<StatusBarNotification> = try { svc.activeNotifications ?: emptyArray() } catch (_: Exception) { emptyArray() }
            val out = mutableListOf<Map<String, Any?>>()
            for (sbn in sbns) {
                if (sbn.packageName !in packages) continue
                val n = sbn.notification
                val ex = n.extras
                // Skip group summaries ("5 messages from 3 chats") — the children carry the content.
                if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) continue
                val title = ex.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()
                    ?: ex.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: continue
                val lines = mutableListOf<String>()
                // MessagingStyle (WhatsApp): individual messages with senders.
                val msgs = if (Build.VERSION.SDK_INT >= 33)
                    ex.getParcelableArray(Notification.EXTRA_MESSAGES, android.os.Parcelable::class.java)
                else @Suppress("DEPRECATION") ex.getParcelableArray(Notification.EXTRA_MESSAGES)
                msgs?.forEach { p ->
                    val b = p as? android.os.Bundle ?: return@forEach
                    val text = b.getCharSequence("text")?.toString() ?: return@forEach
                    val sender = b.getCharSequence("sender")?.toString()
                    lines += if (sender != null && sender != title) "$sender: $text" else text
                }
                if (lines.isEmpty()) {
                    ex.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.forEach { lines += it.toString() }
                }
                if (lines.isEmpty()) {
                    (ex.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: ex.getCharSequence(Notification.EXTRA_TEXT))
                        ?.toString()?.let { lines += it }
                }
                out += mapOf(
                    "package" to sbn.packageName,
                    "title" to title,
                    "lines" to lines.takeLast(5),
                    "count" to lines.size,
                    "time" to sbn.postTime,
                    "subText" to ex.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString(),
                )
            }
            return out.sortedByDescending { it["time"] as Long }
        }
    }
}
