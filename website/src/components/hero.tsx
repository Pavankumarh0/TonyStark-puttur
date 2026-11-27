"use client";

import { useEffect, useRef, useState } from "react";
import {
  AnimatePresence,
  motion,
  useInView,
  useMotionValue,
  useScroll,
  useSpring,
  useTransform,
  type MotionValue,
} from "framer-motion";
import { ArrowDown, Check, LayoutGrid, Mic, ShieldCheck, Zap } from "lucide-react";
import { APP_GLYPHS, type AppKey } from "@/components/app-glyphs";
import { Orb } from "@/components/orb";
import { Particles } from "@/components/particles";
import { EASE, SplitHeading } from "@/components/ui/reveal";
import { PillLink } from "@/components/ui/pill-link";
import { RotatingBadge } from "@/components/ui/stickers";
import { Typewriter } from "@/components/ui/typewriter";
import { Waveform } from "@/components/ui/waveform";
import { cn } from "@/lib/utils";

/* Positions are % of the stage. m = mobile, d = desktop. */
const APPS: { key: AppKey; label: string; m: [number, number]; d: [number, number]; float: number }[] = [
  { key: "whatsapp", label: "WhatsApp", m: [13, 13], d: [31, 22], float: 4.2 },
  { key: "instagram", label: "Instagram", m: [87, 15], d: [67, 18], float: 5.1 },
  { key: "youtube", label: "YouTube", m: [89, 50], d: [73, 55], float: 4.6 },
  { key: "gmail", label: "Gmail", m: [11, 49], d: [27, 60], float: 5.4 },
  { key: "phone", label: "Phone", m: [17, 78], d: [39, 84], float: 4.8 },
  { key: "alarm", label: "Clock", m: [83, 78], d: [61, 83], float: 5.8 },
];

const COMMANDS: {
  text: string;
  app: AppKey;
  result: string;
  side: "left" | "right";
  x: number;
  y: number;
}[] = [
  { text: "Send a WhatsApp message", app: "whatsapp", result: "Sent to Priya on WhatsApp", side: "left", x: 4, y: 13 },
  { text: "Call Mom", app: "phone", result: "Calling Mom · mobile", side: "right", x: 8, y: 11 },
  { text: "Play music", app: "youtube", result: "Now playing · Late Night Drive", side: "right", x: 3, y: 41 },
  { text: "Read my messages", app: "gmail", result: "Reading 3 new messages aloud", side: "left", x: 2, y: 42 },
  { text: "Set an alarm for 6 AM", app: "alarm", result: "Alarm set for 6:00 AM", side: "left", x: 6, y: 71 },
  { text: "Open Instagram", app: "instagram", result: "Opening Instagram", side: "right", x: 7, y: 69 },
];

const CYCLE_MS = 3800;

const CHIPS = [
  { icon: Mic, title: "“Hey LEO”", body: "Hands-free wake word" },
  { icon: Zap, title: "< 1 second", body: "From voice to action" },
  { icon: LayoutGrid, title: "40+ apps", body: "Under one command" },
  { icon: ShieldCheck, title: "On-device", body: "Your voice stays yours" },
];

export function Hero() {
  const sectionRef = useRef<HTMLElement>(null);
  const stageRef = useRef<HTMLDivElement>(null);
  const stageInView = useInView(stageRef, { amount: 0.3 });
  const [active, setActive] = useState(0);
  const [tick, setTick] = useState(0);

  // Cycle commands while the stage is visible. `tick` restarts the timer on manual picks.
  useEffect(() => {
    if (!stageInView) return;
    const id = setInterval(() => setActive((a) => (a + 1) % COMMANDS.length), CYCLE_MS);
    return () => clearInterval(id);
  }, [stageInView, tick]);

  const pick = (i: number) => {
    setActive(i);
    setTick((t) => t + 1);
  };

  // Mouse parallax
  const mx = useMotionValue(0);
  const my = useMotionValue(0);
  const sx = useSpring(mx, { stiffness: 55, damping: 18, mass: 0.6 });
  const sy = useSpring(my, { stiffness: 55, damping: 18, mass: 0.6 });

  // Scroll parallax
  const { scrollYProgress } = useScroll({ target: sectionRef, offset: ["start start", "end start"] });
  const headY = useTransform(scrollYProgress, [0, 1], [0, -90]);
  const stageScale = useTransform(scrollYProgress, [0, 1], [1, 0.94]);
  const orbScrollY = useTransform(scrollYProgress, [0, 1], [0, 70]);

  const cmd = COMMANDS[active];
  const activeApp = APPS.find((a) => a.key === cmd.app)!;

  return (
    <section ref={sectionRef} id="top" className="relative px-4 pb-16 pt-28 sm:px-6 md:pt-32 lg:px-10">
      <div className="mx-auto max-w-[1360px]">
        {/* Headline block */}
        <motion.div style={{ y: headY }}>
          <motion.div
            initial={{ opacity: 0, y: 12 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.8, ease: EASE }}
            className="mb-6 inline-flex items-center gap-2.5 rounded-full border border-volt/15 bg-coal/80 py-1.5 pl-1.5 pr-4 font-mono text-[11px] uppercase tracking-[0.16em] text-bone/70"
          >
            <span className="rounded-full bg-volt px-2 py-0.5 font-semibold text-ink">New</span>
            Voice-first personal AI
          </motion.div>

          <SplitHeading
            as="h1"
            immediate
            delay={0.1}
            stagger={0.07}
            className="font-display text-[clamp(2.6rem,6.1vw,5.9rem)] font-bold uppercase text-volt leading-[0.9] tracking-[-0.045em]"
            lines={[
              "Your entire digital world.",
              [
                "Under",
                "your",
                { text: "command.", className: "rounded-[0.1em] bg-volt px-[0.07em] text-ink" },
              ],
            ]}
          />

          <div className="mt-8 flex flex-col gap-7 md:mt-10 md:flex-row md:items-end md:justify-between">
            <motion.p
              initial={{ opacity: 0, y: 16 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.9, delay: 0.55, ease: EASE }}
              className="max-w-xl text-lg leading-relaxed text-bone/70 md:text-xl"
            >
              Meet <span className="font-semibold text-volt">LEO</span> — your intelligent personal assistant that
              listens, understands, and takes action through your voice.
            </motion.p>
            <motion.div
              initial={{ opacity: 0, y: 16 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.9, delay: 0.7, ease: EASE }}
              className="flex flex-wrap items-center gap-3"
            >
              <PillLink href="#demo" size="lg">
                Meet LEO
              </PillLink>
              <PillLink href="#capabilities" size="lg" variant="ghost" icon={<ArrowDown className="size-5 -rotate-45" />}>
                Explore capabilities
              </PillLink>
            </motion.div>
          </div>
        </motion.div>

        {/* Orb stage */}
        <motion.div
          initial={{ opacity: 0, y: 40 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 1.1, delay: 0.35, ease: EASE }}
          style={{ scale: stageScale }}
          className="relative mt-10 md:mt-14"
        >
          <div
            ref={stageRef}
            onPointerMove={(e) => {
              const r = e.currentTarget.getBoundingClientRect();
              mx.set((e.clientX - r.left) / r.width - 0.5);
              my.set((e.clientY - r.top) / r.height - 0.5);
            }}
            onPointerLeave={() => {
              mx.set(0);
              my.set(0);
            }}
            className="relative h-[560px] overflow-hidden rounded-[28px] border border-line bg-coal sm:h-[600px] md:rounded-[36px] lg:h-[660px]"
          >
            {/* Backdrop */}
            <div className="bg-dots mask-radial absolute inset-0" />
            <div className="absolute inset-0 bg-[radial-gradient(ellipse_55%_50%_at_50%_46%,rgb(46_255_110/0.17),transparent_70%)]" />
            <Particles count={80} />

            {/* Corner HUD */}
            <div className="absolute left-5 top-5 z-20 flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.2em] text-bone/50 md:left-7 md:top-7">
              <span className="relative flex size-2">
                <span className="absolute inset-0 animate-ping rounded-full bg-volt/70" />
                <span className="relative size-2 rounded-full bg-volt" />
              </span>
              Listening
              <span className="hidden text-bone/25 sm:inline">/ LEO voice core</span>
            </div>

            {/* App icons + beam (shared depth so the beam stays attached) */}
            <Depth x={sx} y={sy} depth={22} className="absolute inset-0 z-10">
              <svg
                className="absolute inset-0 hidden size-full lg:block"
                viewBox="0 0 100 100"
                preserveAspectRatio="none"
                aria-hidden
              >
                <AnimatePresence>
                  <motion.line
                    key={active}
                    x1={50}
                    y1={47}
                    x2={activeApp.d[0]}
                    y2={activeApp.d[1]}
                    stroke="#2eff6e"
                    strokeWidth={1.25}
                    strokeLinecap="round"
                    vectorEffect="non-scaling-stroke"
                    initial={{ pathLength: 0, opacity: 0 }}
                    animate={{ pathLength: 1, opacity: 0.7 }}
                    exit={{ opacity: 0, transition: { duration: 0.3 } }}
                    transition={{ duration: 0.7, delay: 0.25, ease: EASE }}
                  />
                </AnimatePresence>
              </svg>

              {APPS.map((app) => (
                <AppIcon key={app.key} app={app} active={app.key === cmd.app} />
              ))}
            </Depth>

            {/* Orb */}
            <Depth x={sx} y={sy} depth={-14} className="pointer-events-none absolute inset-0 z-[5]">
              <motion.div style={{ y: orbScrollY }} className="absolute inset-0">
                <div className="absolute left-1/2 top-[47%] w-[min(80vw,300px)] -translate-x-1/2 -translate-y-1/2 sm:w-[370px] lg:w-[430px]">
                  <Orb pulseKey={active} />
                </div>
              </motion.div>
            </Depth>

            {/* Voice-command bubbles (desktop) */}
            <Depth x={sx} y={sy} depth={40} className="pointer-events-none absolute inset-0 z-20 hidden lg:block">
              {COMMANDS.map((c, i) => (
                <CommandBubble key={c.text} command={c} index={i} active={i === active} onPick={() => pick(i)} />
              ))}
            </Depth>

            {/* Live transcript */}
            <div className="absolute inset-x-0 bottom-4 z-30 flex justify-center px-4 md:bottom-6">
              <div className="flex w-full max-w-[520px] items-center gap-3 rounded-full border border-volt/10 bg-ink/75 p-2 pr-4 shadow-[0_20px_60px_-20px_rgb(0_0_0/0.9)] backdrop-blur-xl">
                <span className="relative grid size-10 shrink-0 place-items-center rounded-full bg-volt text-ink">
                  <span className="absolute inset-0 animate-ping rounded-full bg-volt/35" />
                  <Mic className="relative size-4" strokeWidth={2.4} />
                </span>
                <div className="relative h-10 min-w-0 flex-1 overflow-hidden" aria-live="polite">
                  <AnimatePresence mode="wait" initial={false}>
                    <motion.div
                      key={active}
                      initial={{ y: 14, opacity: 0 }}
                      animate={{ y: 0, opacity: 1 }}
                      exit={{ y: -14, opacity: 0 }}
                      transition={{ duration: 0.35, ease: EASE }}
                      className="flex h-full flex-col justify-center"
                    >
                      <Typewriter
                        text={`“${cmd.text}”`}
                        speed={34}
                        className="truncate font-mono text-[13px] text-bone"
                      />
                      <motion.span
                        initial={{ opacity: 0, x: -6 }}
                        animate={{ opacity: 1, x: 0 }}
                        transition={{ delay: 1.35, duration: 0.4, ease: EASE }}
                        className="flex items-center gap-1.5 truncate font-mono text-[11px] text-volt"
                      >
                        <Check className="size-3 shrink-0" strokeWidth={3} />
                        {cmd.result}
                      </motion.span>
                    </motion.div>
                  </AnimatePresence>
                </div>
                <Waveform bars={12} seed={3} className="hidden h-6 text-volt sm:flex" />
              </div>
            </div>
          </div>

          {/* Sticker hanging off the stage corner */}
          <motion.div
            initial={{ opacity: 0, scale: 0.6, rotate: -30 }}
            animate={{ opacity: 1, scale: 1, rotate: 0 }}
            transition={{ duration: 1, delay: 1.1, ease: EASE }}
            className="absolute -right-2 -top-12 z-40 hidden md:block lg:-right-6"
          >
            <RotatingBadge
              id="hero-badge"
              text="Say “Hey LEO” • Always ready • "
              className="grid size-32 bg-volt text-ink shadow-[0_20px_50px_-15px_rgb(46_255_110/0.6)]"
            >
              <span className="grid size-12 place-items-center rounded-full bg-ink text-volt">
                <Mic className="size-5" strokeWidth={2.4} />
              </span>
            </RotatingBadge>
          </motion.div>
        </motion.div>

        {/* Proof chips */}
        <div className="mt-4 grid grid-cols-2 gap-3 md:mt-5 md:grid-cols-4 md:gap-4">
          {CHIPS.map((c, i) => (
            <motion.div
              key={c.title}
              initial={{ opacity: 0, y: 20 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ duration: 0.8, delay: 0.1 * i, ease: EASE }}
              className="group flex items-center gap-3 rounded-2xl border border-line bg-coal px-4 py-3.5 transition-colors hover:border-volt/40 md:px-5 md:py-4"
            >
              <span className="grid size-10 shrink-0 place-items-center rounded-full bg-volt text-ink transition-colors group-hover:bg-bone">
                <c.icon className="size-[18px]" />
              </span>
              <span className="min-w-0">
                <span className="block font-display text-sm font-bold uppercase tracking-tight text-volt md:text-base">
                  {c.title}
                </span>
                <span className="block text-xs leading-snug text-mute md:text-sm">{c.body}</span>
              </span>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}

/** Layer that shifts with the pointer by `depth` px at the stage edges. */
function Depth({
  x,
  y,
  depth,
  className,
  children,
}: {
  x: MotionValue<number>;
  y: MotionValue<number>;
  depth: number;
  className?: string;
  children: React.ReactNode;
}) {
  const tx = useTransform(x, (v) => v * depth);
  const ty = useTransform(y, (v) => v * depth);
  return (
    <motion.div style={{ x: tx, y: ty }} className={className}>
      {children}
    </motion.div>
  );
}

function AppIcon({ app, active }: { app: (typeof APPS)[number]; active: boolean }) {
  const Glyph = APP_GLYPHS[app.key];
  return (
    <div
      className="absolute left-[var(--mx)] top-[var(--my)] -translate-x-1/2 -translate-y-1/2 lg:left-[var(--dx)] lg:top-[var(--dy)]"
      style={
        {
          "--mx": `${app.m[0]}%`,
          "--my": `${app.m[1]}%`,
          "--dx": `${app.d[0]}%`,
          "--dy": `${app.d[1]}%`,
        } as React.CSSProperties
      }
    >
      <motion.div
        animate={{ y: [0, -9, 0], rotate: [0, app.float > 5 ? 3 : -3, 0] }}
        transition={{ duration: app.float, repeat: Infinity, ease: "easeInOut" }}
        className="relative flex flex-col items-center"
      >
        <motion.div
          animate={{ scale: active ? 1.14 : 1 }}
          transition={{ type: "spring", stiffness: 300, damping: 18 }}
          className={cn(
            "grid size-11 place-items-center rounded-2xl border backdrop-blur-md transition-colors duration-500 sm:size-14",
            active
              ? "border-volt bg-volt text-ink shadow-[0_0_0_6px_rgb(46_255_110/0.12),0_0_40px_rgb(46_255_110/0.55)]"
              : "border-volt/25 bg-coal-2/80 text-volt/85",
          )}
        >
          <Glyph className="size-5 sm:size-6" />
        </motion.div>
        <span
          className={cn(
            "absolute top-full mt-2 whitespace-nowrap font-mono text-[10px] uppercase tracking-[0.18em] transition-all duration-500",
            active ? "translate-y-0 text-volt opacity-100" : "-translate-y-1 text-bone/40 opacity-0",
          )}
        >
          {app.label}
        </span>
      </motion.div>
    </div>
  );
}

function CommandBubble({
  command,
  index,
  active,
  onPick,
}: {
  command: (typeof COMMANDS)[number];
  index: number;
  active: boolean;
  onPick: () => void;
}) {
  const pos: React.CSSProperties =
    command.side === "left" ? { left: `${command.x}%`, top: `${command.y}%` } : { right: `${command.x}%`, top: `${command.y}%` };

  return (
    <motion.div
      className="pointer-events-auto absolute"
      style={pos}
      initial={{ opacity: 0, scale: 0.85, y: 16 }}
      animate={{ opacity: 1, scale: 1, y: 0 }}
      transition={{ duration: 0.8, delay: 0.9 + index * 0.12, ease: EASE }}
    >
      <motion.button
        type="button"
        onClick={onPick}
        animate={{ y: [0, index % 2 ? 9 : -9, 0] }}
        transition={{ duration: 4.5 + index * 0.45, repeat: Infinity, ease: "easeInOut" }}
        className={cn(
          "flex items-center gap-2.5 rounded-2xl border py-2.5 pl-2.5 pr-4 text-left backdrop-blur-md transition-[background-color,border-color,box-shadow,color] duration-500",
          command.side === "left" ? "rounded-br-md" : "rounded-bl-md",
          active
            ? "border-volt/70 bg-volt/[0.12] text-bone shadow-[0_0_40px_-8px_rgb(46_255_110/0.55)]"
            : "border-volt/10 bg-coal-2/70 text-bone/60 hover:border-volt/25 hover:text-bone/90",
        )}
        aria-pressed={active}
      >
        <span
          className={cn(
            "grid size-7 shrink-0 place-items-center rounded-full transition-colors duration-500",
            active ? "bg-volt text-ink" : "bg-volt/[0.07] text-volt",
          )}
        >
          {active ? <Waveform bars={4} className="h-3 gap-[2px] text-ink" barClassName="w-[2px]" /> : <Mic className="size-3.5" />}
        </span>
        <span className="font-mono text-[13px] leading-none">“{command.text}”</span>
      </motion.button>
    </motion.div>
  );
}
