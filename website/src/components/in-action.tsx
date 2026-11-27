"use client";

import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion, useInView } from "framer-motion";
import { AlarmClock, Check, Mic, Pause, Phone, RotateCcw, SkipForward, Volume2 } from "lucide-react";
import { WhatsAppGlyph, YouTubeGlyph } from "@/components/app-glyphs";
import { EASE, Reveal, SectionLabel, SplitHeading } from "@/components/ui/reveal";
import { Burst } from "@/components/ui/stickers";
import { Typewriter } from "@/components/ui/typewriter";
import { Waveform } from "@/components/ui/waveform";
import { cn } from "@/lib/utils";

/* ---------- Script model ---------- */

type Stage = "listening" | "understanding" | "executing" | "done";

type Card =
  | { kind: "message"; to: string; text: string }
  | { kind: "alarm"; time: string; label: string }
  | { kind: "music"; title: string; artist: string }
  | { kind: "call"; name: string };

type Beat =
  | { type: "listen"; text: string; dur: number }
  | { type: "think"; dur: number }
  | { type: "say"; text: string; dur: number; stage: Stage }
  | { type: "act"; card: Card; dur: number };

type Scenario = { id: string; title: string; hint: string; beats: Beat[] };

const SCENARIOS: Scenario[] = [
  {
    id: "message",
    title: "Message a friend",
    hint: "“Tell Priya I'm running late”",
    beats: [
      { type: "listen", text: "Hey LEO, tell Priya I'm running ten minutes late.", dur: 2700 },
      { type: "think", dur: 1000 },
      { type: "say", text: "On it — sending this to Priya on WhatsApp.", dur: 1500, stage: "executing" },
      { type: "act", card: { kind: "message", to: "Priya", text: "Running 10 minutes late — save me a seat!" }, dur: 2400 },
      { type: "say", text: "Sent. I'll read her reply to you when it arrives.", dur: 3200, stage: "done" },
    ],
  },
  {
    id: "morning",
    title: "Plan tomorrow",
    hint: "“Set an alarm for 6 AM”",
    beats: [
      { type: "listen", text: "Set an alarm for 6 AM — I've got an early flight.", dur: 2700 },
      { type: "think", dur: 1000 },
      { type: "say", text: "Done. And I'll nudge you to check in at 6:15.", dur: 1500, stage: "executing" },
      { type: "act", card: { kind: "alarm", time: "6:00", label: "Early flight" }, dur: 2200 },
      { type: "say", text: "Alarm's on. Sleep well — rain is expected tomorrow, so pack an umbrella.", dur: 3400, stage: "done" },
    ],
  },
  {
    id: "music",
    title: "Play music",
    hint: "“Play something for my drive”",
    beats: [
      { type: "listen", text: "Play something chill for my drive.", dur: 2200 },
      { type: "think", dur: 900 },
      { type: "say", text: "Here's Late Night Drive on YouTube Music.", dur: 1400, stage: "executing" },
      { type: "act", card: { kind: "music", title: "Late Night Drive", artist: "Neon Avenue" }, dur: 2200 },
      { type: "say", text: "Volume's at 60%. Enjoy the ride.", dur: 3000, stage: "done" },
    ],
  },
  {
    id: "call",
    title: "Call someone",
    hint: "“Call Mom on speaker”",
    beats: [
      { type: "listen", text: "Call Mom on speaker.", dur: 1800 },
      { type: "think", dur: 800 },
      { type: "say", text: "Calling Mom on speaker now.", dur: 1300, stage: "executing" },
      { type: "act", card: { kind: "call", name: "Mom" }, dur: 2400 },
      { type: "say", text: "You're connected.", dur: 3000, stage: "done" },
    ],
  },
];

const STAGES: { id: Stage; label: string }[] = [
  { id: "listening", label: "Listening" },
  { id: "understanding", label: "Understanding" },
  { id: "executing", label: "Executing" },
  { id: "done", label: "Done" },
];

function stageOf(beat: Beat | undefined): Stage {
  if (!beat) return "done";
  switch (beat.type) {
    case "listen":
      return "listening";
    case "think":
      return "understanding";
    case "act":
      return "executing";
    case "say":
      return beat.stage;
  }
}

/* ---------- Section ---------- */

export function InAction() {
  const panelRef = useRef<HTMLDivElement>(null);
  const inView = useInView(panelRef, { amount: 0.35 });
  const [scenario, setScenario] = useState(0);
  const [beat, setBeat] = useState(0);
  const [run, setRun] = useState(0); // bump to restart the timeline

  const sc = SCENARIOS[scenario];

  // Advance through beats; then roll on to the next scenario.
  useEffect(() => {
    if (!inView) return;
    const current = sc.beats[beat];
    const t = setTimeout(
      () => {
        if (beat < sc.beats.length - 1) {
          setBeat(beat + 1);
        } else {
          setScenario((s) => (s + 1) % SCENARIOS.length);
          setBeat(0);
        }
      },
      current ? current.dur : 1200,
    );
    return () => clearTimeout(t);
  }, [inView, beat, sc, run]);

  const choose = (i: number) => {
    setScenario(i);
    setBeat(0);
    setRun((r) => r + 1);
  };

  const current = sc.beats[beat];
  const stage = stageOf(current);
  const stageIdx = STAGES.findIndex((s) => s.id === stage);
  const listen = current?.type === "listen" ? current : null;
  const listening = listen !== null;

  return (
    <section id="demo" className="relative scroll-mt-20 px-4 py-24 sm:px-6 md:py-32 lg:px-10">
      <div className="mx-auto max-w-[1360px]">
        <div className="grid gap-8 lg:grid-cols-12 lg:items-end">
          <div className="relative lg:col-span-8">
            <SectionLabel index="03">Live demo</SectionLabel>
            <SplitHeading
              className="mt-6 font-display text-[clamp(3.2rem,9vw,8.5rem)] font-bold uppercase text-volt leading-[0.86] tracking-[-0.055em]"
              lines={["See LEO", [{ text: "in" }, { text: "action.", className: "text-outline" }]]}
            />
          </div>
          <Reveal className="lg:col-span-4 lg:pb-3" delay={0.15}>
            <p className="max-w-md text-lg leading-relaxed text-bone/65">
              One sentence in. A finished task out. Pick a moment below — or just watch LEO work through the day.
            </p>
          </Reveal>
        </div>

        <Reveal className="relative mt-14 md:mt-20">
          <div
            ref={panelRef}
            className="grid overflow-hidden rounded-[28px] border border-line bg-coal md:rounded-[36px] lg:grid-cols-12"
          >
            {/* Scenario picker */}
            <div className="flex flex-col border-b border-line p-4 md:p-6 lg:col-span-4 lg:border-b-0 lg:border-r">
              <div className="mb-4 flex items-center justify-between px-2 font-mono text-[10px] uppercase tracking-[0.2em] text-mute">
                <span>Scenarios</span>
                <span>
                  {String(scenario + 1).padStart(2, "0")} / {String(SCENARIOS.length).padStart(2, "0")}
                </span>
              </div>
              <div className="grid grid-cols-2 gap-2 lg:grid-cols-1">
                {SCENARIOS.map((s, i) => {
                  const on = i === scenario;
                  return (
                    <button
                      key={s.id}
                      type="button"
                      onClick={() => choose(i)}
                      aria-pressed={on}
                      className={cn(
                        "group relative overflow-hidden rounded-2xl border p-3.5 text-left transition-colors duration-300 md:p-4",
                        on ? "border-volt/60 bg-volt/[0.07]" : "border-line hover:border-volt/25 hover:bg-volt/[0.02]",
                      )}
                    >
                      <div className="flex items-center gap-3">
                        <span
                          className={cn(
                            "font-mono text-[11px] transition-colors",
                            on ? "text-volt" : "text-mute group-hover:text-bone/60",
                          )}
                        >
                          {String(i + 1).padStart(2, "0")}
                        </span>
                        <span className="font-display text-[15px] font-bold uppercase tracking-tight md:text-lg">
                          {s.title}
                        </span>
                      </div>
                      <div className="mt-1 hidden pl-8 font-mono text-[11px] text-bone/40 sm:block">{s.hint}</div>
                      {on && (
                        <motion.span
                          key={`${s.id}-${run}`}
                          className="absolute bottom-0 left-0 h-[2px] bg-volt"
                          initial={{ width: "0%" }}
                          animate={{ width: inView ? "100%" : "0%" }}
                          transition={{
                            duration: s.beats.reduce((a, b) => a + b.dur, 0) / 1000,
                            ease: "linear",
                          }}
                        />
                      )}
                    </button>
                  );
                })}
              </div>

              {/* Pipeline */}
              <div className="mt-6 hidden rounded-2xl border border-line p-4 lg:mt-auto lg:block">
                <div className="mb-3 font-mono text-[10px] uppercase tracking-[0.2em] text-mute">Pipeline</div>
                <ol className="space-y-2.5">
                  {STAGES.map((s, i) => (
                    <li key={s.id} className="flex items-center gap-3">
                      <span
                        className={cn(
                          "grid size-5 place-items-center rounded-full border transition-all duration-500",
                          i < stageIdx && "border-volt bg-volt text-ink",
                          i === stageIdx && "border-volt text-volt shadow-[0_0_14px_rgb(46_255_110/0.5)]",
                          i > stageIdx && "border-volt/15 text-transparent",
                        )}
                      >
                        {i < stageIdx ? (
                          <Check className="size-3" strokeWidth={3} />
                        ) : (
                          <span className={cn("size-1.5 rounded-full", i === stageIdx ? "animate-pulse bg-volt" : "")} />
                        )}
                      </span>
                      <span
                        className={cn(
                          "font-mono text-[12px] uppercase tracking-[0.14em] transition-colors duration-500",
                          i === stageIdx ? "text-bone" : i < stageIdx ? "text-bone/55" : "text-bone/25",
                        )}
                      >
                        {s.label}
                      </span>
                    </li>
                  ))}
                </ol>
              </div>
            </div>

            {/* Conversation */}
            <div className="flex flex-col lg:col-span-8">
              <div className="flex items-center justify-between border-b border-line px-5 py-4 md:px-7">
                <div className="flex items-center gap-3">
                  <span className="orb-mini size-8 rounded-full" />
                  <div>
                    <div className="font-display text-sm font-bold uppercase tracking-tight">LEO</div>
                    <div className="flex items-center gap-1.5 font-mono text-[10px] uppercase tracking-[0.18em] text-volt">
                      <span className="size-1.5 animate-pulse rounded-full bg-volt" />
                      {STAGES[stageIdx]?.label ?? "Ready"}
                    </div>
                  </div>
                </div>
                <button
                  type="button"
                  onClick={() => choose(scenario)}
                  className="flex items-center gap-2 rounded-full border border-volt/15 px-3.5 py-2 font-mono text-[10px] uppercase tracking-[0.18em] text-bone/70 transition-colors hover:border-volt hover:text-volt"
                >
                  <RotateCcw className="size-3.5" /> Replay
                </button>
              </div>

              <div className="relative h-[440px] overflow-hidden px-4 md:h-[500px] md:px-7">
                <div className="absolute inset-x-0 top-0 z-10 h-16 bg-gradient-to-b from-coal to-transparent" />
                <div className="flex h-full flex-col justify-end gap-3 pb-5" aria-live="polite">
                  <AnimatePresence mode="popLayout" initial={false}>
                    {sc.beats.slice(0, beat + 1).map((b, i) => {
                      const key = `${sc.id}-${run}-${i}`;
                      const live = i === beat;
                      if (b.type === "listen") {
                        return live ? null : <UserBubble key={key} text={b.text} />;
                      }
                      if (b.type === "think") return live ? <Thinking key={key} /> : null;
                      if (b.type === "say") return <LeoBubble key={key} text={b.text} />;
                      return <ActionCard key={key} card={b.card} live={live} />;
                    })}
                  </AnimatePresence>
                </div>
              </div>

              {/* Voice input bar */}
              <div className="border-t border-line p-3 md:p-4">
                <div
                  className={cn(
                    "flex items-center gap-3 rounded-full border p-1.5 pr-5 transition-colors duration-500",
                    listening ? "border-volt/50 bg-volt/[0.06]" : "border-line bg-ink/40",
                  )}
                >
                  <span
                    className={cn(
                      "relative grid size-11 shrink-0 place-items-center rounded-full transition-colors duration-500",
                      listening ? "bg-volt text-ink" : "bg-coal-2 text-bone/50",
                    )}
                  >
                    {listening && <span className="absolute inset-0 animate-ping rounded-full bg-volt/40" />}
                    <Mic className="relative size-[18px]" strokeWidth={2.2} />
                  </span>
                  <div className="min-w-0 flex-1 truncate font-mono text-[13px]">
                    {listen ? (
                      <Typewriter
                        key={`${sc.id}-${run}-listen`}
                        text={listen.text}
                        // Finish typing just before the beat ends.
                        speed={Math.max(22, Math.floor((listen.dur - 600) / listen.text.length))}
                        className="text-bone"
                      />
                    ) : (
                      <span className="text-bone/35">Say “Hey LEO”…</span>
                    )}
                  </div>
                  <Waveform bars={16} seed={5} active={listening} className="hidden h-6 text-volt sm:flex" />
                </div>
              </div>
            </div>
          </div>

          <Burst className="absolute -top-12 right-44 z-20 hidden size-24 md:grid" rotate={-12} spikes={16}>
            Live
            <br />
            demo
          </Burst>
        </Reveal>
      </div>
    </section>
  );
}

/* ---------- Messages ---------- */

const bubbleIn = {
  layout: true,
  initial: { opacity: 0, y: 24, scale: 0.96 },
  animate: { opacity: 1, y: 0, scale: 1 },
  exit: { opacity: 0, scale: 0.96 },
  transition: { duration: 0.45, ease: EASE },
} as const;

function UserBubble({ text }: { text: string }) {
  return (
    <motion.div {...bubbleIn} className="flex max-w-[85%] flex-col items-end self-end md:max-w-[70%]">
      <div className="rounded-3xl rounded-br-md bg-volt px-4 py-3 text-[15px] leading-snug text-ink">{text}</div>
      <div className="mt-1.5 flex items-center gap-1.5 pr-1 font-mono text-[10px] uppercase tracking-[0.16em] text-mute">
        <Mic className="size-3" /> Voice · transcribed
      </div>
    </motion.div>
  );
}

function LeoBubble({ text }: { text: string }) {
  return (
    <motion.div {...bubbleIn} className="flex max-w-[85%] items-end gap-2.5 self-start md:max-w-[70%]">
      <span className="orb-mini mb-1 size-6 shrink-0 rounded-full" />
      <div className="rounded-3xl rounded-bl-md border border-line bg-coal-2 px-4 py-3 text-[15px] leading-snug">
        <Typewriter text={text} speed={18} caret={false} />
      </div>
    </motion.div>
  );
}

function Thinking() {
  return (
    <motion.div {...bubbleIn} className="flex items-end gap-2.5 self-start">
      <span className="orb-mini mb-1 size-6 shrink-0 rounded-full" />
      <div className="flex items-center gap-1.5 rounded-3xl rounded-bl-md border border-line bg-coal-2 px-4 py-4">
        {[0, 1, 2].map((i) => (
          <motion.span
            key={i}
            className="size-1.5 rounded-full bg-volt"
            animate={{ opacity: [0.25, 1, 0.25], y: [0, -3, 0] }}
            transition={{ duration: 0.9, repeat: Infinity, delay: i * 0.15 }}
          />
        ))}
      </div>
    </motion.div>
  );
}

function ActionCard({ card, live }: { card: Card; live: boolean }) {
  const done = !live;
  return (
    <motion.div
      {...bubbleIn}
      className="ml-8 w-full max-w-[360px] self-start overflow-hidden rounded-3xl border border-volt/30 bg-ink"
    >
      <div className="flex items-center justify-between border-b border-line px-4 py-2.5 font-mono text-[10px] uppercase tracking-[0.18em]">
        <span className="text-mute">Action</span>
        <span className={cn("flex items-center gap-1.5", done ? "text-volt" : "text-bone/70")}>
          {done ? <Check className="size-3" strokeWidth={3} /> : <span className="size-1.5 animate-pulse rounded-full bg-volt" />}
          {done ? "Complete" : "Running"}
        </span>
      </div>
      <div className="p-4">
        <CardBody card={card} done={done} />
      </div>
      <div className="h-[2px] bg-line">
        <motion.div
          className="h-full bg-volt"
          initial={{ width: "0%" }}
          animate={{ width: "100%" }}
          transition={{ duration: 1.8, ease: EASE }}
        />
      </div>
    </motion.div>
  );
}

function CardBody({ card, done }: { card: Card; done: boolean }) {
  switch (card.kind) {
    case "message":
      return (
        <div className="flex gap-3">
          <span className="grid size-10 shrink-0 place-items-center rounded-2xl bg-volt text-ink">
            <WhatsAppGlyph className="size-5" />
          </span>
          <div className="min-w-0">
            <div className="font-display text-sm font-semibold">To {card.to}</div>
            <p className="mt-0.5 text-[13px] text-bone/70">{card.text}</p>
            <div className="mt-1.5 font-mono text-[10px] text-volt">{done ? "Delivered ✓✓" : "Sending…"}</div>
          </div>
        </div>
      );
    case "alarm":
      return (
        <div className="flex items-center gap-4">
          <span className="grid size-10 shrink-0 place-items-center rounded-2xl bg-volt text-ink">
            <AlarmClock className="size-5" />
          </span>
          <div className="flex-1">
            <div className="flex items-baseline gap-1.5">
              <span className="font-display text-3xl font-bold tracking-[-0.05em]">{card.time}</span>
              <span className="font-display text-sm text-mute">AM</span>
            </div>
            <div className="font-mono text-[10px] text-mute">Tomorrow · {card.label}</div>
          </div>
          <span className={cn("relative h-6 w-10 rounded-full p-0.5 transition-colors duration-500", done ? "bg-volt" : "bg-line")}>
            <span
              className={cn(
                "block size-5 rounded-full transition-transform duration-500",
                done ? "translate-x-4 bg-ink" : "bg-bone/80",
              )}
            />
          </span>
        </div>
      );
    case "music":
      return (
        <div className="flex items-center gap-3">
          <span className="relative grid size-12 shrink-0 place-items-center overflow-hidden rounded-xl bg-[radial-gradient(circle_at_30%_25%,#b4ffcb,#2eff6e_35%,#0f8a3a)]">
            <Waveform bars={5} seed={8} className="h-5 text-ink" barClassName="w-[2px]" />
          </span>
          <div className="min-w-0 flex-1">
            <div className="truncate font-display text-sm font-semibold">{card.title}</div>
            <div className="flex items-center gap-1.5 text-[12px] text-mute">
              <YouTubeGlyph className="size-3.5" /> {card.artist}
            </div>
          </div>
          <div className="flex items-center gap-2 text-bone/70">
            <Pause className="size-4" fill="currentColor" />
            <SkipForward className="size-4" />
          </div>
        </div>
      );
    case "call":
      return (
        <div className="flex items-center gap-3">
          <span className="relative grid size-11 shrink-0 place-items-center rounded-full bg-volt font-display font-bold text-ink">
            {!done && <span className="absolute inset-0 animate-ping rounded-full border border-volt" />}
            {card.name[0]}
          </span>
          <div className="flex-1">
            <div className="font-display text-sm font-semibold">{card.name}</div>
            <div className="font-mono text-[10px] text-volt">{done ? "Connected · 00:04" : "Ringing…"}</div>
          </div>
          <span className="grid size-9 place-items-center rounded-full bg-volt text-ink">
            <Volume2 className="size-4" />
          </span>
          <span className="grid size-9 place-items-center rounded-full bg-volt-deep text-ink">
            <Phone className="size-4 rotate-[135deg]" />
          </span>
        </div>
      );
  }
}
