package com.jarvis.jarvis

import android.app.SearchManager
import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.net.Uri
import android.os.Build
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.MediaStore
import android.provider.Settings

/**
 * Standard Android app actions LEO performs locally (no AI): alarms, timers, calendar events,
 * Google Meet, navigation, web search, torch, camera, connectivity panels. Each returns
 * {ok, reason?, note?} describing what actually happened.
 */
object PhoneActions {
    private fun start(ctx: Context, i: Intent): Map<String, Any?> = try {
        ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); mapOf("ok" to true)
    } catch (e: Exception) { mapOf("ok" to false, "reason" to (e.message ?: "No app can do that")) }

    fun setAlarm(ctx: Context, hour: Int, minute: Int, message: String?, dayOfWeek: Int?): Map<String, Any?> {
        val i = Intent(AlarmClock.ACTION_SET_ALARM)
            .putExtra(AlarmClock.EXTRA_HOUR, hour)
            .putExtra(AlarmClock.EXTRA_MINUTES, minute)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        if (!message.isNullOrBlank()) i.putExtra(AlarmClock.EXTRA_MESSAGE, message)
        // Calendar.DAY_OF_WEEK (1=Sunday) — set when the alarm is for a specific later day.
        if (dayOfWeek != null) i.putExtra(AlarmClock.EXTRA_DAYS, arrayListOf(dayOfWeek))
        return start(ctx, i)
    }

    fun setTimer(ctx: Context, seconds: Int, message: String?): Map<String, Any?> {
        val i = Intent(AlarmClock.ACTION_SET_TIMER)
            .putExtra(AlarmClock.EXTRA_LENGTH, seconds)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        if (!message.isNullOrBlank()) i.putExtra(AlarmClock.EXTRA_MESSAGE, message)
        return start(ctx, i)
    }

    /** Opens the phone's calendar with the event pre-filled; the user taps Save. */
    fun insertEvent(ctx: Context, title: String, begin: Long, end: Long, description: String?, emails: List<String>): Map<String, Any?> {
        val i = Intent(Intent.ACTION_INSERT, CalendarContract.Events.CONTENT_URI)
            .putExtra(CalendarContract.Events.TITLE, title)
            .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, begin)
            .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, end)
        if (!description.isNullOrBlank()) i.putExtra(CalendarContract.Events.DESCRIPTION, description)
        if (emails.isNotEmpty()) i.putExtra(Intent.EXTRA_EMAIL, emails.joinToString(","))
        return start(ctx, i)
    }

    fun openUrl(ctx: Context, url: String, pkg: String? = null): Map<String, Any?> {
        val i = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        if (pkg != null) {
            i.setPackage(pkg)
            if (i.resolveActivity(ctx.packageManager) == null) i.setPackage(null)
        }
        return start(ctx, i)
    }

    fun navigate(ctx: Context, place: String): Map<String, Any?> {
        val nav = Intent(Intent.ACTION_VIEW, Uri.parse("google.navigation:q=${Uri.encode(place)}")).setPackage("com.google.android.apps.maps")
        if (nav.resolveActivity(ctx.packageManager) != null) return start(ctx, nav)
        return start(ctx, Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=${Uri.encode(place)}")))
    }

    fun webSearch(ctx: Context, query: String): Map<String, Any?> {
        val r = start(ctx, Intent(Intent.ACTION_WEB_SEARCH).putExtra(SearchManager.QUERY, query))
        if (r["ok"] == true) return r
        return openUrl(ctx, "https://www.google.com/search?q=${Uri.encode(query)}")
    }

    fun torch(ctx: Context, on: Boolean): Map<String, Any?> = try {
        val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = cm.cameraIdList.firstOrNull {
            cm.getCameraCharacteristics(it).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        } ?: return mapOf("ok" to false, "reason" to "This phone has no flashlight")
        cm.setTorchMode(id, on)
        mapOf("ok" to true)
    } catch (e: Exception) { mapOf("ok" to false, "reason" to (e.message ?: "The camera is in use")) }

    fun camera(ctx: Context, selfie: Boolean, video: Boolean): Map<String, Any?> {
        val i = Intent(if (video) MediaStore.INTENT_ACTION_VIDEO_CAMERA else MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA)
        if (selfie) {
            i.putExtra("android.intent.extras.CAMERA_FACING", 1)
            i.putExtra("android.intent.extras.LENS_FACING_FRONT", 1)
            i.putExtra("android.intent.extra.USE_FRONT_CAMERA", true)
        }
        return start(ctx, i)
    }

    /** Android 10+ does not let apps switch Wi-Fi/Bluetooth/data; we open the quick panel instead. */
    fun panel(ctx: Context, kind: String): Map<String, Any?> {
        val action = when (kind) {
            "wifi" -> if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_WIFI else Settings.ACTION_WIFI_SETTINGS
            "internet", "data" -> if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_INTERNET_CONNECTIVITY else Settings.ACTION_WIRELESS_SETTINGS
            "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
            "nfc" -> if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_NFC else Settings.ACTION_NFC_SETTINGS
            "volume" -> if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_VOLUME else Settings.ACTION_SOUND_SETTINGS
            "hotspot" -> "android.settings.TETHER_SETTINGS"
            "location" -> Settings.ACTION_LOCATION_SOURCE_SETTINGS
            "display", "brightness" -> Settings.ACTION_DISPLAY_SETTINGS
            "airplane" -> Settings.ACTION_AIRPLANE_MODE_SETTINGS
            else -> Settings.ACTION_SETTINGS
        }
        return start(ctx, Intent(action))
    }

    /** Email addresses saved for contacts matching [name] (for meeting invites). */
    fun contactEmails(ctx: Context, name: String): List<Map<String, String>> {
        if (androidx.core.content.ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.READ_CONTACTS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED) return emptyList()
        val out = mutableListOf<Map<String, String>>()
        ctx.contentResolver.query(
            ContactsContract.CommonDataKinds.Email.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY, ContactsContract.CommonDataKinds.Email.ADDRESS),
            "${ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY} LIKE ?", arrayOf("%${name.trim()}%"), null,
        )?.use { c ->
            while (c.moveToNext() && out.size < 10) {
                val n = c.getString(0) ?: continue
                val e = c.getString(1) ?: continue
                out += mapOf("name" to n, "email" to e)
            }
        }
        return out.distinctBy { it["email"] }
    }
}
