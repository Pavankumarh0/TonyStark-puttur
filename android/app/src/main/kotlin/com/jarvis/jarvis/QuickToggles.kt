package com.jarvis.jarvis

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Turns system features on/off through the Quick Settings panel (what Android allows an
 * accessibility service to do — apps can't toggle Wi-Fi/Bluetooth/data directly).
 * Reads the tile's real state before and after, so the report is truthful.
 */
object QuickToggles {
    private val NAMES = mapOf(
        "wifi" to listOf("wi-fi", "wifi", "wi‑fi"),
        "bluetooth" to listOf("bluetooth"),
        "data" to listOf("mobile data", "data"),
        "hotspot" to listOf("mobile hotspot", "hotspot"),
        "airplane" to listOf("airplane mode", "flight mode", "aeroplane mode"),
        "location" to listOf("location"),
        "dnd" to listOf("do not disturb", "dnd"),
        "rotation" to listOf("auto rotate", "rotation", "portrait", "landscape"),
        "power_saving" to listOf("power saving", "battery saver"),
        "nfc" to listOf("nfc"),
        "flashlight" to listOf("flashlight", "torch"),
        "dark_mode" to listOf("dark mode"),
        "sound" to listOf("sound", "mute", "vibrate"),
    )

    /**
     * One UI tiles contain an outer button (whole pill → opens the detail page) and an inner icon
     * button (the actual on/off switch) with the same label. Pick the SMALLEST checkable match.
     */
    private fun findTile(root: AccessibilityNodeInfo, names: List<String>): AccessibilityNodeInfo? {
        val stack = ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        val candidates = mutableListOf<AccessibilityNodeInfo>()
        while (stack.isNotEmpty()) {
            val n = stack.removeFirst()
            val label = listOfNotNull(n.contentDescription?.toString(), n.text?.toString()).joinToString(" ").lowercase()
            if (label.isNotEmpty() && names.any { label.startsWith(it) || label.contains(", $it") || label == it || label.contains(it) }) {
                var c: AccessibilityNodeInfo? = n
                while (c != null && !c.isClickable) c = c.parent
                if (c != null) candidates += c
            }
            for (i in 0 until n.childCount) n.getChild(i)?.let { stack.add(it) }
        }
        fun area(x: AccessibilityNodeInfo): Int { val r = android.graphics.Rect(); x.getBoundsInScreen(r); return r.width() * r.height() }
        return candidates.filter { it.isCheckable }.minByOrNull { area(it) } ?: candidates.minByOrNull { area(it) }
    }

    /** null = unknown */
    private fun stateOf(n: AccessibilityNodeInfo): Boolean? {
        if (n.isCheckable) return n.isChecked
        val d = listOfNotNull(n.contentDescription?.toString(), n.stateDescription?.toString(), n.text?.toString())
            .joinToString(" ").lowercase()
        return when {
            Regex("\\b(on|enabled|connected)\\b").containsMatchIn(d) -> true
            Regex("\\b(off|disabled)\\b").containsMatchIn(d) -> false
            else -> null
        }
    }

    /** Returns {ok, status: already|changed|unknown|not_found, reason?} */
    fun set(kind: String, on: Boolean): Map<String, Any?> {
        val s = JarvisAccessibilityService.instance ?: return mapOf("ok" to false, "status" to "accessibility_off")
        val names = NAMES[kind] ?: return mapOf("ok" to false, "status" to "unsupported")
        s.allowExtraPackages(setOf("com.android.systemui"))
        try {
            s.performGlobalAction(AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS)
            var tile: AccessibilityNodeInfo? = null
            repeat(10) {
                Thread.sleep(300)
                val roots = try { s.windows.mapNotNull { it.root } } catch (_: Exception) { emptyList() } + listOfNotNull(s.rootInActiveWindow)
                tile = roots.firstNotNullOfOrNull { findTile(it, names) }
                if (tile != null) return@repeat
            }
            val t = tile ?: return mapOf("ok" to false, "status" to "not_found",
                "reason" to "I couldn't find that tile in Quick Settings (it may need adding via the panel's edit button)")
            val before = stateOf(t)
            if (before == on) return mapOf("ok" to true, "status" to "already")
            if (!t.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return mapOf("ok" to false, "status" to "tap_failed")
            Thread.sleep(900)
            t.refresh()
            val after = stateOf(t)
            return when (after) {
                on -> mapOf("ok" to true, "status" to "changed")
                null -> mapOf("ok" to true, "status" to "unknown")
                else -> mapOf("ok" to false, "status" to "unchanged",
                    "reason" to "The switch didn't change (Android may need you to confirm, e.g. airplane mode or hotspot)")
            }
        } finally {
            Thread.sleep(300)
            s.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK) // close the panel (once — a 2nd BACK could leave your app)
            s.allowExtraPackages(emptySet())
        }
    }
}
