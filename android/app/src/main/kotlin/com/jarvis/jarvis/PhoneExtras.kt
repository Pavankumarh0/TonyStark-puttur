package com.jarvis.jarvis

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.AlarmClock
import android.provider.Settings
import android.telecom.TelecomManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Alarms (dismiss/snooze), LEO reminders, call control and file search — all local, no AI. */
object PhoneExtras {
    // ---------------------------------------------------------------- alarms
    /** mode: "time" (needs hour/minute), "next" (the next upcoming alarm), "all", "label". */
    fun dismissAlarm(ctx: Context, mode: String, hour: Int?, minute: Int?, label: String?): Map<String, Any?> {
        val i = Intent(AlarmClock.ACTION_DISMISS_ALARM).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        when (mode) {
            "time" -> {
                i.putExtra(AlarmClock.EXTRA_ALARM_SEARCH_MODE, AlarmClock.ALARM_SEARCH_MODE_TIME)
                val h = hour ?: 0
                i.putExtra(AlarmClock.EXTRA_HOUR, h % 12).putExtra(AlarmClock.EXTRA_MINUTES, minute ?: 0)
                    .putExtra(AlarmClock.EXTRA_IS_PM, h >= 12)
            }
            "all" -> i.putExtra(AlarmClock.EXTRA_ALARM_SEARCH_MODE, AlarmClock.ALARM_SEARCH_MODE_ALL)
            "label" -> i.putExtra(AlarmClock.EXTRA_ALARM_SEARCH_MODE, AlarmClock.ALARM_SEARCH_MODE_LABEL)
                .putExtra(AlarmClock.EXTRA_MESSAGE, label ?: "")
            else -> i.putExtra(AlarmClock.EXTRA_ALARM_SEARCH_MODE, AlarmClock.ALARM_SEARCH_MODE_NEXT)
        }
        return try { ctx.startActivity(i); mapOf("ok" to true) } catch (e: Exception) {
            mapOf("ok" to false, "reason" to (e.message ?: "The Clock app can't dismiss alarms this way"))
        }
    }

    fun snoozeAlarm(ctx: Context, minutes: Int?): Map<String, Any?> = try {
        ctx.startActivity(Intent(AlarmClock.ACTION_SNOOZE_ALARM).apply {
            if (minutes != null) putExtra(AlarmClock.EXTRA_ALARM_SNOOZE_DURATION, minutes)
        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); mapOf("ok" to true)
    } catch (e: Exception) { mapOf("ok" to false, "reason" to (e.message ?: "No alarm is ringing")) }

    // ---------------------------------------------------------------- LEO reminders
    private const val PREFS = "leo_reminders"
    private const val CHANNEL = "leo_reminders"

    private fun load(ctx: Context): JSONArray =
        JSONArray(ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("list", "[]"))

    private fun save(ctx: Context, a: JSONArray) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("list", a.toString()).apply()

    private fun pending(ctx: Context, id: Int, text: String): PendingIntent =
        PendingIntent.getBroadcast(ctx, id,
            Intent(ctx, ReminderReceiver::class.java).putExtra("id", id).putExtra("text", text),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    private fun schedule(ctx: Context, id: Int, at: Long, text: String) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pending(ctx, id, text)
        if (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi) // may be a few minutes late
        } else {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        }
    }

    fun addReminder(ctx: Context, at: Long, text: String): Map<String, Any?> {
        val a = load(ctx)
        val id = (System.currentTimeMillis() % 1_000_000_000).toInt()
        a.put(JSONObject().put("id", id).put("at", at).put("text", text))
        save(ctx, a)
        schedule(ctx, id, at, text)
        val exact = Build.VERSION.SDK_INT < 31 || (ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()
        return mapOf("ok" to true, "id" to id, "exact" to exact)
    }

    fun listReminders(ctx: Context): List<Map<String, Any?>> {
        val a = load(ctx)
        val now = System.currentTimeMillis()
        return (0 until a.length()).map { a.getJSONObject(it) }
            .filter { it.getLong("at") > now - 60_000 }
            .sortedBy { it.getLong("at") }
            .map { mapOf("id" to it.getInt("id"), "at" to it.getLong("at"), "text" to it.getString("text")) }
    }

    fun deleteReminder(ctx: Context, id: Int?): Map<String, Any?> {
        val a = load(ctx)
        val keep = JSONArray()
        var removed = 0
        for (i in 0 until a.length()) {
            val o = a.getJSONObject(i)
            if (id == null || o.getInt("id") == id) {
                (ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending(ctx, o.getInt("id"), o.getString("text")))
                removed++
            } else keep.put(o)
        }
        save(ctx, keep)
        return mapOf("ok" to true, "removed" to removed)
    }

    /** After a reboot, alarms are lost — reschedule future reminders. */
    fun rescheduleAll(ctx: Context) {
        val now = System.currentTimeMillis()
        listReminders(ctx).filter { (it["at"] as Long) > now }.forEach {
            schedule(ctx, it["id"] as Int, it["at"] as Long, it["text"] as String)
        }
    }

    fun showReminder(ctx: Context, id: Int, text: String) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "LEO reminders", NotificationManager.IMPORTANCE_HIGH))
        }
        val open = PendingIntent.getActivity(ctx, id, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE)
        nm.notify(id, NotificationCompat.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_jarvis)
            .setContentTitle("Reminder from LEO")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build())
        DeviceChannel.emit(mapOf("type" to "reminder", "text" to text))
        val a = load(ctx); val keep = JSONArray()
        for (i in 0 until a.length()) a.getJSONObject(i).let { if (it.getInt("id") != id) keep.put(it) }
        save(ctx, keep)
    }

    fun exactAlarmsAllowed(ctx: Context): Boolean = Build.VERSION.SDK_INT < 31 ||
        (ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()

    fun openExactAlarmSettings(ctx: Context) {
        if (Build.VERSION.SDK_INT >= 31) try {
            ctx.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${ctx.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) {}
    }

    // ---------------------------------------------------------------- calls
    private fun tm(ctx: Context) = ctx.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
    private fun canControlCalls(ctx: Context) =
        ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.ANSWER_PHONE_CALLS) == android.content.pm.PackageManager.PERMISSION_GRANTED

    @Suppress("DEPRECATION", "MissingPermission")
    fun answerCall(ctx: Context): Map<String, Any?> {
        if (!canControlCalls(ctx)) return mapOf("ok" to false, "reason" to "no_permission")
        return try { tm(ctx).acceptRingingCall(); mapOf("ok" to true) } catch (e: Exception) { mapOf("ok" to false, "reason" to e.message) }
    }

    @Suppress("DEPRECATION", "MissingPermission")
    fun endCall(ctx: Context): Map<String, Any?> {
        if (!canControlCalls(ctx)) return mapOf("ok" to false, "reason" to "no_permission")
        if (Build.VERSION.SDK_INT < 28) return mapOf("ok" to false, "reason" to "Android 9+ needed")
        return try { mapOf("ok" to tm(ctx).endCall()) } catch (e: Exception) { mapOf("ok" to false, "reason" to e.message) }
    }

    @Suppress("MissingPermission")
    fun callState(ctx: Context): String = try {
        val read = ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.READ_PHONE_STATE) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (!read) "unknown" else if (tm(ctx).isInCall) "in_call" else "idle"
    } catch (_: Exception) { "unknown" }

    // ---------------------------------------------------------------- files
    fun allFilesAccess(): Boolean = Build.VERSION.SDK_INT < 30 || Environment.isExternalStorageManager()

    fun openAllFilesSettings(ctx: Context) {
        try {
            ctx.startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:${ctx.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) {
            ctx.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    /** Finds files whose name contains every word of [query] (any order) with one of [exts]. Newest first. */
    fun findFiles(query: String, exts: List<String>, limit: Int = 12): List<Map<String, Any?>> {
        val root = Environment.getExternalStorageDirectory()
        val words = query.lowercase().split(Regex("[^a-z0-9]+")).filter { it.length > 1 && it !in setOf("pdf", "file", "document", "my", "the") }
        val out = mutableListOf<File>()
        val skip = setOf("Android", ".thumbnails", ".Trash", "cache")
        val stack = ArrayDeque<File>().apply { add(root) }
        var visited = 0
        while (stack.isNotEmpty() && visited < 40_000) {
            val dir = stack.removeLast()
            val kids = dir.listFiles() ?: continue
            for (f in kids) {
                visited++
                if (f.isDirectory) { if (f.name !in skip && !f.name.startsWith(".")) stack.add(f); continue }
                val n = f.name.lowercase()
                if (exts.none { n.endsWith(".$it") }) continue
                if (words.isEmpty() || words.all { n.contains(it) }) out += f
            }
        }
        return out.sortedByDescending { it.lastModified() }.take(limit).map {
            mapOf("path" to it.absolutePath, "name" to it.name, "size" to it.length(), "modified" to it.lastModified(),
                "folder" to (it.parentFile?.name ?: ""))
        }
    }

    fun openFile(ctx: Context, path: String): Map<String, Any?> {
        val f = File(path)
        if (!f.exists()) return mapOf("ok" to false, "reason" to "File not found")
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", f)
        val mime = when (f.extension.lowercase()) {
            "pdf" -> "application/pdf"; "doc", "docx" -> "application/msword"; "xls", "xlsx" -> "application/vnd.ms-excel"
            "ppt", "pptx" -> "application/vnd.ms-powerpoint"; "txt" -> "text/plain"; "jpg", "jpeg", "png" -> "image/*"
            else -> "*/*"
        }
        return try {
            ctx.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)); mapOf("ok" to true)
        } catch (e: Exception) { mapOf("ok" to false, "reason" to "No app can open ${f.extension} files") }
    }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        PhoneExtras.showReminder(ctx, intent.getIntExtra("id", 0), intent.getStringExtra("text") ?: "Reminder")
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) PhoneExtras.rescheduleAll(ctx)
    }
}
