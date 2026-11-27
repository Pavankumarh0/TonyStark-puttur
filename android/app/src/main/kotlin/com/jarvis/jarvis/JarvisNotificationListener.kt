package com.jarvis.jarvis

import android.app.Notification
import android.os.Build
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Reads the notifications that are currently showing for messaging/email apps so JARVIS can answer
 * "check my new WhatsApp messages / emails" entirely on-device (no AI, no network).
 * Requires the user to grant Notification access (Settings → Notifications → Device & app notifications).
 */
class JarvisNotificationListener : NotificationListenerService() {

    override fun onListenerConnected() { instance = this }
    override fun onListenerDisconnected() { if (instance === this) instance = null }
    override fun onDestroy() { if (instance === this) instance = null; super.onDestroy() }

    companion object {
        @Volatile var instance: JarvisNotificationListener? = null

        val WHATSAPP = setOf("com.whatsapp", "com.whatsapp.w4b")
        val EMAIL = setOf(
            "com.google.android.gm", "com.samsung.android.email.provider", "com.microsoft.office.outlook",
            "com.yahoo.mobile.client.android.mail", "ch.protonmail.android",
        )

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
