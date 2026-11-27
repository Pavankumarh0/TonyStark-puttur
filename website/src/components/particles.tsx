"use client";

import { useEffect, useRef } from "react";
import { cn } from "@/lib/utils";

type Particle = { x: number; y: number; r: number; vx: number; vy: number; a: number; tw: number; lime: boolean };

/** Slow-drifting dust motes on a canvas. Pauses off-screen; static under reduced motion. */
export function Particles({ count = 70, className }: { count?: number; className?: string }) {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = ref.current;
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx) return;

    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    let w = 0;
    let h = 0;
    let raf = 0;
    let visible = true;
    let t = 0;

    const spawn = (anywhere: boolean): Particle => ({
      x: Math.random() * w,
      y: anywhere ? Math.random() * h : h + 8,
      r: Math.random() * 1.5 + 0.4,
      vx: (Math.random() - 0.5) * 0.16,
      vy: -(Math.random() * 0.28 + 0.05),
      a: Math.random() * 0.5 + 0.15,
      tw: Math.random() * Math.PI * 2,
      lime: Math.random() < 0.8,
    });

    let particles: Particle[] = [];

    const draw = () => {
      ctx.clearRect(0, 0, w, h);
      t += 0.016;
      for (const p of particles) {
        if (!reduce) {
          p.x += p.vx;
          p.y += p.vy;
          if (p.y < -8 || p.x < -8 || p.x > w + 8) Object.assign(p, spawn(false));
        }
        const alpha = p.a * (0.6 + 0.4 * Math.sin(t * 2 + p.tw));
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
        ctx.fillStyle = p.lime ? `rgba(46,255,110,${alpha})` : `rgba(228,255,234,${alpha * 0.7})`;
        ctx.fill();
      }
    };

    const loop = () => {
      draw();
      if (visible && !reduce) raf = requestAnimationFrame(loop);
    };

    const resize = () => {
      const rect = canvas.getBoundingClientRect();
      w = rect.width;
      h = rect.height;
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      if (particles.length === 0) particles = Array.from({ length: count }, () => spawn(true));
      if (reduce) draw();
    };

    const ro = new ResizeObserver(resize);
    ro.observe(canvas);

    const io = new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      cancelAnimationFrame(raf);
      if (visible && !reduce) raf = requestAnimationFrame(loop);
    });
    io.observe(canvas);

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
      io.disconnect();
    };
  }, [count]);

  return <canvas ref={ref} aria-hidden className={cn("pointer-events-none absolute inset-0 size-full", className)} />;
}
