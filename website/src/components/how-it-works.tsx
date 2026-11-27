"use client";

import { useRef } from "react";
import { motion, useInView } from "framer-motion";
import { ArrowRight, Check, Mic } from "lucide-react";
import { EASE, Reveal, SectionLabel, SplitHeading } from "@/components/ui/reveal";
import { Tag } from "@/components/ui/stickers";
import { Typewriter } from "@/components/ui/typewriter";
import { Waveform } from "@/components/ui/waveform";
import { cn } from "@/lib/utils";

const SENTENCE = "Remind me to call the dentist tomorrow at 10.";

const PARSED = [
  { k: "Intent", v: "Create reminder" },
  { k: "Task", v: "Call the dentist" },
  { k: "When", v: "Tomorrow · 10:00 AM" },
];

const ACTIONS = ["Opened Reminders", "Created “Call the dentist”", "Scheduled for 10:00 AM"];

export function HowItWorks() {
  const gridRef = useRef<HTMLDivElement>(null);
  const inView = useInView(gridRef, { once: true, amount: 0.35 });

  return (
    <section id="how" className="relative scroll-mt-20 px-4 py-24 sm:px-6 md:py-32 lg:px-10">
      <div className="mx-auto max-w-[1360px]">
        <div className="flex flex-col gap-8 md:flex-row md:items-end md:justify-between">
          <div className="relative">
            <SectionLabel index="02">How it works</SectionLabel>
            <SplitHeading
              className="mt-6 font-display text-[clamp(3.2rem,9vw,8.5rem)] font-bold uppercase text-volt leading-[0.86] tracking-[-0.055em]"
              lines={["How it", "works."]}
            />
            <motion.div
              initial={{ opacity: 0, scale: 0.5, rotate: -20 }}
              whileInView={{ opacity: 1, scale: 1, rotate: 0 }}
              viewport={{ once: true }}
              transition={{ delay: 0.5, type: "spring", stiffness: 260, damping: 14 }}
              className="absolute -right-4 top-10 sm:-right-28 md:top-16"
            >
              <Tag rotate={6}>
                3 steps.
                <br />
                Zero taps.
              </Tag>
            </motion.div>
          </div>
          <Reveal className="max-w-sm md:pb-3" delay={0.15}>
            <p className="text-lg leading-relaxed text-bone/65">
              You talk. LEO figures out what you mean, then does it — across the apps you already use.
            </p>
          </Reveal>
        </div>

        <div ref={gridRef} className="relative mt-14 grid gap-4 md:mt-20 md:grid-cols-3 md:gap-5">
          {/* 01 — Speak */}
          <StepPanel
            index={0}
            n="01"
            title="Speak."
            body="Talk the way you talk. No commands to memorise, no buttons to find."
            className="border border-line bg-coal text-bone"
            numClass="border-volt/25"
          >
            <div className="flex h-full flex-col items-center justify-center gap-7">
              <div className="flex items-center gap-4">
                <Waveform bars={9} seed={11} active={inView} className="h-14 text-volt/70" />
                <span className="relative grid size-20 place-items-center rounded-full bg-volt text-ink">
                  <span className="ping-ring absolute inset-0 rounded-full border border-volt" />
                  <span className="ping-ring absolute inset-0 rounded-full border border-volt [animation-delay:1.2s]" />
                  <Mic className="size-8" strokeWidth={2.2} />
                </span>
                <Waveform bars={9} seed={12} active={inView} className="h-14 text-volt/70" />
              </div>
              <p className="min-h-[3.2em] max-w-[16rem] text-center font-mono text-sm leading-relaxed text-bone/85">
                <Typewriter text={`“${SENTENCE}”`} start={inView} delay={400} speed={38} />
              </p>
            </div>
          </StepPanel>

          {/* 02 — Understands */}
          <StepPanel
            index={1}
            n="02"
            title="LEO understands."
            body="Context, contacts, timing — LEO works out what you mean, not just what you said."
            className="bg-volt text-ink"
            numClass="border-ink/30"
          >
            <div className="flex h-full flex-col justify-center gap-3">
              {PARSED.map((p, i) => (
                <motion.div
                  key={p.k}
                  initial={{ opacity: 0, x: -24 }}
                  animate={inView ? { opacity: 1, x: 0 } : undefined}
                  transition={{ delay: 2.3 + i * 0.35, duration: 0.6, ease: EASE }}
                  className="flex items-center gap-3"
                >
                  <span className="w-14 font-mono text-[11px] uppercase tracking-[0.16em] text-ink/55">{p.k}</span>
                  <span className="h-px flex-1 bg-ink/20" />
                  <span className="rounded-full bg-ink px-3.5 py-1.5 font-mono text-[12px] text-volt">{p.v}</span>
                </motion.div>
              ))}
              <motion.div
                initial={{ opacity: 0 }}
                animate={inView ? { opacity: 1 } : undefined}
                transition={{ delay: 3.4, duration: 0.5 }}
                className="mt-4"
              >
                <div className="flex justify-between font-mono text-[10px] uppercase tracking-[0.16em] text-ink/60">
                  <span>Confidence</span>
                  <span>99%</span>
                </div>
                <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-ink/15">
                  <motion.div
                    className="h-full rounded-full bg-ink"
                    initial={{ width: "0%" }}
                    animate={inView ? { width: "99%" } : undefined}
                    transition={{ delay: 3.5, duration: 1, ease: EASE }}
                  />
                </div>
              </motion.div>
            </div>
          </StepPanel>

          {/* 03 — Executes */}
          <StepPanel
            index={2}
            n="03"
            title="LEO executes."
            body="It opens the app, taps the buttons and finishes the job — then tells you it's done."
            className="bg-volt-deep text-ink"
            numClass="border-ink/25"
          >
            <div className="flex h-full flex-col justify-center gap-3">
              {ACTIONS.map((a, i) => (
                <motion.div
                  key={a}
                  initial={{ opacity: 0, y: 12 }}
                  animate={inView ? { opacity: 1, y: 0 } : undefined}
                  transition={{ delay: 4.3 + i * 0.45, duration: 0.5, ease: EASE }}
                  className="flex items-center gap-3 rounded-2xl border border-ink/10 bg-ink/[0.04] px-3.5 py-3"
                >
                  <motion.span
                    initial={{ scale: 0 }}
                    animate={inView ? { scale: 1 } : undefined}
                    transition={{ delay: 4.55 + i * 0.45, type: "spring", stiffness: 400, damping: 15 }}
                    className="grid size-6 shrink-0 place-items-center rounded-full bg-ink text-volt"
                  >
                    <Check className="size-3.5" strokeWidth={3} />
                  </motion.span>
                  <span className="text-[14px] font-medium">{a}</span>
                </motion.div>
              ))}
              <motion.div
                initial={{ opacity: 0, scale: 0.9 }}
                animate={inView ? { opacity: 1, scale: 1 } : undefined}
                transition={{ delay: 5.9, duration: 0.6, ease: EASE }}
                className="mt-2 flex items-center gap-3 rounded-2xl bg-ink px-4 py-3.5 text-bone"
              >
                <span className="orb-mini size-7 shrink-0 rounded-full" />
                <span className="font-mono text-[12px] leading-snug">“Done. I&apos;ll remind you tomorrow at 10.”</span>
              </motion.div>
            </div>
          </StepPanel>

          {/* Connectors between panels */}
          {[1, 2].map((i) => (
            <motion.span
              key={i}
              aria-hidden
              initial={{ scale: 0 }}
              animate={inView ? { scale: 1 } : undefined}
              transition={{ delay: i === 1 ? 2 : 4, type: "spring", stiffness: 300, damping: 16 }}
              className="absolute top-1/2 z-10 hidden size-12 -translate-x-1/2 -translate-y-1/2 place-items-center rounded-full border-4 border-ink bg-volt text-ink md:grid"
              style={{ left: `${(i * 100) / 3}%` }}
            >
              <ArrowRight className="size-5" strokeWidth={2.4} />
            </motion.span>
          ))}
        </div>
      </div>
    </section>
  );
}

function StepPanel({
  index,
  n,
  title,
  body,
  className,
  numClass,
  children,
}: {
  index: number;
  n: string;
  title: string;
  body: string;
  className: string;
  numClass: string;
  children: React.ReactNode;
}) {
  return (
    <motion.article
      initial={{ opacity: 0, y: 50 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "0px 0px -10% 0px" }}
      transition={{ duration: 0.9, delay: index * 0.15, ease: EASE }}
      whileHover={{ y: -6 }}
      className={cn("flex min-h-[520px] flex-col rounded-[28px] p-6 md:p-7 lg:min-h-[560px]", className)}
    >
      <div className="flex items-center justify-between">
        <span className={cn("grid size-11 place-items-center rounded-full border font-mono text-sm", numClass)}>{n}</span>
        <span className="font-mono text-[10px] uppercase tracking-[0.2em] opacity-50">Step {n}</span>
      </div>
      <div className="flex-1 py-8">{children}</div>
      <div className={cn("border-t pt-5", numClass)}>
        <h3 className="font-display text-[2rem] font-bold uppercase leading-[0.95] tracking-[-0.04em] lg:text-[2.4rem]">
          {title}
        </h3>
        <p className="mt-2.5 max-w-xs text-[15px] leading-relaxed opacity-70">{body}</p>
      </div>
    </motion.article>
  );
}
