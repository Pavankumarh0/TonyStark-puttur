package com.jarvis.jarvis

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo
import java.net.URLEncoder

/**
 * Executes an ALREADY-APPROVED WhatsApp send and reports what actually happened.
 *
 * Contact with phone number: deep link opens the chat with the text pre-filled → tap Send.
 * Group / name only: open WhatsApp → search → open the single exact match → type → tap Send.
 * Verification: after tapping Send, the input box must be empty and the text must appear in the
 * conversation. Result statuses: verified | sent_unverified | failed | cancelled | ambiguous.
 *
 * WhatsApp's view ids are not a public API and can change with app updates; every lookup has a
 * fallback (content description / class name) and failures are reported, never hidden.
 */
object WhatsAppAutomator {
    @Volatile var cancelled = false

    private class Cancelled : Exception()

    fun openChat(ctx: Context, pkg: String, phone: String, text: String): Boolean {
        val digits = normalizePhone(phone)
        val uri = Uri.parse("https://api.whatsapp.com/send?phone=$digits&text=${URLEncoder.encode(text, "UTF-8").replace("+", "%20")}")
        return try {
            ctx.startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage(pkg).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) { false }
    }

    /** Indian numbers are often stored without a country code; WhatsApp needs one. */
    fun normalizePhone(raw: String): String {
        val plus = raw.trim().startsWith("+")
        var d = raw.filter { it.isDigit() }
        if (plus) return d
        if (d.startsWith("00")) return d.substring(2)
        if (d.length == 11 && d.startsWith("0")) d = d.substring(1)
        if (d.length == 10) d = "91$d"
        return d
    }

    fun send(ctx: Context, pkg: String, phone: String?, searchName: String?, message: String): Map<String, Any?> {
        cancelled = false
        val trace = mutableListOf<String>()
        fun result(status: String, reason: String? = null, chat: String? = null, candidates: List<String> = emptyList()) =
            mapOf("status" to status, "reason" to reason, "chatTitle" to chat, "candidates" to candidates, "trace" to trace)

        val svc = JarvisAccessibilityService.instance
            ?: return result("failed", "The LEO accessibility service is not running")
        try {
            var chatTitle: String? = null
            if (phone != null) {
                trace += "open chat via deep link"
                if (!openChat(ctx, pkg, phone, message)) return result("failed", "Could not open the chat")
                val entry = waitFor(svc, pkg, 9000) { root -> entryField(root, pkg)?.takeIf { (it.text?.toString() ?: "").isNotEmpty() } }
                    ?: return result("failed", "The chat did not open with the message (is this number on WhatsApp?)")
                trace += "chat open, text pre-filled"
                chatTitle = svc.rootFor(pkg)?.let { chatName(it, pkg) }
                if ((entry.text?.toString() ?: "").trim() != message.trim()) {
                    // Pre-fill differs (e.g. old draft in the box) — replace with exactly the approved text.
                    setText(entry, message)
                    trace += "replaced pre-filled text with approved text"
                }
            } else {
                val name = searchName ?: return result("failed", "No recipient")
                trace += "open $pkg"
                val launch = ctx.packageManager.getLaunchIntentForPackage(pkg) ?: return result("failed", "WhatsApp is not installed")
                ctx.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
                val search = waitFor(svc, pkg, 9000) { root -> searchButton(root, pkg) }
                    ?: return result("failed", "Could not find WhatsApp's search button")
                checkCancel()
                click(search)
                trace += "search opened"
                val input = waitFor(svc, pkg, 5000) { root -> findFirst(root) { it.className == "android.widget.EditText" && it.isEditable } }
                    ?: return result("failed", "Could not find WhatsApp's search box")
                setText(input, name)
                trace += "searched \"$name\""
                Thread.sleep(1600)
                checkCancel()
                val root = svc.rootFor(pkg) ?: return result("failed", "WhatsApp window lost")
                val rows = resultRows(root, pkg)
                val names = rows.map { it.first }.distinct()
                val exact = rows.filter { it.first.equals(name, ignoreCase = true) }
                val pick = when {
                    exact.size == 1 -> exact.first()
                    exact.size > 1 -> return result("ambiguous", "Several chats are named \"$name\"", candidates = names.take(6))
                    rows.size == 1 -> rows.first()
                    rows.isEmpty() -> return result("failed", "No chat named \"$name\" found in WhatsApp")
                    else -> return result("ambiguous", "Several chats match \"$name\"", candidates = names.take(6))
                }
                checkCancel()
                click(pick.second)
                trace += "opened chat \"${pick.first}\""
                val entry = waitFor(svc, pkg, 6000) { r -> entryField(r, pkg) }
                    ?: return result("failed", "The chat did not open")
                chatTitle = svc.rootFor(pkg)?.let { chatName(it, pkg) } ?: pick.first
                setText(entry, message)
                trace += "typed approved message"
            }

            // ---- last checkpoint before the irreversible action
            Thread.sleep(400)
            checkCancel()
            val root = svc.rootFor(pkg) ?: return result("failed", "WhatsApp window lost before sending", chatTitle)
            val entry = entryField(root, pkg)
            if (entry == null || (entry.text?.toString() ?: "").trim() != message.trim()) {
                return result("failed", "The text in WhatsApp's box did not match the approved message, so I did not send it", chatTitle)
            }
            val sendBtn = sendButton(root, pkg) ?: return result("failed", "Could not find the Send button", chatTitle)
            if (!click(sendBtn)) return result("failed", "Tapping Send did not work", chatTitle)
            trace += "send tapped"

            // ---- verify (no cancellation from here: the action already happened)
            val verified = waitFor(svc, pkg, 4000) { r ->
                val box = entryField(r, pkg)
                val boxEmpty = box == null || (box.text?.toString() ?: "").isEmpty() || box.text?.toString() == box.hintText?.toString()
                val bubble = findFirst(r) { n ->
                    n != box && (n.text?.toString()?.trim() == message.trim()) && !n.isEditable
                }
                if (boxEmpty && bubble != null) bubble else null
            }
            return if (verified != null) {
                trace += "message visible in chat"
                result("verified", chat = chatTitle)
            } else {
                result("sent_unverified", "Send was tapped but the message was not found in the chat view", chatTitle)
            }
        } catch (_: Cancelled) {
            return result("cancelled", "Stopped before sending")
        } catch (e: Exception) {
            return result("failed", e.message ?: e.javaClass.simpleName)
        }
    }

    // ---------------------------------------------------------------- helpers
    private fun checkCancel() { if (cancelled) throw Cancelled() }

    private fun <T> waitFor(svc: JarvisAccessibilityService, pkg: String, timeoutMs: Long, probe: (AccessibilityNodeInfo) -> T?): T? {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            checkCancel()
            svc.rootFor(pkg)?.let { root -> probe(root)?.let { return it } }
            Thread.sleep(250)
        }
        return null
    }

    private fun byId(root: AccessibilityNodeInfo, pkg: String, id: String): AccessibilityNodeInfo? =
        root.findAccessibilityNodeInfosByViewId("$pkg:id/$id")?.firstOrNull()

    private fun entryField(root: AccessibilityNodeInfo, pkg: String): AccessibilityNodeInfo? =
        byId(root, pkg, "entry") ?: findFirst(root) {
            it.isEditable && (it.hintText?.toString()?.contains("Message", ignoreCase = true) == true)
        }

    private fun sendButton(root: AccessibilityNodeInfo, pkg: String): AccessibilityNodeInfo? =
        byId(root, pkg, "send") ?: findFirst(root) {
            it.contentDescription?.toString()?.equals("Send", ignoreCase = true) == true
        }

    private fun searchButton(root: AccessibilityNodeInfo, pkg: String): AccessibilityNodeInfo? =
        byId(root, pkg, "menuitem_search")
            ?: byId(root, pkg, "my_search_bar")
            ?: byId(root, pkg, "search_bar")
            ?: findFirst(root) {
                (it.contentDescription?.toString()?.equals("Search", ignoreCase = true) == true) ||
                    (it.viewIdResourceName?.contains("search", ignoreCase = true) == true && it.isClickable)
            }

    private fun chatName(root: AccessibilityNodeInfo, pkg: String): String? =
        byId(root, pkg, "conversation_contact_name")?.text?.toString()

    /** Search result rows: (display name, clickable node). */
    private fun resultRows(root: AccessibilityNodeInfo, pkg: String): List<Pair<String, AccessibilityNodeInfo>> {
        val names = root.findAccessibilityNodeInfosByViewId("$pkg:id/conversations_row_contact_name").orEmpty() +
            root.findAccessibilityNodeInfosByViewId("$pkg:id/contactpicker_row_name").orEmpty()
        return names.mapNotNull { n ->
            val text = n.text?.toString()?.trim() ?: return@mapNotNull null
            var c: AccessibilityNodeInfo? = n
            while (c != null && !c.isClickable) c = c.parent
            c?.let { text to it }
        }
    }

    private fun findFirst(root: AccessibilityNodeInfo, pred: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(root)
        var visited = 0
        while (stack.isNotEmpty() && visited < 3000) {
            val n = stack.removeLast()
            visited++
            if (pred(n)) return n
            for (i in 0 until n.childCount) n.getChild(i)?.let { stack.add(it) }
        }
        return null
    }

    private fun click(node: AccessibilityNodeInfo): Boolean {
        var c: AccessibilityNodeInfo? = node
        while (c != null) {
            if (c.isClickable) return c.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            c = c.parent
        }
        return false
    }

    private fun setText(node: AccessibilityNodeInfo, text: String): Boolean {
        node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        val args = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text) }
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }
}
