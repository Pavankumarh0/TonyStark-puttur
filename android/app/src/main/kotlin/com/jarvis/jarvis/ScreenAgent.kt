package com.jarvis.jarvis

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Generic phone control: reads the current screen as a compact, numbered list of elements and
 * performs one action at a time (tap / type / scroll / back / home / open app …).
 * The planner (Dart) decides the steps; this layer only executes and reports.
 * Password fields are masked and never typed into. Payment/banking apps are refused.
 */
object ScreenAgent {
    private var lastNodes: List<AccessibilityNodeInfo> = emptyList()

    /** Apps LEO refuses to operate automatically (money / credentials). */
    private val BLOCKED = listOf(
        "bank", "upi", "paisa", "phonepe", "paytm", "bhim", "mobikwik", "cred", "groww", "zerodha", "kite",
        "wallet", "pay", "sbi", "hdfc", "icici", "axis", "kotak", "yono", "lastpass", "bitwarden", "1password",
        "authenticator", "keychain", "password",
    )

    fun isBlocked(pkg: String?): Boolean {
        val p = pkg?.lowercase() ?: return false
        if (p.startsWith("com.jarvis")) return false
        return BLOCKED.any { p.contains(it) }
    }

    private fun svc() = JarvisAccessibilityService.instance

    /** Numbered list of visible elements on the active window. */
    /**
     * Root of the app the user is looking at. With [skipOwn], LEO's own windows (e.g. the assistant
     * panel floating on top) are skipped so we read the app underneath.
     */
    private fun targetRoot(s: JarvisAccessibilityService, skipOwn: Boolean): AccessibilityNodeInfo? {
        val active = s.rootInActiveWindow
        if (!skipOwn || active?.packageName?.toString()?.startsWith("com.jarvis") != true) return active
        return try {
            s.windows
                .filter { it.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_APPLICATION }
                .sortedByDescending { it.layer }
                .mapNotNull { it.root }
                .firstOrNull { it.packageName?.toString()?.startsWith("com.jarvis") == false }
        } catch (_: Exception) { null }
    }

    /** Visible text of the current app, in reading order (for "read this" / screen context). */
    fun readText(skipOwn: Boolean, max: Int = 60): Map<String, Any?> {
        val s = svc() ?: return mapOf("ok" to false, "reason" to "accessibility_off")
        val root = targetRoot(s, skipOwn) ?: return mapOf("ok" to false, "reason" to "no_window")
        val pkg = root.packageName?.toString()
        if (isBlocked(pkg)) return mapOf("ok" to false, "reason" to "blocked_app", "package" to pkg)
        fun collect(r: AccessibilityNodeInfo): List<String> {
            val out = LinkedHashSet<String>()
            val stack = ArrayDeque<AccessibilityNodeInfo>().apply { add(r) }
            var visited = 0
            // Depth-first = reading order (a paragraph's pieces stay together).
            while (stack.isNotEmpty() && out.size < max && visited < 5000) {
                val n = stack.removeLast(); visited++
                if (n.isVisibleToUser && !n.isPassword && !n.isEditable) {
                    // Web pages often carry their text as a description instead of text.
                    val t = (n.text?.toString()?.trim()?.takeIf { it.isNotEmpty() }
                        // (not for buttons — "Refresh", "Bookmarks" aren't content)
                        ?: n.contentDescription?.toString()?.trim().takeIf { n.childCount == 0 && !n.isClickable } ?: "").trim()
                    val isUrlBar = n.viewIdResourceName?.contains("url", ignoreCase = true) == true ||
                        n.viewIdResourceName?.contains("location_bar", ignoreCase = true) == true
                    if (t.length > 1 && !isUrlBar) out += t.take(300)
                }
                for (i in n.childCount - 1 downTo 0) n.getChild(i)?.let { stack.addLast(it) }
            }
            return out.toList()
        }
        var lines = collect(root)
        if (lines.size < 3) {
            // Browsers build the page's accessibility tree lazily on first request — give it a moment.
            Thread.sleep(700)
            (targetRoot(s, skipOwn) ?: root).let { r -> r.refresh(); lines = collect(r) }
        }
        return mapOf("ok" to true, "package" to pkg, "lines" to lines)
    }

    fun dump(maxNodes: Int = 70, skipOwn: Boolean = false): Map<String, Any?> {
        val s = svc() ?: return mapOf("ok" to false, "reason" to "accessibility_off")
        val root = targetRoot(s, skipOwn) ?: return mapOf("ok" to false, "reason" to "no_window")
        val pkg = root.packageName?.toString()
        if (isBlocked(pkg)) return mapOf("ok" to false, "reason" to "blocked_app", "package" to pkg)
        val nodes = mutableListOf<AccessibilityNodeInfo>()
        val lines = StringBuilder()
        val stack = ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        var visited = 0
        val r = Rect()
        while (stack.isNotEmpty() && nodes.size < maxNodes && visited < 4000) {
            val n = stack.removeFirst(); visited++
            n.getBoundsInScreen(r)
            if (!n.isVisibleToUser || r.width() <= 0 || r.height() <= 0) {
                for (i in 0 until n.childCount) n.getChild(i)?.let { stack.add(it) }
                continue
            }
            val text = if (n.isPassword) "••••" else (n.text?.toString() ?: "").trim()
            val desc = (n.contentDescription?.toString() ?: "").trim()
            val hint = (n.hintText?.toString() ?: "").trim()
            val interesting = n.isClickable || n.isEditable || n.isScrollable || n.isCheckable || text.isNotEmpty() || desc.isNotEmpty()
            if (interesting) {
                val label = listOf(text, desc.takeIf { it != text }, hint.takeIf { n.isEditable && it.isNotEmpty() }?.let { "hint: $it" })
                    .filterNotNull().filter { it.isNotEmpty() }.joinToString(" | ").take(70)
                val kind = (n.className?.toString() ?: "").substringAfterLast('.').replace("AppCompat", "")
                val flags = buildList {
                    if (n.isClickable || n.isLongClickable) add("tap")
                    if (n.isEditable) add(if (n.isPassword) "password" else "input")
                    if (n.isScrollable) add("scroll")
                    if (n.isCheckable) add(if (n.isChecked) "on" else "off")
                    if (n.isSelected) add("selected")
                    if (!n.isEnabled) add("disabled")
                }.joinToString(",")
                if (label.isNotEmpty() || n.isEditable || n.isScrollable) {
                    lines.append("[${nodes.size}] $kind \"$label\" ($flags)\n")
                    nodes += n
                }
            }
            for (i in 0 until n.childCount) n.getChild(i)?.let { stack.add(it) }
        }
        lastNodes = nodes
        return mapOf("ok" to true, "package" to pkg, "screen" to lines.toString(), "count" to nodes.size)
    }

    /** Screen bounds [l,t,r,b] of element [index] from the last dump (for the overlay highlight). */
    /**
     * Unlabelled send buttons (ChatGPT and many chat apps): searches the WHOLE window (not just the
     * last dump, which may stop before the composer) for the right-most pressable element beside or
     * just below the text box [inputIndex], and taps it with a real finger-style tap.
     * Returns {ok, bounds} for logging.
     */
    fun tapSendNear(inputIndex: Int): Map<String, Any?> {
        val s = svc() ?: return mapOf("ok" to false, "reason" to "accessibility_off")
        val input = lastNodes.getOrNull(inputIndex) ?: return mapOf("ok" to false, "reason" to "no_input")
        input.refresh()
        val ib = Rect(); input.getBoundsInScreen(ib)
        val root = s.rootInActiveWindow ?: return mapOf("ok" to false, "reason" to "no_window")
        val band = (ib.height() * 1.6).toInt().coerceAtLeast(160)
        var best: AccessibilityNodeInfo? = null; val bb = Rect()
        val q = ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        var seen = 0
        while (q.isNotEmpty() && seen < 4000) {
            val n = q.removeFirst(); seen++
            for (i in 0 until n.childCount) n.getChild(i)?.let { q.add(it) }
            if (!n.isClickable || n.isEditable || !n.isVisibleToUser) continue
            val r = Rect(); n.getBoundsInScreen(r)
            if (r.width() <= 0 || r.height() > ib.height() * 2 + 40 || r.width() > ib.width() / 2) continue
            if (r.centerY() < ib.top - band / 2 || r.centerY() > ib.bottom + band) continue
            if (r.centerX() < ib.left + ib.width() / 2) continue
            if (best == null || r.right > bb.right + 8 || (kotlin.math.abs(r.right - bb.right) <= 8 && r.centerY() > bb.centerY())) {
                best = n; bb.set(r)
            }
        }
        val b = best ?: return mapOf("ok" to false, "reason" to "no_button", "input" to ib.toShortString())
        val ok = tapAt(s, b)
        android.util.Log.i("LEO", "tapSendNear input=${ib.toShortString()} button=${bb.toShortString()} ok=$ok")
        Thread.sleep(700)
        return mapOf("ok" to ok, "bounds" to bb.toShortString())
    }

    /**
     * Shopping results: taps the [target] button (e.g. "Add to cart") that belongs to the card showing
     * [anchor] (e.g. the price "₹150") — the nearest match below the anchor, overlapping it horizontally.
     * With tap=false it only reports that button's current label (e.g. "1 in cart") for verification.
     * Reads the app under LEO's panel. Returns {ok, label, reason?}.
     */
    fun tapBelow(anchor: String, target: String, tap: Boolean): Map<String, Any?> {
        val s = svc() ?: return mapOf("ok" to false, "reason" to "accessibility_off")
        val root = targetRoot(s, true) ?: return mapOf("ok" to false, "reason" to "no_window")
        if (isBlocked(root.packageName?.toString())) return mapOf("ok" to false, "reason" to "blocked_app")
        val targetRe = Regex(target, RegexOption.IGNORE_CASE)
        val norm = { t: String -> t.replace(Regex("[\\s,]"), "") }
        val want = norm(anchor)
        val anchors = mutableListOf<Rect>()
        val targets = mutableListOf<Pair<AccessibilityNodeInfo, Rect>>()
        val q = ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        var seen = 0
        while (q.isNotEmpty() && seen < 5000) {
            val n = q.removeFirst(); seen++
            for (i in 0 until n.childCount) n.getChild(i)?.let { q.add(it) }
            if (!n.isVisibleToUser) continue
            val label = listOfNotNull(n.text?.toString(), n.contentDescription?.toString()).joinToString(" ").trim()
            if (label.isEmpty()) continue
            val r = Rect(); n.getBoundsInScreen(r)
            if (r.width() <= 0 || r.height() <= 0) continue
            // The price on its own ("₹150", "₹150.00") — not "M.R.P: ₹1500".
            if (Regex("^" + Regex.escape(want) + "(\\.\\d+)?$").matches(norm(label))) anchors += r
            if (targetRe.containsMatchIn(label)) targets += n to r
        }
        if (anchors.isEmpty()) return mapOf("ok" to false, "reason" to "anchor_not_found")
        var best: Pair<AccessibilityNodeInfo, Rect>? = null
        var bestGap = Int.MAX_VALUE
        for (a in anchors) for (t in targets) {
            val gap = t.second.top - a.bottom
            val overlaps = t.second.right > a.left && t.second.left < a.right + a.width() * 4
            if (gap >= -a.height() && gap < bestGap && overlaps) { best = t; bestGap = gap }
        }
        val (node, rect) = best ?: return mapOf("ok" to false, "reason" to "target_not_found")
        val label = listOfNotNull(node.text?.toString(), node.contentDescription?.toString()).joinToString(" ").trim()
        if (!tap) return mapOf("ok" to true, "label" to label)
        val ok = (clickable(node)?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) || tapAt(s, node)
        android.util.Log.i("LEO", "tapBelow anchor=$anchor target=$label at=${rect.toShortString()} ok=$ok")
        return mapOf("ok" to ok, "label" to label)
    }

    fun boundsOf(index: Int?): IntArray? {
        val n = index?.let { lastNodes.getOrNull(it) } ?: return null
        n.refresh() // the screen may have moved since the dump (animations/scrolling)
        val r = Rect(); n.getBoundsInScreen(r)
        if (r.width() <= 0 || r.height() <= 0) return null
        return intArrayOf(r.left, r.top, r.right, r.bottom)
    }

    private fun clickable(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var c: AccessibilityNodeInfo? = n
        while (c != null && !c.isClickable) c = c.parent
        return c
    }

    private fun tapAt(s: AccessibilityService, n: AccessibilityNodeInfo, longPress: Boolean = false): Boolean {
        val r = Rect(); n.getBoundsInScreen(r)
        val p = Path().apply { moveTo(r.exactCenterX(), r.exactCenterY()) }
        val g = GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(p, 0, if (longPress) 700 else 60)).build()
        val latch = CountDownLatch(1)
        var ok = false
        s.dispatchGesture(g, object : AccessibilityService.GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) { ok = true; latch.countDown() }
            override fun onCancelled(gestureDescription: GestureDescription?) { latch.countDown() }
        }, null)
        latch.await(2, TimeUnit.SECONDS)
        return ok
    }

    private fun swipe(s: AccessibilityService, dir: String): Boolean {
        val dm = s.resources.displayMetrics
        val w = dm.widthPixels.toFloat(); val h = dm.heightPixels.toFloat()
        val (x1, y1, x2, y2) = when (dir) {
            "up" -> listOf(w / 2, h * 0.3f, w / 2, h * 0.75f)      // reveal content above
            "left" -> listOf(w * 0.2f, h / 2, w * 0.8f, h / 2)
            "right" -> listOf(w * 0.8f, h / 2, w * 0.2f, h / 2)
            else -> listOf(w / 2, h * 0.75f, w / 2, h * 0.3f)      // "down": reveal content below
        }
        val p = Path().apply { moveTo(x1, y1); lineTo(x2, y2) }
        val g = GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(p, 0, 350)).build()
        val latch = CountDownLatch(1)
        var ok = false
        s.dispatchGesture(g, object : AccessibilityService.GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) { ok = true; latch.countDown() }
            override fun onCancelled(gestureDescription: GestureDescription?) { latch.countDown() }
        }, null)
        latch.await(2, TimeUnit.SECONDS)
        return ok
    }

    /** Executes one action. Returns {ok, reason?}. */
    fun act(ctx: Context, type: String, index: Int?, text: String?, dir: String?, pkg: String?): Map<String, Any?> {
        val s = svc() ?: return mapOf("ok" to false, "reason" to "accessibility_off")
        val node = index?.let { lastNodes.getOrNull(it) }
        val activePkg = s.rootInActiveWindow?.packageName?.toString()
        if (isBlocked(activePkg)) return mapOf("ok" to false, "reason" to "blocked_app")
        val ok: Boolean = when (type) {
            "tap" -> {
                node ?: return mapOf("ok" to false, "reason" to "no_such_element")
                val c = clickable(node)
                (c?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) || tapAt(s, node)
            }
            // A real finger-style tap at the element's centre — for apps (e.g. ChatGPT) whose buttons
            // accept the accessibility "click" but ignore it.
            "tap_gesture" -> {
                node ?: return mapOf("ok" to false, "reason" to "no_such_element")
                node.refresh()
                tapAt(s, node)
            }
            "long_press" -> {
                node ?: return mapOf("ok" to false, "reason" to "no_such_element")
                val c = clickable(node)
                (c?.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK) == true) || tapAt(s, node, longPress = true)
            }
            "type" -> {
                val target = node ?: lastNodes.firstOrNull { it.isFocused && it.isEditable } ?: lastNodes.firstOrNull { it.isEditable }
                    ?: return mapOf("ok" to false, "reason" to "no_input_field")
                if (target.isPassword) return mapOf("ok" to false, "reason" to "password_field")
                target.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
                val args = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text ?: "") }
                target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            }
            "submit" -> {
                // IME "enter/search" on the focused field
                val target = node ?: lastNodes.firstOrNull { it.isFocused && it.isEditable } ?: lastNodes.firstOrNull { it.isEditable }
                target?.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id) == true
            }
            "scroll" -> {
                if (node != null && node.isScrollable) {
                    node.performAction(if (dir == "up") AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD else AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
                } else swipe(s, dir ?: "down")
            }
            "back" -> s.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
            "home" -> s.performGlobalAction(AccessibilityService.GLOBAL_ACTION_HOME)
            "recents" -> s.performGlobalAction(AccessibilityService.GLOBAL_ACTION_RECENTS)
            "notifications" -> s.performGlobalAction(AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS)
            "quick_settings" -> s.performGlobalAction(AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS)
            "open_app" -> {
                val p = pkg ?: return mapOf("ok" to false, "reason" to "no_package")
                if (isBlocked(p)) return mapOf("ok" to false, "reason" to "blocked_app")
                val i = ctx.packageManager.getLaunchIntentForPackage(p) ?: return mapOf("ok" to false, "reason" to "not_installed")
                try { ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true } catch (_: Exception) { false }
            }
            "wait" -> { Thread.sleep(1500); true }
            else -> return mapOf("ok" to false, "reason" to "unknown_action")
        }
        Thread.sleep(if (type == "open_app") 1800 else 900) // let the UI settle before the next look
        return mapOf("ok" to ok)
    }
}
