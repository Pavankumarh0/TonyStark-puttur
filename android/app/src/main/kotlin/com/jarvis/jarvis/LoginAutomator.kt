package com.jarvis.jarvis

import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Helps the user sign in to an app LEO opened — ONLY step by step with the user's answers:
 *  scan → (user agrees) → tap the method the user chose → list Google accounts → tap the account the
 *  user chose / type the phone number or OTP the user said. Never types or stores passwords.
 * Screen text matching is English-UI based; failures are reported, never guessed.
 */
object LoginAutomator {
    private const val GMS = "com.google.android.gms"
    private val EMAIL = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")

    private val LOGIN_WORDS = listOf("sign in", "log in", "login", "sign up", "continue with google",
        "continue with phone", "use phone number", "continue with email", "sign in with google")

    private fun svc() = JarvisAccessibilityService.instance

    /** Widen the accessibility scope to the app being signed into + Google's account picker. */
    fun allow(pkg: String) { svc()?.allowExtraPackages(setOf(pkg, GMS)) }
    fun release() { svc()?.allowExtraPackages(emptySet()) }

    private fun texts(root: AccessibilityNodeInfo): List<Pair<String, AccessibilityNodeInfo>> {
        val out = mutableListOf<Pair<String, AccessibilityNodeInfo>>()
        val stack = ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        var visited = 0
        while (stack.isNotEmpty() && visited < 3000) {
            val n = stack.removeFirst(); visited++
            val t = (n.text?.toString() ?: n.contentDescription?.toString())?.trim()
            if (!t.isNullOrEmpty()) out += t to n
            for (i in 0 until n.childCount) n.getChild(i)?.let { stack.add(it) }
        }
        return out
    }

    private fun anyRoot(pkgs: Set<String>): AccessibilityNodeInfo? {
        val s = svc() ?: return null
        for (p in pkgs) s.rootFor(p)?.let { return it }
        return null
    }

    /** {needsLogin, options:[google|phone|email], prompt} for the app's current screen. */
    fun scan(pkg: String, waitMs: Long = 4000): Map<String, Any?> {
        if (svc() == null) return mapOf("needsLogin" to false, "error" to "accessibility_off")
        allow(pkg)
        val end = System.currentTimeMillis() + waitMs
        while (System.currentTimeMillis() < end) {
            val root = anyRoot(setOf(pkg))
            if (root != null) {
                val all = texts(root)
                val lower = all.map { it.first.lowercase() }
                val needs = lower.any { t -> LOGIN_WORDS.any { t == it || t.startsWith(it) } }
                if (needs) {
                    val opts = mutableListOf<String>()
                    // Google-owned apps sign in with a Google account even when the button just says "Sign in".
                    if (lower.any { "google" in it } || pkg.startsWith("com.google.")) opts += "google"
                    if (lower.any { "phone" in it || "mobile number" in it }) opts += "phone"
                    if (lower.any { "email" in it && "google" !in it }) opts += "email"
                    if (opts.isEmpty()) opts += "google"
                    return mapOf("needsLogin" to true, "options" to opts.distinct())
                }
            }
            Thread.sleep(400)
        }
        return mapOf("needsLogin" to false)
    }

    private fun clickFirst(pkgs: Set<String>, vararg phrases: String): Boolean {
        val root = anyRoot(pkgs) ?: return false
        val all = texts(root)
        for (p in phrases) {
            val hit = all.firstOrNull { it.first.lowercase() == p } ?: all.firstOrNull { it.first.lowercase().contains(p) }
            if (hit != null) {
                var c: AccessibilityNodeInfo? = hit.second
                while (c != null && !c.isClickable) c = c.parent
                if (c != null && c.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
            }
        }
        return false
    }

    /** Taps the sign-in method the user chose. */
    fun choose(pkg: String, method: String): Map<String, Any?> {
        val ok = when (method) {
            "google" -> clickFirst(setOf(pkg), "continue with google", "sign in with google", "google", "sign in", "log in")
            "phone" -> clickFirst(setOf(pkg), "continue with phone", "use phone number", "phone number", "phone", "mobile number")
            "email" -> clickFirst(setOf(pkg), "continue with email", "use email", "email", "sign in", "log in")
            else -> false
        }
        return mapOf("ok" to ok)
    }

    /** Google accounts shown in the account chooser (read from screen; nothing is stored). */
    fun accounts(pkg: String, waitMs: Long = 7000): List<String> {
        val end = System.currentTimeMillis() + waitMs
        while (System.currentTimeMillis() < end) {
            val s = svc() ?: return emptyList()
            val roots = listOfNotNull(s.rootFor(GMS), s.rootFor(pkg), s.rootInActiveWindow)
            val found = roots.flatMap { r -> texts(r).mapNotNull { EMAIL.find(it.first)?.value } }.distinct()
            if (found.isNotEmpty()) return found
            Thread.sleep(400)
        }
        return emptyList()
    }

    fun pickAccount(pkg: String, email: String): Map<String, Any?> {
        val s = svc() ?: return mapOf("ok" to false)
        val roots = listOfNotNull(s.rootFor(GMS), s.rootFor(pkg), s.rootInActiveWindow)
        for (r in roots) {
            val hit = texts(r).firstOrNull { it.first.contains(email, ignoreCase = true) } ?: continue
            var c: AccessibilityNodeInfo? = hit.second
            while (c != null && !c.isClickable) c = c.parent
            if (c != null && c.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return mapOf("ok" to true)
        }
        return mapOf("ok" to false)
    }

    /**
     * Types [value] into the visible input field and presses the continue button.
     * Refuses password fields — the user types passwords themselves.
     */
    fun enter(pkg: String, value: String): Map<String, Any?> {
        val s = svc() ?: return mapOf("ok" to false, "reason" to "accessibility_off")
        val root = s.rootFor(pkg) ?: s.rootFor(GMS) ?: s.rootInActiveWindow ?: return mapOf("ok" to false, "reason" to "no_window")
        val fields = mutableListOf<AccessibilityNodeInfo>()
        val stack = ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        while (stack.isNotEmpty()) {
            val n = stack.removeFirst()
            if (n.isEditable) fields += n
            for (i in 0 until n.childCount) n.getChild(i)?.let { stack.add(it) }
        }
        val field = fields.firstOrNull { it.isFocused } ?: fields.firstOrNull { !it.isPassword } ?: return mapOf("ok" to false, "reason" to "no_field")
        if (field.isPassword) return mapOf("ok" to false, "reason" to "password_field")
        field.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        val args = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value) }
        if (!field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) return mapOf("ok" to false, "reason" to "set_text_failed")
        Thread.sleep(400)
        val pressed = clickFirst(setOf(pkg, GMS), "next", "continue", "send otp", "get otp", "send code", "verify", "submit", "sign in", "log in")
        return mapOf("ok" to true, "pressed" to pressed)
    }

    /** Is a password field showing? (LEO hands those to the user.) */
    fun passwordShowing(pkg: String): Boolean {
        val root = anyRoot(setOf(pkg, GMS)) ?: return false
        val stack = ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        while (stack.isNotEmpty()) {
            val n = stack.removeFirst()
            if (n.isPassword) return true
            for (i in 0 until n.childCount) n.getChild(i)?.let { stack.add(it) }
        }
        return false
    }
}
