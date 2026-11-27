package com.jarvis.jarvis

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Accessibility service used ONLY to execute approved WhatsApp actions. It never acts on its own;
 * [WhatsAppAutomator] drives it when the Dart orchestrator calls whatsappSend after approval.
 * Scope is restricted to com.whatsapp / com.whatsapp.w4b in accessibility_config.xml.
 */
class JarvisAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Passive: we read the window tree on demand instead of reacting to events.
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    private var basePackages: Array<String>? = null

    /**
     * Temporarily lets the service see [extra] apps (e.g. the app being signed into + Google's
     * account picker). Pass an empty set to go back to the default WhatsApp/YouTube scope.
     */
    fun allowExtraPackages(extra: Set<String>) {
        val info = serviceInfo ?: return
        if (basePackages == null) basePackages = info.packageNames ?: emptyArray()
        // Full-access mode (no package filter): nothing to widen — and setting a list would NARROW it.
        if (basePackages!!.isEmpty()) return
        info.packageNames = (basePackages!!.toSet() + extra).toTypedArray()
        serviceInfo = info
    }

    /** Root node of the foreground window belonging to [pkg], or null. */
    fun rootFor(pkg: String): AccessibilityNodeInfo? {
        rootInActiveWindow?.let { if (it.packageName?.toString() == pkg) return it }
        return try {
            windows.firstNotNullOfOrNull { w -> w.root?.takeIf { it.packageName?.toString() == pkg } }
        } catch (_: Exception) { null }
    }

    companion object {
        @Volatile var instance: JarvisAccessibilityService? = null
            get() {
                // The system can unbind/rebind the service for a moment (other a11y tools, UI testing,
                // settings changes). Off the main thread, wait briefly instead of failing the task.
                if (field == null && android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) {
                    val end = System.currentTimeMillis() + 3000
                    while (field == null && System.currentTimeMillis() < end) Thread.sleep(100)
                }
                return field
            }
    }
}
