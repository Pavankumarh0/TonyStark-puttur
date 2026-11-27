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

    /**
     * Samsung (and some other) Clock apps ignore DISMISS for alarms that aren't ringing and just show a list.
     * So: open the alarm list ourselves and flip the matching switches off via accessibility.
     * hour = 0..23; ampmKnown=false matches both 6:30 am and 6:30 pm. Runs off the main thread.
     */
    fun clockSwitchOff(ctx: Context, hour: Int?, minute: Int?, ampmKnown: Boolean, all: Boolean): Map<String, Any?> {
        val s = JarvisAccessibilityService.instance ?: return mapOf("ok" to false, "status" to "accessibility_off")
        try {
            ctx.startActivity(Intent(AlarmClock.ACTION_SHOW_ALARMS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) { return mapOf("ok" to false, "status" to "no_clock_app") }
        val timeRx: Regex? = if (all || hour == null) null else {
            val mm = "%02d".format(minute ?: 0)
            val h12 = if (hour % 12 == 0) 12 else hour % 12
            val ap = if (hour >= 12) "p" else "a"
            // "6:30 am", "06:30", "18:30", and for whole hours also "7 am".
            val hm = if (mm == "00") """0?$h12(?:[:.]00)?""" else """0?$h12[:.]$mm"""
            if (ampmKnown) Regex("""(^|\D)$hm\s*$ap\.?\s*m\b|(^|\D)0?$hour[:.]$mm(?!\s*[ap]\.?\s*m)""", RegexOption.IGNORE_CASE)
            else Regex("""(^|\D)$hm\s*[ap]\.?\s*m\b|(^|\D)0?$h12[:.]$mm\b|(^|\D)${(h12 % 12) + 12}[:.]$mm\b""", RegexOption.IGNORE_CASE)
        }
        // Wait for the clock list to be in front.
        var root: android.view.accessibility.AccessibilityNodeInfo? = null
        for (i in 0 until 20) {
            Thread.sleep(250)
            val r = s.rootInActiveWindow
            val pkg = r?.packageName?.toString() ?: ""
            if (r != null && pkg != ctx.packageName && (pkg.contains("clock") || pkg.contains("alarm"))) { root = r; break }
        }
        if (root == null) return mapOf("ok" to false, "status" to "clock_not_shown")
        val pkg = root.packageName.toString()
        val timeLike = Regex("""\d{1,2}(?:[:.]\d\d)?\s*[ap]\.?\s*m\b|\d{1,2}[:.]\d\d""", RegexOption.IGNORE_CASE)
        val A = android.view.accessibility.AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
        val F = android.view.accessibility.AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
        // The list that holds the alarm switches (not the app bar / outer layout).
        fun listScroller(r: android.view.accessibility.AccessibilityNodeInfo): android.view.accessibility.AccessibilityNodeInfo? {
            var sw: android.view.accessibility.AccessibilityNodeInfo? = null
            fun find(x: android.view.accessibility.AccessibilityNodeInfo) {
                if (sw != null) return
                if (x.isCheckable) { sw = x; return }
                for (k in 0 until x.childCount) x.getChild(k)?.let { find(it) }
            }
            find(r)
            val viaSwitch = sw?.let { generateSequence(it.parent) { p -> p.parent }.firstOrNull { p -> p.isScrollable } }
            if (viaSwitch != null) return viaSwitch
            return generateSequence(listOf(r)) { lvl -> lvl.flatMap { n -> (0 until n.childCount).mapNotNull { n.getChild(it) } }.ifEmpty { null } }
                .flatten().take(400).filter { it.isScrollable }
                .maxByOrNull { val b = android.graphics.Rect(); it.getBoundsInScreen(b); b.width().toLong() * b.height() }
        }
        // Start from the top of the list.
        s.rootInActiveWindow?.let { r -> listScroller(r)?.let { l -> repeat(10) { if (!l.performAction(A)) return@let; Thread.sleep(150) } } }
        Thread.sleep(300)
        fun label(n: android.view.accessibility.AccessibilityNodeInfo): String {
            val own = listOfNotNull(n.contentDescription?.toString(), n.text?.toString()).joinToString(" ")
            if (own.contains(timeLike)) return own
            // The switch's row: walk up and collect the row text.
            var p = n.parent
            repeat(3) {
                if (p == null) return own
                val sb = StringBuilder()
                fun walk(x: android.view.accessibility.AccessibilityNodeInfo, d: Int) {
                    if (d > 4) return
                    x.contentDescription?.let { sb.append(it).append(' ') }; x.text?.let { sb.append(it).append(' ') }
                    for (k in 0 until x.childCount) x.getChild(k)?.let { walk(it, d + 1) }
                }
                walk(p!!, 0)
                val t = sb.toString()
                if (t.contains(timeLike)) return t
                p = p!!.parent
            }
            return own
        }
        val turnedOff = mutableListOf<String>(); val alreadyOff = mutableListOf<String>(); val seen = HashSet<String>()
        for (page in 0 until 8) {
            val r = s.rootInActiveWindow ?: break
            if (r.packageName?.toString() != pkg) break
            val switches = mutableListOf<android.view.accessibility.AccessibilityNodeInfo>()
            fun collect(x: android.view.accessibility.AccessibilityNodeInfo) {
                if (x.isCheckable && x.isVisibleToUser) switches.add(x)
                for (k in 0 until x.childCount) x.getChild(k)?.let { collect(it) }
            }
            collect(r)
            for (sw in switches) {
                val l = label(sw).trim()
                val key = Regex("""\d{1,2}(?:[:.]\d\d)?\s*[ap]\.?\s*m\b|\d{1,2}[:.]\d\d""", RegexOption.IGNORE_CASE).find(l)?.value ?: continue
                if (timeRx != null && !timeRx.containsMatchIn(l)) continue
                if (!seen.add(l)) continue
                if (!sw.isChecked) { alreadyOff.add(key); continue }
                val target = if (sw.isClickable) sw else generateSequence(sw.parent) { it.parent }.firstOrNull { it.isClickable }
                if (target?.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK) == true) turnedOff.add(key)
            }
            if (timeRx != null && turnedOff.isNotEmpty()) break
            val before = seen.size
            if (listScroller(r)?.performAction(F) != true) break
            Thread.sleep(600)
            if (page > 0 && before == seen.size && switches.isEmpty()) break
        }
        Thread.sleep(400)
        return mapOf("ok" to true, "status" to "done", "turnedOff" to turnedOff, "alreadyOff" to alreadyOff.distinct().filter { it !in turnedOff })
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
