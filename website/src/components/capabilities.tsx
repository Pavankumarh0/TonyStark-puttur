"use client";

import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import {
  AlarmScreen,
  CallScreen,
  ControlScreen,
  MessageScreen,
  OpenScreen,
  PhoneFrame,
  PlayScreen,
  ReadScreen,
  SearchScreen,
} from "@/components/phone-screens";
import { EASE, Reveal, SectionLabel, SplitHeading } from "@/components/ui/reveal";
import { Burst } from "@/components/ui/stickers";
import { cn } from "@/lib/utils";

const CAPS = [
  {
    verb: "Message",
    cmd: "Tell Priya I'm running ten minutes late",
    desc: "Compose and send on WhatsApp, SMS and more.",
    Screen: MessageScreen,
  },
  { verb: "Call", cmd: "Call Mom on speaker", desc: "Dial anyone in your contacts. No thumbs.", Screen: CallScreen },
  { verb: "Read", cmd: "Read my new messages", desc: "Texts, emails and notifications, read aloud.", Screen: ReadScreen },
  { verb: "Open", cmd: "Open Instagram", desc: "Launch any app on your phone, instantly.", Screen: OpenScreen },
  { verb: "Play", cmd: "Play something for my drive", desc: "Music, podcasts and videos, queued by voice.", Screen: PlayScreen },
  {
    verb: "Search",
    cmd: "Will it rain tomorrow?",
    desc: "Ask anything. Hear the answer, not ten blue links.",
    Screen: SearchScreen,
  },
  { verb: "Wake", cmd: "Set an alarm for 6 AM", desc: "Alarms, timers and reminders in one sentence.", Screen: AlarmScreen },
  {
    verb: "Control",
    cmd: "Turn on Do Not Disturb and dim the screen",
    desc: "Wi-Fi, brightness, Bluetooth — settings, spoken.",
    Screen: ControlScreen,
  },
];

export function Capabilities() {
  const [active, setActive] = useState(0);
  const { Screen, cmd } = CAPS[active];

  return (
    <section id="capabilities" className="relative scroll-mt-20 px-4 py-24 sm:px-6 md:py-32 lg:px-10">
      <div className="mx-auto max-w-[1360px]">
        <div className="grid gap-8 lg:grid-cols-12 lg:items-end">
          <div className="lg:col-span-8">
            <SectionLabel index="01">Capabilities</SectionLabel>
            <SplitHeading
              className="mt-6 font-display text-[clamp(3.2rem,9vw,8.5rem)] font-bold uppercase text-volt leading-[0.86] tracking-[-0.055em]"
              lines={[
                "One voice.",
                [
                  { text: "Every", className: "text-outline" },
                  { text: "app.", className: "text-outline" },
                ],
              ]}
            />
          </div>
          <Reveal className="lg:col-span-4 lg:pb-3" delay={0.15}>
            <p className="max-w-md text-lg leading-relaxed text-bone/65">
              Messages, calls, music, alarms, search — LEO handles the everyday taps so your hands and eyes stay free.{" "}
              <span className="text-bone">Just say it.</span>
            </p>
          </Reveal>
        </div>

        <div className="mt-14 grid gap-10 lg:mt-20 lg:grid-cols-12 lg:gap-8">
          <ol className="lg:col-span-7">
            {CAPS.map((c, i) => (
              <CapRow key={c.verb} index={i} cap={c} active={i === active} setActive={setActive} />
            ))}
          </ol>

          <div className="hidden lg:col-span-5 lg:block">
            <div className="sticky top-24 flex justify-center pt-4">
              <div className="relative">
                {/* Giant index number behind the phone */}
                <AnimatePresence mode="popLayout" initial={false}>
                  <motion.span
                    key={active}
                    aria-hidden
                    initial={{ opacity: 0, y: 60 }}
                    animate={{ opacity: 1, y: 0 }}
                    exit={{ opacity: 0, y: -60 }}
                    transition={{ duration: 0.6, ease: EASE }}
                    className="text-outline-volt pointer-events-none absolute -left-24 top-0 select-none font-display text-[13rem] font-bold leading-none tracking-[-0.08em]"
                  >
                    {String(active + 1).padStart(2, "0")}
                  </motion.span>
                </AnimatePresence>
                <div className="absolute inset-0 -z-10 scale-110 rounded-full bg-volt/10 blur-[90px]" />

                <PhoneFrame command={cmd}>
                  <AnimatePresence mode="wait" initial={false}>
                    <motion.div
                      key={active}
                      initial={{ opacity: 0, y: 14, filter: "blur(6px)" }}
                      animate={{ opacity: 1, y: 0, filter: "blur(0px)" }}
                      exit={{ opacity: 0, y: -14, filter: "blur(6px)" }}
                      transition={{ duration: 0.32, ease: EASE }}
                      className="absolute inset-0"
                    >
                      <Screen />
                    </motion.div>
                  </AnimatePresence>
                </PhoneFrame>

                <Burst className="absolute -right-12 top-16 grid size-28" rotate={12}>
                  No
                  <br />
                  taps!
                </Burst>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function CapRow({
  cap,
  index,
  active,
  setActive,
}: {
  cap: (typeof CAPS)[number];
  index: number;
  active: boolean;
  setActive: (i: number) => void;
}) {
  const ref = useRef<HTMLLIElement>(null);

  // Activate the row that crosses the middle of the viewport while scrolling.
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) setActive(index);
      },
      { rootMargin: "-48% 0px -48% 0px" },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [index, setActive]);

  return (
    <motion.li
      ref={ref}
      initial={{ opacity: 0, y: 30 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "0px 0px -8% 0px" }}
      transition={{ duration: 0.8, ease: EASE }}
      className="relative border-t border-line last:border-b"
    >
      <button
        type="button"
        onMouseEnter={() => setActive(index)}
        onFocus={() => setActive(index)}
        onClick={() => setActive(index)}
        aria-pressed={active}
        className="group flex w-full flex-col gap-3 py-5 text-left md:py-7 xl:flex-row xl:items-center xl:gap-8"
      >
        <span className="flex items-baseline gap-4 md:gap-6 xl:flex-1">
          <span className={cn("w-7 font-mono text-xs transition-colors", active ? "text-volt" : "text-mute")}>
            {String(index + 1).padStart(2, "0")}
          </span>
          <span
            className={cn(
              "font-display text-[clamp(2.9rem,6.6vw,6rem)] font-bold uppercase leading-[0.85] tracking-[-0.055em] transition-[color,transform] duration-500 ease-[cubic-bezier(.2,.8,.2,1)]",
              active ? "translate-x-2 text-volt" : "text-outline group-hover:translate-x-1",
            )}
          >
            {cap.verb}
            <span className={cn("transition-colors duration-500", active ? "text-bone" : "")}>.</span>
          </span>
        </span>
        <span className="pl-11 md:pl-[3.25rem] xl:w-[270px] xl:shrink-0 xl:pl-0">
          <span
            className={cn("block font-mono text-[13px] leading-snug transition-colors duration-500", active ? "text-volt" : "text-bone/35")}
          >
            “{cap.cmd}”
          </span>
          <span className={cn("mt-1.5 block text-sm transition-colors duration-500", active ? "text-bone/70" : "text-mute/70")}>
            {cap.desc}
          </span>
        </span>
      </button>
      <motion.span
        aria-hidden
        className="absolute -bottom-px left-0 h-px w-full origin-left bg-volt"
        initial={false}
        animate={{ scaleX: active ? 1 : 0 }}
        transition={{ duration: 0.7, ease: EASE }}
      />
    </motion.li>
  );
}
