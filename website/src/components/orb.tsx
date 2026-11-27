"use client";

import { useEffect, useRef } from "react";
import { motion, useInView } from "framer-motion";
import { cn, r3, seeded } from "@/lib/utils";

const BARS = 84;

/**
 * The LEO voice core: a glassy lime sphere with live sine waves inside, a radial
 * equalizer, expanding sound rings and two tilted 3D orbits that pass behind it.
 * Size is driven by the wrapper width; everything inside scales via container units.
 */
export function Orb({ className, pulseKey }: { className?: string; pulseKey?: number | string }) {
  return (
    <div className={cn("relative aspect-square [container-type:inline-size]", className)} aria-hidden>
      {/* Ambient glow */}
      <motion.div
        className="absolute -inset-[35%] rounded-full bg-[radial-gradient(circle,rgb(46_255_110/0.28)_0%,rgb(46_255_110/0.08)_38%,transparent_68%)]"
        animate={{ scale: [1, 1.1, 1], opacity: [0.75, 1, 0.75] }}
        transition={{ duration: 4.2, repeat: Infinity, ease: "easeInOut" }}
      />

      {/* Expanding sound-wave rings */}
      {[0, 1, 2].map((i) => (
        <span
          key={i}
          className="ping-ring absolute inset-[23%] rounded-full border border-volt/50"
          style={{ animationDelay: `${i * 1.2}s` }}
        />
      ))}

      {/* One-shot pulse whenever a new command lands */}
      {pulseKey !== undefined && (
        <motion.span
          key={pulseKey}
          className="absolute inset-[23%] rounded-full border-2 border-volt"
          initial={{ scale: 1, opacity: 0.9 }}
          animate={{ scale: 2.3, opacity: 0 }}
          transition={{ duration: 1.4, ease: [0.2, 0.7, 0.3, 1] }}
        />
      )}

      {/* Back halves of the orbits — sit behind the sphere */}
      <Orbits half="back" />

      {/* Radial equalizer */}
      <div className="absolute inset-0">
        {Array.from({ length: BARS }, (_, i) => {
          const angle = (i / BARS) * 360;
          const len = 2.5 + seeded(i) * 7.5;
          return (
            <span
              key={i}
              className="absolute left-1/2 top-1/2"
              style={{ transform: `rotate(${angle.toFixed(2)}deg) translateY(-30.5cqw)` }}
            >
              <span
                className="eq-out absolute bottom-0 -left-px block w-[2px] rounded-full bg-volt"
                style={{
                  height: `${len.toFixed(2)}cqw`,
                  opacity: r3(0.3 + seeded(i + 300) * 0.55),
                  animationDuration: `${r3(0.7 + seeded(i + 100) * 1.1)}s`,
                  animationDelay: `${r3(-seeded(i + 200) * 2)}s`,
                }}
              />
            </span>
          );
        })}
      </div>

      {/* Core sphere */}
      <motion.div
        className="absolute inset-[24%]"
        animate={{ scale: [1, 1.045, 0.99, 1.03, 1] }}
        transition={{ duration: 2.6, repeat: Infinity, ease: "easeInOut" }}
      >
        <OrbSphere className="absolute inset-0" />
      </motion.div>

      {/* Front halves of the orbits — pass in front of the sphere */}
      <Orbits half="front" />
    </div>
  );
}

/** Just the glass sphere — plasma swirl, inner sine waves, shading and specular. Inline-safe (spans only). */
export function OrbSphere({ className }: { className?: string }) {
  return (
    <span className={cn("orb-core block overflow-hidden rounded-full", className)} aria-hidden>
      <span className="orb-swirl absolute -inset-1/4 block" />
      <span className="orb-blob-a absolute left-[20%] top-[30%] block size-[60%] rounded-full bg-[#b4ffcb]/60 blur-2xl" />
      <span className="orb-blob-b absolute left-[10%] top-[10%] block size-[55%] rounded-full bg-volt/50 blur-2xl" />
      <OrbWaves />
      <span className="orb-shade absolute inset-0 block rounded-full" />
      <span className="absolute left-[19%] top-[11%] block h-[20%] w-[34%] -rotate-[28deg] rounded-full bg-white/35 blur-[6px]" />
    </span>
  );
}

/*
 * Each orbit is drawn twice with complementary masks: the far (top) half under the
 * sphere and the near (bottom) half over it, which fakes correct 3D occlusion.
 */
function Orbits({ half }: { half: "back" | "front" }) {
  const mask =
    half === "back"
      ? "linear-gradient(to bottom, #000 50%, transparent 50%)"
      : "linear-gradient(to bottom, transparent 50%, #000 50%)";

  const rings = [
    { tilt: "rotateX(76deg) rotateY(-14deg)", inset: "-6%", speed: "9s", reverse: false },
    { tilt: "rotateX(70deg) rotateY(24deg)", inset: "4%", speed: "13s", reverse: true },
  ];

  return (
    <div className="pointer-events-none absolute inset-0 [perspective:1100px]">
      {rings.map((r, i) => (
        <div
          key={i}
          className="absolute rounded-full border border-volt/15"
          style={{ inset: r.inset, transform: r.tilt, maskImage: mask, WebkitMaskImage: mask }}
        >
          <div
            className="absolute inset-0 animate-spin"
            style={{ animationDuration: r.speed, animationDirection: r.reverse ? "reverse" : "normal" }}
          >
            <span className="absolute left-1/2 top-0 size-[3.2cqw] -translate-x-1/2 -translate-y-1/2 rounded-full bg-volt shadow-[0_0_14px_3px_rgb(46_255_110/0.7)]" />
            {i === 0 && (
              <span className="absolute bottom-0 left-1/2 size-[1.8cqw] -translate-x-1/2 translate-y-1/2 rounded-full bg-volt shadow-[0_0_10px_rgb(228_255_234/0.8)]" />
            )}
          </div>
        </div>
      ))}
    </div>
  );
}

const WAVES = [
  { amp: 24, freq: 1.6, speed: 3.1, phase: 0, stroke: "rgb(255 255 255 / 0.75)", width: 1.6 },
  { amp: 18, freq: 2.3, speed: -2.4, phase: 1.7, stroke: "rgb(4 25 12 / 0.55)", width: 1.4 },
  { amp: 13, freq: 3.1, speed: 4.2, phase: 3.1, stroke: "rgb(180 255 210 / 0.7)", width: 1.1 },
];

/** Voice-like sine waves inside the sphere, redrawn per frame without React renders. */
function OrbWaves() {
  const svgRef = useRef<SVGSVGElement>(null);
  const pathRefs = useRef<(SVGPathElement | null)[]>([]);
  const inView = useInView(svgRef);

  useEffect(() => {
    if (!inView) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    const W = 200;
    const H = 100;
    const N = 64;
    const start = performance.now();
    let raf = 0;

    const frame = (now: number) => {
      const t = (now - start) / 1000;
      // Speech-like envelope: syllables rising and falling
      const env = 0.45 + 0.55 * Math.abs(Math.sin(t * 1.9) * Math.sin(t * 0.73 + 1.2));
      WAVES.forEach((w, k) => {
        let d = "";
        for (let i = 0; i <= N; i++) {
          const u = i / N;
          const taper = Math.sin(Math.PI * u) ** 2;
          const y = H / 2 + Math.sin(u * w.freq * Math.PI * 2 + t * w.speed + w.phase) * w.amp * taper * env;
          d += `${i ? "L" : "M"}${(u * W).toFixed(1)} ${y.toFixed(1)}`;
        }
        pathRefs.current[k]?.setAttribute("d", d);
      });
      raf = requestAnimationFrame(frame);
    };

    raf = requestAnimationFrame(frame);
    return () => cancelAnimationFrame(raf);
  }, [inView]);

  return (
    <svg
      ref={svgRef}
      viewBox="0 0 200 100"
      preserveAspectRatio="none"
      className="absolute left-[6%] top-1/2 h-[56%] w-[88%] -translate-y-1/2 mix-blend-overlay"
    >
      {WAVES.map((w, k) => (
        <path
          key={k}
          ref={(el) => {
            pathRefs.current[k] = el;
          }}
          d="M0 50L200 50"
          fill="none"
          stroke={w.stroke}
          strokeWidth={w.width}
          strokeLinecap="round"
          vectorEffect="non-scaling-stroke"
        />
      ))}
    </svg>
  );
}
