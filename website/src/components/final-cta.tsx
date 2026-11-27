"use client";

import { useRef } from "react";
import { motion, useScroll, useTransform } from "framer-motion";
import { Mic } from "lucide-react";
import { EASE } from "@/components/ui/reveal";
import { PillLink } from "@/components/ui/pill-link";
import { RotatingBadge } from "@/components/ui/stickers";
import { r3, seeded } from "@/lib/utils";

export function FinalCta() {
  const ref = useRef<HTMLElement>(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start end", "end start"] });
  const x1 = useTransform(scrollYProgress, [0, 1], ["7%", "-5%"]);
  const x2 = useTransform(scrollYProgress, [0, 1], ["-7%", "4%"]);

  return (
    <section ref={ref} id="get-started" className="relative scroll-mt-20 px-4 py-16 sm:px-6 md:py-24 lg:px-10">
      <div className="mx-auto max-w-[1360px]">
        <motion.div
          initial={{ opacity: 0, y: 60, scale: 0.97 }}
          whileInView={{ opacity: 1, y: 0, scale: 1 }}
          viewport={{ once: true, margin: "0px 0px -10% 0px" }}
          transition={{ duration: 1, ease: EASE }}
          className="relative overflow-hidden rounded-[32px] bg-volt text-ink md:rounded-[44px]"
        >
          {/* Waveform floor */}
          <div className="pointer-events-none absolute inset-x-0 bottom-0 flex h-36 items-end gap-[6px] px-4 opacity-[0.1] md:h-48" aria-hidden>
            {Array.from({ length: 90 }, (_, i) => (
              <span
                key={i}
                className="eq-out flex-1 rounded-t-full bg-ink"
                style={{
                  height: `${r3(20 + seeded(i + 500) * 80)}%`,
                  animationDuration: `${r3(0.9 + seeded(i + 600) * 1.4)}s`,
                  animationDelay: `${r3(-seeded(i + 700) * 2)}s`,
                }}
              />
            ))}
          </div>

          <div className="relative px-6 pb-10 pt-10 md:px-12 md:pb-14 md:pt-14">
            <div className="flex items-start justify-between gap-6">
              <div className="flex items-center gap-3 font-mono text-xs uppercase tracking-[0.18em] text-ink/70">
                <span className="size-1.5 rounded-full bg-ink" />
                (04) Ready when you are
              </div>
              <RotatingBadge
                id="cta-badge"
                text="Free early access • Hands-free • "
                className="-mr-2 -mt-2 hidden size-28 bg-ink text-volt sm:grid md:size-32"
              >
                <span className="orb-mini grid size-11 place-items-center rounded-full">
                  <Mic className="size-4 text-ink" strokeWidth={2.6} />
                </span>
              </RotatingBadge>
            </div>

            <h2 className="mt-6 font-display text-[clamp(2.5rem,9.6vw,9.5rem)] font-bold uppercase leading-[0.85] tracking-[-0.06em] md:mt-2">
              <motion.span style={{ x: x1 }} className="block whitespace-nowrap">
                Stop{" "}
                <span className="relative inline-block">
                  <motion.span
                    className="inline-block"
                    initial={{ opacity: 1 }}
                    whileInView={{ opacity: 0.35 }}
                    viewport={{ once: true, amount: 0.8 }}
                    transition={{ delay: 1.1, duration: 0.6 }}
                  >
                    tapping.
                  </motion.span>
                  <motion.span
                    aria-hidden
                    className="absolute left-[-2%] top-[46%] h-[0.1em] w-[104%] origin-left rounded-full bg-ink"
                    initial={{ scaleX: 0 }}
                    whileInView={{ scaleX: 1 }}
                    viewport={{ once: true, amount: 0.8 }}
                    transition={{ delay: 0.6, duration: 0.7, ease: [0.7, 0, 0.2, 1] }}
                  />
                </span>
              </motion.span>
              <motion.span style={{ x: x2 }} className="block">
                <span className="inline-block">Start talking.</span>
              </motion.span>
            </h2>

            <div className="mt-12 flex flex-col gap-8 md:mt-16 md:flex-row md:items-end md:justify-between">
              <p className="max-w-md text-lg font-medium leading-relaxed text-ink/75 md:text-xl">
                Set up in under a minute. Say “Hey LEO” and hand over the busywork — your voice is the only interface you
                need.
              </p>
              <PillLink href="#top" variant="ink" size="xl" className="self-start md:self-auto">
                Get Started
              </PillLink>
            </div>
          </div>
        </motion.div>
      </div>
    </section>
  );
}
