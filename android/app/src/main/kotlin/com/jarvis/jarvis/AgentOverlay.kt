package com.jarvis.jarvis

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Live "LEO is operating your phone" overlay, drawn above any app through the accessibility
 * service (TYPE_ACCESSIBILITY_OVERLAY — no extra permission): glowing screen border, a status card
 * (step, action, brain) with a STOP button, and a highlight box on the element about to be used.
 * The highlight and border never take touches; only the card's STOP button is clickable.
 */
object AgentOverlay {
    private val main = Handler(Looper.getMainLooper())
    private var root: FrameLayout? = null
    private var card: LinearLayout? = null
    private var title: TextView? = null
    private var detail: TextView? = null
    private var border: BorderView? = null

    private const val VOLT = 0xFF2EFF6E.toInt()
    private const val INK = 0xF204190C.toInt()
    private const val BONE = 0xFFE4FFEA.toInt()
    private const val MUTE = 0xFF7CB08E.toInt()
    private const val AMBER = 0xFFFFC857.toInt()

    private fun dp(ctx: Context, v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, ctx.resources.displayMetrics)

    /** Border + highlight: full screen, never touchable. */
    private class BorderView(ctx: Context) : View(ctx) {
        var highlight: RectF? = null
        var warn = false
        var phase = 0f
        private val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
        override fun onDraw(c: Canvas) {
            val color = if (warn) AMBER else VOLT
            val glow = (0.55f + 0.45f * kotlin.math.sin(phase)).coerceIn(0f, 1f)
            for (i in 0 until 4) {
                p.strokeWidth = (14 - i * 3).toFloat()
                p.color = Color.argb((40 + i * 45 * glow).toInt().coerceAtMost(255), Color.red(color), Color.green(color), Color.blue(color))
                val inset = p.strokeWidth / 2
                c.drawRoundRect(inset, inset, width - inset, height - inset, 60f, 60f, p)
            }
            highlight?.let { r ->
                p.strokeWidth = 6f
                p.color = color
                c.drawRoundRect(r, 24f, 24f, p)
                p.strokeWidth = 18f
                p.color = Color.argb((70 * glow).toInt(), Color.red(color), Color.green(color), Color.blue(color))
                c.drawRoundRect(r, 24f, 24f, p)
            }
            phase += 0.12f
            postInvalidateOnAnimation()
        }
    }

    fun show(ctx0: Context) = main.post {
        val svc = JarvisAccessibilityService.instance ?: return@post
        if (root != null) return@post
        val ctx: Context = svc
        val wm = svc.getSystemService(Context.WINDOW_SERVICE) as WindowManager

        // 1) Border + highlight layer (not touchable)
        val b = BorderView(ctx)
        wm.addView(b, WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT))
        border = b

        // 2) Status card with STOP (touchable, small)
        val c = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            val pad = dp(ctx, 12f).toInt()
            setPadding(pad, pad, pad, pad)
            background = GradientDrawable().apply {
                cornerRadius = dp(ctx, 28f); setColor(INK); setStroke(dp(ctx, 1.5f).toInt(), VOLT)
            }
            elevation = dp(ctx, 8f)
        }
        val dot = View(ctx).apply {
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(VOLT) }
            layoutParams = LinearLayout.LayoutParams(dp(ctx, 12f).toInt(), dp(ctx, 12f).toInt()).apply { marginEnd = dp(ctx, 10f).toInt() }
        }
        val texts = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
        val t = TextView(ctx).apply {
            setTextColor(VOLT); textSize = 10f; letterSpacing = 0.18f; typeface = android.graphics.Typeface.MONOSPACE
            text = "LEO · OPERATING YOUR PHONE"
        }
        val d = TextView(ctx).apply { setTextColor(BONE); textSize = 14f; maxLines = 2; text = "Starting…" }
        texts.addView(t); texts.addView(d)
        val stop = TextView(ctx).apply {
            text = "STOP"; setTextColor(Color.WHITE); textSize = 12f; letterSpacing = 0.15f
            typeface = android.graphics.Typeface.MONOSPACE
            val ph = dp(ctx, 14f).toInt(); val pv = dp(ctx, 8f).toInt()
            setPadding(ph, pv, ph, pv)
            background = GradientDrawable().apply { cornerRadius = dp(ctx, 20f); setColor(0xFFFF5A5F.toInt()) }
            setOnClickListener { DeviceChannel.emit(mapOf("type" to "notificationStop")) }
        }
        c.addView(dot)
        c.addView(texts, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        c.addView(stop)
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.BOTTOM
            val m = dp(ctx, 14f).toInt()
            x = 0; y = dp(ctx, 96f).toInt()
            horizontalMargin = 0f
            width = svc.resources.displayMetrics.widthPixels - 2 * m
        }
        wm.addView(c, lp)
        card = c; title = t; detail = d
        root = FrameLayout(ctx) // marker that the overlay is showing
    }

    /** Updates the card text and highlight (screen-pixel bounds, or null). */
    fun update(titleText: String?, detailText: String?, highlight: IntArray?, warn: Boolean) = main.post {
        titleText?.let { title?.text = it }
        detailText?.let { detail?.text = it }
        border?.apply {
            this.warn = warn
            this.highlight = highlight?.let { RectF(it[0].toFloat(), it[1].toFloat(), it[2].toFloat(), it[3].toFloat()) }
        }
        (card?.background as? GradientDrawable)?.setStroke(4, if (warn) AMBER else VOLT)
        title?.setTextColor(if (warn) AMBER else VOLT)
    }

    fun hide() = main.post {
        val svc = JarvisAccessibilityService.instance
        val wm = svc?.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        try { border?.let { wm?.removeView(it) } } catch (_: Exception) {}
        try { card?.let { wm?.removeView(it) } } catch (_: Exception) {}
        border = null; card = null; title = null; detail = null; root = null
    }
}
