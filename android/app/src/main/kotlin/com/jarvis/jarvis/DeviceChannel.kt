package com.jarvis.jarvis

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.ContactsContract
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Native device-control layer exposed to Dart. Every method receives a structured action; none of
 * them decides anything on its own (decisions + approvals happen in the Dart orchestrator).
 */
object DeviceChannel {
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var sink: EventChannel.EventSink? = null
    private lateinit var app: Context

    fun register(context: Context, engine: FlutterEngine) {
        app = context.applicationContext
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "jarvis/device").setMethodCallHandler { call, result -> handle(call, result) }
        EventChannel(messenger, "jarvis/mic_frames").setStreamHandler(MicStreamer)
        EventChannel(messenger, "jarvis/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
            override fun onCancel(arguments: Any?) { sink = null }
        })
    }

    fun emit(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val v = block()
                main.post { result.success(v) }
            } catch (e: Exception) {
                main.post { result.error("device_error", e.message, null) }
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getLaunchableApps" -> background(result) { launchableApps() }
            "launchApp" -> result.success(launchApp(call.argument<String>("package")!!))
            "isInstalled" -> result.success(isInstalled(call.argument<String>("package")!!))
            "searchContacts" -> background(result) { searchContacts(call.argument<String>("query") ?: "") }
            "accessibilityEnabled" -> result.success(accessibilityEnabled())
            "openAccessibilitySettings" -> { startSettings(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)); result.success(null) }
            "openAppSettings" -> {
                startSettings(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${app.packageName}")))
                result.success(null)
            }
            "isIgnoringBatteryOptimizations" -> {
                val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
                result.success(pm.isIgnoringBatteryOptimizations(app.packageName))
            }
            "requestIgnoreBatteryOptimizations" -> {
                startSettings(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${app.packageName}")))
                result.success(null)
            }
            "startListenerService" -> result.success(startListener())
            "stopListenerService" -> {
                app.stopService(Intent(app, JarvisListenerService::class.java))
                JarvisListenerService.running = false
                result.success(null)
            }
            "isListenerServiceRunning" -> result.success(JarvisListenerService.running)
            "updateServiceStatus" -> {
                if (JarvisListenerService.running) {
                    JarvisListenerService.status = call.argument<String>("text") ?: JarvisListenerService.status
                    JarvisListenerService.notify(app)
                }
                result.success(null)
            }
            "openWhatsAppChat" -> result.success(
                WhatsAppAutomator.openChat(app, call.argument("package")!!, call.argument("phone")!!, call.argument("text") ?: "")
            )
            "whatsappSend" -> background(result) {
                WhatsAppAutomator.send(
                    app,
                    pkg = call.argument("package")!!,
                    phone = call.argument("phone"),
                    searchName = call.argument("searchName"),
                    message = call.argument("message")!!,
                )
            }
            "whatsappCancel" -> { WhatsAppAutomator.cancelled = true; result.success(null) }
            "bringToFront" -> {
                try {
                    app.startActivity(Intent(app, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
                } catch (_: Exception) {}
                result.success(null)
            }
            "composeEmail" -> {
                val i = Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:"))
                    .putExtra(Intent.EXTRA_SUBJECT, call.argument<String>("subject") ?: "")
                    .putExtra(Intent.EXTRA_TEXT, call.argument<String>("body") ?: "")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                result.success(try { app.startActivity(i); true } catch (_: Exception) { false })
            }
            // ---------------- media (no AI)
            "playMedia" -> {
                val app = call.argument<String>("app") ?: "youtube"
                val q = call.argument<String>("query") ?: ""
                background(result) {
                    val (pkg, label) = when (app) {
                        "youtube_music" -> MediaAutomator.YT_MUSIC to "YouTube Music"
                        "spotify" -> MediaAutomator.SPOTIFY to "Spotify"
                        else -> MediaAutomator.YOUTUBE to "YouTube"
                    }
                    val launched: Map<String, Any?> = if (app == "youtube") MediaAutomator.playOnYouTube(app_, q)
                    else if (MediaAutomator.playFromSearch(app_, pkg, q)) mapOf("status" to "requested")
                    else mapOf("status" to "failed", "reason" to "$label is not installed")
                    if (launched["status"] == "failed" || launched["status"] == "results_opened") return@background launched
                    // Never claim playback on the app's word: confirm its media session is PLAYING.
                    var np = MediaBridge.waitForPlaying(app_, pkg, if (app == "youtube") 8000 else 5000)
                    if (np == null && app != "youtube" && MediaAutomator.tapBestResult(pkg, q) != null) {
                        // Results were shown but nothing played (free Spotify etc.): we tapped the best song row.
                        np = MediaBridge.waitForPlaying(app_, pkg, 7000)
                    }
                    if (np != null) launched + mapOf("status" to "playing", "title" to (np["title"] ?: launched["title"]))
                    else mapOf("status" to "results_opened",
                        "reason" to "$label opened, but playback did not start (it may need you to tap play or sign in)")
                }
            }
            // ---------------- process-scoped microphone
            "wakePopup" -> result.success(WakePopup.show(app))
            "micStart" -> result.success(MicStreamer.start())
            "micStop" -> { MicStreamer.stop(); result.success(null) }
            "micRunning" -> result.success(MicStreamer.isRunning)
            // ---------------- media control (no AI): via the playing app's media session
            "mediaControl" -> {
                val action = call.argument<String>("action") ?: ""
                val am = app.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
                when (action) {
                    "volume_up", "volume_down" -> {
                        val dir = if (action == "volume_up") android.media.AudioManager.ADJUST_RAISE else android.media.AudioManager.ADJUST_LOWER
                        repeat(2) { am.adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, dir, android.media.AudioManager.FLAG_SHOW_UI) }
                        result.success(mapOf("status" to "done"))
                    }
                    "mute" -> {
                        am.adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, android.media.AudioManager.ADJUST_MUTE, android.media.AudioManager.FLAG_SHOW_UI)
                        result.success(mapOf("status" to "done"))
                    }
                    else -> background(result) { MediaBridge.control(app, action) }
                }
            }
            "nowPlaying" -> background(result) { MediaBridge.nowPlaying(app) }
            // ---------------- on-device model (screen-agent brain, no key)
            "llmStatus" -> result.success(LocalLlm.status(app))
            "llmDownload" -> { LocalLlm.download(app); result.success(null) }
            "llmCancelDownload" -> { LocalLlm.cancel(); result.success(null) }
            "llmDelete" -> { LocalLlm.delete(app); result.success(null) }
            "llmCountTokens" -> background(result) { LocalLlm.countTokens(app, call.argument<String>("text") ?: "") }
            "llmGenerate" -> background(result) { LocalLlm.generate(app, call.argument<String>("prompt") ?: "") }
            "llmUnload" -> { LocalLlm.unload(); result.success(null) }
            // ---------------- generic screen control
            "screenDump" -> background(result) { ScreenAgent.dump(call.argument<Int>("max") ?: 70, call.argument<Boolean>("skipOwn") == true) }
            "screenText" -> background(result) { ScreenAgent.readText(call.argument<Boolean>("skipOwn") == true) }
            // ---------------- alarms / reminders / calls / files (local)
            "dismissAlarm" -> result.success(PhoneExtras.dismissAlarm(app, call.argument<String>("mode") ?: "next",
                call.argument<Int>("hour"), call.argument<Int>("minute"), call.argument<String>("label")))
            "clockSwitchOff" -> background(result) { PhoneExtras.clockSwitchOff(app, call.argument<Int>("hour"), call.argument<Int>("minute"),
                call.argument<Boolean>("ampmKnown") == true, call.argument<Boolean>("all") == true) }
            "snoozeAlarm" ->result.success(PhoneExtras.snoozeAlarm(app, call.argument<Int>("minutes")))
            "addReminder" -> result.success(PhoneExtras.addReminder(app, (call.argument<Number>("at")!!).toLong(), call.argument<String>("text")!!))
            "listReminders" -> result.success(PhoneExtras.listReminders(app))
            "deleteReminder" -> result.success(PhoneExtras.deleteReminder(app, call.argument<Int>("id")))
            "exactAlarmsAllowed" -> result.success(PhoneExtras.exactAlarmsAllowed(app))
            "openExactAlarmSettings" -> { PhoneExtras.openExactAlarmSettings(app); result.success(null) }
            "answerCall" -> result.success(PhoneExtras.answerCall(app))
            "endCall" -> result.success(PhoneExtras.endCall(app))
            "callState" -> result.success(PhoneExtras.callState(app))
            "allFilesAccess" -> result.success(PhoneExtras.allFilesAccess())
            "openAllFilesSettings" -> { PhoneExtras.openAllFilesSettings(app); result.success(null) }
            "findFiles" -> background(result) { PhoneExtras.findFiles(call.argument<String>("query") ?: "", call.argument<List<String>>("exts") ?: listOf("pdf")) }
            "openFile" -> result.success(PhoneExtras.openFile(app, call.argument<String>("path")!!))
            "screenAct" -> background(result) {
                ScreenAgent.act(app, call.argument<String>("type") ?: "", call.argument<Int>("index"),
                    call.argument<String>("text"), call.argument<String>("dir"), call.argument<String>("package"))
            }
            "overlayShow" -> { AgentOverlay.show(app); result.success(null) }
            "overlayUpdate" -> {
                AgentOverlay.update(call.argument<String>("title"), call.argument<String>("detail"),
                    ScreenAgent.boundsOf(call.argument<Int>("index")), call.argument<Boolean>("warn") == true)
                result.success(null)
            }
            "overlayHide" -> { AgentOverlay.hide(); result.success(null) }
            "isBlockedApp" -> result.success(ScreenAgent.isBlocked(call.argument<String>("package")))
            "quickToggle" -> background(result) { QuickToggles.set(call.argument<String>("kind") ?: "", call.argument<Boolean>("on") == true) }
            // ---------------- notification replies
            "replyTargets" -> result.success(JarvisNotificationListener.replyTargets(call.argument<String>("who") ?: ""))
            "notificationReply" -> result.success(JarvisNotificationListener.reply(app, call.argument<String>("key")!!, call.argument<String>("text")!!))
            // ---------------- everyday phone actions (no AI)
            "setAlarm" -> result.success(PhoneActions.setAlarm(app, call.argument("hour")!!, call.argument("minute")!!,
                call.argument("message"), call.argument("dayOfWeek")))
            "setTimer" -> result.success(PhoneActions.setTimer(app, call.argument("seconds")!!, call.argument("message")))
            "insertEvent" -> result.success(PhoneActions.insertEvent(app, call.argument("title")!!,
                (call.argument<Number>("begin")!!).toLong(), (call.argument<Number>("end")!!).toLong(),
                call.argument("description"), call.argument<List<String>>("emails") ?: emptyList()))
            "openUrl" -> result.success(PhoneActions.openUrl(app, call.argument("url")!!, call.argument("package")))
            "navigate" -> result.success(PhoneActions.navigate(app, call.argument("place")!!))
            "webSearch" -> result.success(PhoneActions.webSearch(app, call.argument("query")!!))
            "torch" -> result.success(PhoneActions.torch(app, call.argument<Boolean>("on") == true))
            "camera" -> result.success(PhoneActions.camera(app, call.argument<Boolean>("selfie") == true, call.argument<Boolean>("video") == true))
            "panel" -> result.success(PhoneActions.panel(app, call.argument("kind") ?: "settings"))
            "contactEmails" -> background(result) { PhoneActions.contactEmails(app, call.argument("name") ?: "") }
            // ---------------- sign-in help (each step only after the user's answer)
            "loginScan" -> background(result) { LoginAutomator.scan(call.argument("package")!!) }
            "loginChoose" -> background(result) { LoginAutomator.choose(call.argument("package")!!, call.argument("method")!!) }
            "loginAccounts" -> background(result) { LoginAutomator.accounts(call.argument("package")!!) }
            "loginPickAccount" -> background(result) { LoginAutomator.pickAccount(call.argument("package")!!, call.argument("email")!!) }
            "loginEnter" -> background(result) { LoginAutomator.enter(call.argument("package")!!, call.argument("value")!!) }
            "loginPasswordShowing" -> background(result) { LoginAutomator.passwordShowing(call.argument("package")!!) }
            "loginRelease" -> { LoginAutomator.release(); result.success(null) }
            "listenFocus" -> {
                if (call.argument<Boolean>("on") == true) MediaBridge.beginListening(app) else MediaBridge.endListening(app)
                result.success(null)
            }
            // ---------------- phone calls (no AI)
            "placeCall" -> {
                val number = call.argument<String>("number")!!
                val granted = ContextCompat.checkSelfPermission(app, android.Manifest.permission.CALL_PHONE) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED
                val i = Intent(if (granted) Intent.ACTION_CALL else Intent.ACTION_DIAL, Uri.parse("tel:${Uri.encode(number)}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                result.success(try { app.startActivity(i); if (granted) "calling" else "dialer_opened" } catch (e: Exception) { "failed:${e.message}" })
            }
            // ---------------- notifications (no AI)
            "notificationAccess" -> result.success(notificationAccessGranted())
            "openNotificationAccessSettings" -> {
                startSettings(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)); result.success(null)
            }
            "readNotifications" -> {
                val kinds = call.argument<List<String>>("kinds") ?: listOf("whatsapp", "email")
                val pkgs = HashSet<String>()
                if ("whatsapp" in kinds) pkgs += JarvisNotificationListener.WHATSAPP
                if ("email" in kinds) pkgs += JarvisNotificationListener.EMAIL
                if ("sms" in kinds) pkgs += setOf("com.samsung.android.messaging", "com.google.android.apps.messaging", "com.android.mms")
                result.success(JarvisNotificationListener.read(pkgs))
            }
            // ---------------- assistant role / half-screen panel
            "isDefaultAssistant" -> result.success(isDefaultAssistant())
            "openAssistantSettings" -> {
                try {
                    app.startActivity(Intent(Settings.ACTION_VOICE_INPUT_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } catch (_: Exception) {
                    startSettings(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS))
                }
                result.success(null)
            }
            "closeAssist" -> { assistActivity?.finish(); result.success(null) }
            "openFullApp" -> {
                assistActivity?.finish()
                app.startActivity(Intent(app, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    @Volatile var assistActivity: android.app.Activity? = null
    private val app_: Context get() = app

    private fun notificationAccessGranted(): Boolean {
        val flat = Settings.Secure.getString(app.contentResolver, "enabled_notification_listeners") ?: return false
        val me = ComponentName(app, JarvisNotificationListener::class.java)
        return flat.split(':').any { ComponentName.unflattenFromString(it) == me }
    }

    private fun isDefaultAssistant(): Boolean {
        val cur = Settings.Secure.getString(app.contentResolver, "voice_interaction_service") ?: return false
        return ComponentName.unflattenFromString(cur)?.packageName == app.packageName
    }

    private fun startSettings(i: Intent) {
        try { app.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (_: Exception) {
            app.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    private fun startListener(): Boolean {
        return try {
            ContextCompat.startForegroundService(app, Intent(app, JarvisListenerService::class.java))
            // startForeground runs asynchronously in the service; report the request was accepted.
            true
        } catch (e: Exception) {
            JarvisListenerService.lastError = e.message
            false
        }
    }

    // ------------------------------------------------------------------ apps
    private fun launchableApps(): List<Map<String, String>> {
        val pm = app.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val list = if (Build.VERSION.SDK_INT >= 33)
            pm.queryIntentActivities(intent, android.content.pm.PackageManager.ResolveInfoFlags.of(0))
        else @Suppress("DEPRECATION") pm.queryIntentActivities(intent, 0)
        return list
            .map { mapOf("label" to it.loadLabel(pm).toString(), "package" to it.activityInfo.packageName) }
            .filter { it["package"] != app.packageName }
            .distinctBy { it["package"] }
            .sortedBy { it["label"]?.lowercase() }
    }

    private fun isInstalled(pkg: String): Boolean = try {
        app.packageManager.getPackageInfo(pkg, 0); true
    } catch (_: Exception) { false }

    /** Starts the app's launcher activity. Returns false if Android refused. */
    private fun launchApp(pkg: String): Boolean {
        val i = app.packageManager.getLaunchIntentForPackage(pkg) ?: return false
        return try {
            app.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) { false }
    }

    // ------------------------------------------------------------------ contacts
    private fun searchContacts(query: String): List<Map<String, Any>> {
        if (query.isBlank()) return emptyList()
        if (ContextCompat.checkSelfPermission(app, android.Manifest.permission.READ_CONTACTS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED) return emptyList()
        val cr = app.contentResolver
        val byContact = LinkedHashMap<Long, Pair<String, LinkedHashSet<String>>>()
        cr.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            ),
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?",
            arrayOf("%${query.trim()}%"),
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC",
        )?.use { c ->
            while (c.moveToNext() && byContact.size < 20) {
                val id = c.getLong(0)
                val name = c.getString(1) ?: continue
                val num = c.getString(2) ?: continue
                val entry = byContact.getOrPut(id) { name to LinkedHashSet() }
                // De-duplicate numbers that differ only in formatting / country prefix.
                val key = num.filter { it.isDigit() }.takeLast(10)
                if (entry.second.none { it.filter { ch -> ch.isDigit() }.takeLast(10) == key }) entry.second.add(num.trim())
            }
        }
        val waContacts = HashSet<Long>()
        if (byContact.isNotEmpty()) {
            cr.query(
                ContactsContract.RawContacts.CONTENT_URI,
                arrayOf(ContactsContract.RawContacts.CONTACT_ID),
                "${ContactsContract.RawContacts.ACCOUNT_TYPE} IN (?, ?) AND ${ContactsContract.RawContacts.CONTACT_ID} IN (${byContact.keys.joinToString(",")})",
                arrayOf("com.whatsapp", "com.whatsapp.w4b"),
                null,
            )?.use { c -> while (c.moveToNext()) waContacts.add(c.getLong(0)) }
        }
        return byContact.map { (id, v) ->
            mapOf("name" to v.first, "numbers" to v.second.toList(), "whatsapp" to waContacts.contains(id))
        }
    }

    // ------------------------------------------------------------------ accessibility
    fun accessibilityEnabled(): Boolean {
        val enabled = Settings.Secure.getString(app.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val me = ComponentName(app, JarvisAccessibilityService::class.java)
        val listed = enabled.split(':').any { ComponentName.unflattenFromString(it) == me }
        return listed && JarvisAccessibilityService.instance != null
    }
}
