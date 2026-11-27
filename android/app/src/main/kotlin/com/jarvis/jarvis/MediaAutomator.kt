package com.jarvis.jarvis

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Plays media without any AI:
 *  1. Apps that support the standard "play from search" intent (YouTube Music, Spotify) start playback directly.
 *  2. YouTube: open search results for the query, then (if the accessibility service is on) tap the
 *     first real video result. Reports what actually happened.
 */
object MediaAutomator {
    const val YOUTUBE = "com.google.android.youtube"
    const val YT_MUSIC = "com.google.android.apps.youtube.music"
    const val SPOTIFY = "com.spotify.music"

    fun playFromSearch(ctx: Context, pkg: String, query: String): Boolean {
        val i = Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH)
            .setPackage(pkg)
            .putExtra(android.app.SearchManager.QUERY, query)
            .putExtra(MediaStore.EXTRA_MEDIA_FOCUS, "vnd.android.cursor.item/*")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (i.resolveActivity(ctx.packageManager) == null) return false
        return try { ctx.startActivity(i); true } catch (_: Exception) { false }
    }

    /**
     * Spotify / YouTube Music opened the search results but didn't start playing (e.g. free accounts):
     * tap the result row that best matches the query, preferring rows marked as a song.
     * Returns the tapped row's title, or null.
     */
    fun tapBestResult(pkg: String, query: String, waitMs: Long = 6000): String? {
        val svc = JarvisAccessibilityService.instance ?: return null
        val words = query.lowercase().split(Regex("[^a-z0-9]+")).filter { it.length > 1 }
        if (words.isEmpty()) return null
        val end = System.currentTimeMillis() + waitMs
        while (System.currentTimeMillis() < end) {
            Thread.sleep(400)
            val root = svc.rootFor(pkg) ?: continue
            var best: AccessibilityNodeInfo? = null; var bestScore = 0; var bestTitle: String? = null
            fun text(n: AccessibilityNodeInfo, d: Int = 0): String {
                if (d > 4) return ""
                val sb = StringBuilder()
                n.text?.let { sb.append(it).append(" | ") }; n.contentDescription?.let { sb.append(it).append(" | ") }
                for (k in 0 until n.childCount) n.getChild(k)?.let { sb.append(text(it, d + 1)) }
                return sb.toString()
            }
            fun visit(n: AccessibilityNodeInfo, d: Int) {
                if (d > 30) return
                if (n.isClickable && !n.isEditable && n.isVisibleToUser) {
                    val t = text(n)
                    val lt = t.lowercase()
                    val hits = words.count { lt.contains(it) }
                    // Chips ("Songs", "Albums") and the search box have no query words / are short.
                    if (hits > 0 && t.length > query.length + 4) {
                        var score = hits * 10
                        if (Regex("""\bsong\s*[•·]""").containsMatchIn(lt)) score += 8
                        if (Regex("""\b(playlist|podcast|episode|profile|artist)\s*[•·]""").containsMatchIn(lt)) score -= 6
                        if (score > bestScore) { bestScore = score; best = n; bestTitle = t.split(" | ").firstOrNull { it.isNotBlank() } }
                    }
                }
                for (k in 0 until n.childCount) n.getChild(k)?.let { visit(it, d + 1) }
            }
            visit(root, 0)
            val b = best
            if (b != null && b.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return bestTitle
        }
        return null
    }

    private fun openYouTubeSearch(ctx: Context, query: String): Boolean {
        val search = Intent(Intent.ACTION_SEARCH).setPackage(YOUTUBE).putExtra("query", query)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return try {
            ctx.startActivity(search); true
        } catch (_: Exception) {
            try {
                ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.youtube.com/results?search_query=${Uri.encode(query)}"))
                    .setPackage(YOUTUBE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                true
            } catch (_: Exception) { false }
        }
    }

    /** Returns status: playing | results_opened | failed (+ reason). Runs on a background thread. */
    fun playOnYouTube(ctx: Context, query: String): Map<String, Any?> {
        if (!openYouTubeSearch(ctx, query)) return mapOf("status" to "failed", "reason" to "YouTube could not be opened")
        val svc = JarvisAccessibilityService.instance
            ?: return mapOf("status" to "results_opened", "reason" to "Accessibility service off — tap a result to play")
        val end = System.currentTimeMillis() + 9000
        while (System.currentTimeMillis() < end) {
            Thread.sleep(400)
            val root = svc.rootFor(YOUTUBE) ?: continue
            val video = findVideoResult(root) ?: continue
            var c: AccessibilityNodeInfo? = video
            while (c != null && !c.isClickable) c = c.parent
            if (c != null && c.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                val title = video.contentDescription?.toString()?.substringBefore(" - ")?.substringBefore(" – ")
                return mapOf("status" to "playing", "title" to title)
            }
        }
        return mapOf("status" to "results_opened", "reason" to "Couldn't identify a video result to tap")
    }

    /** First search result that is a video (YouTube labels them "... play video"), skipping ads/shorts shelves. */
    private fun findVideoResult(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val stack = ArrayDeque<AccessibilityNodeInfo>()
        stack.add(root)
        var visited = 0
        while (stack.isNotEmpty() && visited < 4000) {
            val n = stack.removeFirst() // breadth-first → top-most result first
            visited++
            val d = n.contentDescription?.toString()?.lowercase() ?: ""
            if (d.contains("play video") && !d.contains("sponsored") && !d.startsWith("ad ")) return n
            for (i in 0 until n.childCount) n.getChild(i)?.let { stack.add(it) }
        }
        return null
    }
}
