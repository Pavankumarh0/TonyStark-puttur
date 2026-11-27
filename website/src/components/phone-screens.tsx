"use client";

import { useEffect, useState } from "react";
import { motion } from "framer-motion";
import {
  Battery,
  Bluetooth,
  Camera,
  Check,
  CheckCheck,
  ChevronLeft,
  CloudRain,
  Flashlight,
  Globe,
  MessageSquareText,
  MicOff,
  Moon,
  Music,
  Pause,
  Phone,
  Search,
  Settings,
  Signal,
  SkipBack,
  SkipForward,
  Sun,
  Sunrise,
  Volume2,
  Wifi,
} from "lucide-react";
import { GmailGlyph, InstagramGlyph, WhatsAppGlyph, YouTubeGlyph } from "@/components/app-glyphs";
import { EASE } from "@/components/ui/reveal";
import { Typewriter } from "@/components/ui/typewriter";
import { Waveform } from "@/components/ui/waveform";
import { cn } from "@/lib/utils";

/* ---------- Frame ---------- */

export function PhoneFrame({ command, children }: { command: string; children: React.ReactNode }) {
  return (
    <div className="relative w-[300px] rounded-[50px] border border-volt/15 bg-[#031208] p-2.5 shadow-[0_60px_140px_-40px_rgb(46_255_110/0.3),inset_0_0_0_1px_rgb(255_255_255/0.04)]">
      <div className="relative h-[610px] overflow-hidden rounded-[41px] bg-ink">
        {/* Status bar */}
        <div className="flex h-12 items-center justify-between px-7 pt-1 font-mono text-[11px] font-medium text-bone/80">
          <span>9:41</span>
          <span className="flex items-center gap-1.5">
            <Signal className="size-3" />
            <Wifi className="size-3" />
            <Battery className="size-4" />
          </span>
        </div>
        {/* Island */}
        <div className="absolute left-1/2 top-2.5 flex h-7 w-[92px] -translate-x-1/2 items-center justify-end rounded-full bg-black pr-2">
          <span className="relative flex size-3">
            <span className="absolute inset-0 animate-ping rounded-full bg-volt/60" />
            <span className="orb-mini relative size-3 rounded-full" />
          </span>
        </div>

        <div className="absolute inset-x-0 bottom-[78px] top-12">{children}</div>

        {/* LEO voice bar */}
        <div className="absolute inset-x-3 bottom-3 flex h-[58px] items-center gap-2.5 rounded-full border border-volt/10 bg-coal-2/95 pl-2 pr-4">
          <span className="orb-mini size-10 shrink-0 rounded-full" />
          <div className="min-w-0 flex-1">
            <div className="font-mono text-[9px] uppercase tracking-[0.2em] text-volt">LEO heard</div>
            <Typewriter key={command} text={`“${command}”`} speed={28} className="block truncate font-mono text-[11px] text-bone" />
          </div>
          <Waveform bars={6} seed={9} className="h-4 text-volt" />
        </div>
      </div>
    </div>
  );
}

/* ---------- Shared bits ---------- */

function useSeconds() {
  const [s, setS] = useState(0);
  useEffect(() => {
    const id = setInterval(() => setS((v) => v + 1), 1000);
    return () => clearInterval(id);
  }, []);
  return s;
}

const pop = (delay: number) => ({
  initial: { opacity: 0, y: 10, scale: 0.96 },
  animate: { opacity: 1, y: 0, scale: 1 },
  transition: { duration: 0.45, delay, ease: EASE },
});

function AppBar({ icon, title, sub, avatar }: { icon: React.ReactNode; title: string; sub?: string; avatar?: string }) {
  return (
    <div className="flex items-center gap-2.5 border-b border-line px-4 pb-3 pt-1">
      <ChevronLeft className="size-4 text-bone/50" />
      {avatar ? (
        <span className="grid size-8 place-items-center rounded-full bg-volt font-display text-sm font-bold text-ink">
          {avatar}
        </span>
      ) : null}
      <div className="min-w-0 flex-1">
        <div className="truncate font-display text-sm font-semibold">{title}</div>
        {sub ? <div className="font-mono text-[10px] text-volt">{sub}</div> : null}
      </div>
      <span className="text-bone/40">{icon}</span>
    </div>
  );
}

function Toggle({ on, delay = 0 }: { on: boolean; delay?: number }) {
  return (
    <motion.span
      initial={{ backgroundColor: "rgb(19 71 38)" }}
      animate={{ backgroundColor: on ? "rgb(46 255 110)" : "rgb(19 71 38)" }}
      transition={{ delay, duration: 0.3 }}
      className="relative inline-flex h-6 w-10 shrink-0 items-center rounded-full p-0.5"
    >
      <motion.span
        initial={{ x: 0 }}
        animate={{ x: on ? 16 : 0 }}
        transition={{ delay, type: "spring", stiffness: 500, damping: 30 }}
        className={cn("size-5 rounded-full shadow", on ? "bg-ink" : "bg-bone/80")}
      />
    </motion.span>
  );
}

/* ---------- Screens ---------- */

export function MessageScreen() {
  return (
    <div className="flex h-full flex-col">
      <AppBar avatar="P" title="Priya" sub="online" icon={<WhatsAppGlyph className="size-4" />} />
      <div className="flex flex-1 flex-col justify-end gap-2 px-3 pb-4">
        <motion.div {...pop(0.05)} className="self-center rounded-full bg-volt/[0.06] px-3 py-1 font-mono text-[10px] text-mute">
          Today
        </motion.div>
        <motion.div {...pop(0.15)} className="max-w-[78%] self-start rounded-2xl rounded-bl-md bg-coal-2 px-3.5 py-2.5 text-[13px]">
          Are you close?
        </motion.div>
        <motion.div {...pop(0.3)} className="max-w-[78%] self-start rounded-2xl rounded-bl-md bg-coal-2 px-3.5 py-2.5 text-[13px]">
          The table&apos;s ready.
        </motion.div>
        <motion.div
          {...pop(1.0)}
          className="max-w-[82%] self-end rounded-2xl rounded-br-md bg-volt px-3.5 py-2.5 text-[13px] font-medium text-ink"
        >
          Running 10 min late — order me the usual!
        </motion.div>
        <motion.div {...pop(1.5)} className="flex items-center gap-1 self-end font-mono text-[10px] text-volt">
          <CheckCheck className="size-3" /> Sent by LEO · 9:41
        </motion.div>
      </div>
    </div>
  );
}

export function CallScreen() {
  const s = useSeconds();
  const status = s < 2 ? "Calling · mobile" : `00:${String(s - 2).padStart(2, "0")}`;
  return (
    <div className="flex h-full flex-col items-center px-6 pt-12">
      <div className="relative grid size-28 place-items-center">
        {[0, 1, 2].map((i) => (
          <span key={i} className="ping-ring absolute inset-0 rounded-full border border-volt/60" style={{ animationDelay: `${i * 1.2}s` }} />
        ))}
        <motion.span
          {...pop(0.1)}
          className="relative grid size-24 place-items-center rounded-full bg-volt font-display text-4xl font-bold text-ink"
        >
          M
        </motion.span>
      </div>
      <motion.div {...pop(0.25)} className="mt-8 font-display text-3xl font-bold tracking-tight">
        Mom
      </motion.div>
      <motion.div {...pop(0.35)} className="mt-1 font-mono text-xs text-volt">
        {status}
      </motion.div>
      <div className="mt-auto mb-8 grid w-full grid-cols-3 gap-4">
        {[
          { icon: MicOff, label: "Mute", on: false },
          { icon: Volume2, label: "Speaker", on: true },
          { icon: Phone, label: "End", on: false, end: true },
        ].map((b, i) => (
          <motion.div key={b.label} {...pop(0.45 + i * 0.08)} className="flex flex-col items-center gap-2">
            <span
              className={cn(
                "grid size-14 place-items-center rounded-full",
                b.end ? "bg-volt-deep text-ink" : b.on ? "bg-volt text-ink" : "bg-coal-2 text-bone",
              )}
            >
              <b.icon className={cn("size-5", b.end && "rotate-[135deg]")} />
            </span>
            <span className="font-mono text-[10px] text-mute">{b.label}</span>
          </motion.div>
        ))}
      </div>
    </div>
  );
}

const INBOX = [
  { from: "Mom", text: "Don't forget Sunday lunch!", time: "9:12" },
  { from: "Arjun", text: "Game tonight at 8?", time: "8:47" },
  { from: "Studio", text: "Your booking is confirmed.", time: "7:30" },
];

export function ReadScreen() {
  const s = useSeconds();
  const current = Math.min(Math.floor(s / 2), INBOX.length - 1);
  return (
    <div className="flex h-full flex-col">
      <AppBar title="Messages" sub="Reading aloud" icon={<MessageSquareText className="size-4" />} />
      <div className="flex flex-col gap-2 p-3">
        {INBOX.map((m, i) => (
          <motion.div
            key={m.from}
            {...pop(0.1 + i * 0.1)}
            className={cn(
              "rounded-2xl border p-3 transition-colors duration-500",
              i === current ? "border-volt/60 bg-volt/[0.08]" : "border-line bg-coal",
            )}
          >
            <div className="flex items-center justify-between">
              <span className="font-display text-sm font-semibold">{m.from}</span>
              <span className="font-mono text-[10px] text-mute">{m.time}</span>
            </div>
            <p className={cn("mt-1 text-[12px]", i === current ? "text-bone" : "text-bone/50")}>{m.text}</p>
            {i === current && <Waveform bars={22} seed={i + 4} className="mt-2.5 h-4 text-volt" />}
          </motion.div>
        ))}
      </div>
    </div>
  );
}

const HOME_APPS = [
  { icon: WhatsAppGlyph },
  { icon: YouTubeGlyph },
  { icon: GmailGlyph },
  { icon: Phone },
  { icon: Camera },
  { icon: InstagramGlyph, target: true },
  { icon: Globe },
  { icon: Music },
  { icon: Search },
  { icon: Sun },
  { icon: MessageSquareText },
  { icon: Settings },
];

export function OpenScreen() {
  return (
    <div className="relative h-full px-5 pt-6">
      <div className="grid grid-cols-4 gap-x-3 gap-y-5">
        {HOME_APPS.map((a, i) => (
          <motion.div key={i} {...pop(0.03 * i)} className="flex justify-center">
            <motion.span
              animate={a.target ? { scale: [1, 1, 1.18, 1.12] } : undefined}
              transition={{ duration: 1.2, times: [0, 0.5, 0.8, 1], delay: 0.3 }}
              className={cn(
                "grid size-12 place-items-center rounded-2xl border",
                a.target
                  ? "border-volt bg-volt text-ink shadow-[0_0_30px_rgb(46_255_110/0.6)]"
                  : "border-line bg-coal-2 text-bone/60",
              )}
            >
              <a.icon className="size-5" />
            </motion.span>
          </motion.div>
        ))}
      </div>
      {/* App launch splash zooming out of the icon */}
      <motion.div
        initial={{ scale: 0.12, opacity: 0, borderRadius: 40 }}
        animate={{ scale: 1, opacity: 1, borderRadius: 24 }}
        transition={{ delay: 1.5, duration: 0.6, ease: EASE }}
        style={{ transformOrigin: "62% 34%" }}
        className="absolute inset-3 grid place-items-center bg-volt text-ink"
      >
        <div className="flex flex-col items-center gap-3">
          <InstagramGlyph className="size-14" />
          <span className="font-display text-lg font-bold tracking-tight">Instagram</span>
          <span className="h-1 w-24 overflow-hidden rounded-full bg-ink/10">
            <motion.span
              className="block h-full bg-ink"
              initial={{ width: "0%" }}
              animate={{ width: "100%" }}
              transition={{ delay: 1.9, duration: 1.4, ease: "easeInOut" }}
            />
          </span>
        </div>
      </motion.div>
    </div>
  );
}

export function PlayScreen() {
  return (
    <div className="flex h-full flex-col px-5 pt-4">
      <motion.div
        {...pop(0.05)}
        className="relative aspect-square w-full overflow-hidden rounded-3xl bg-[radial-gradient(circle_at_30%_25%,#b4ffcb,#2eff6e_30%,#0f8a3a_70%,#063d1a)]"
      >
        {[0, 1, 2, 3].map((i) => (
          <span
            key={i}
            className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 rounded-full border border-ink/25"
            style={{ width: `${30 + i * 22}%`, height: `${30 + i * 22}%` }}
          />
        ))}
        <span className="absolute inset-0 animate-spin-slow">
          <span className="absolute left-1/2 top-[8%] size-2 rounded-full bg-ink" />
        </span>
        <Waveform bars={18} seed={2} className="absolute inset-x-6 bottom-5 h-10 text-ink" />
      </motion.div>
      <motion.div {...pop(0.2)} className="mt-5 flex items-end justify-between">
        <div>
          <div className="font-display text-xl font-bold tracking-tight">Late Night Drive</div>
          <div className="text-xs text-mute">Neon Avenue</div>
        </div>
        <YouTubeGlyph className="size-5 text-volt" />
      </motion.div>
      <motion.div {...pop(0.3)} className="mt-4">
        <div className="h-1 overflow-hidden rounded-full bg-volt/10">
          <motion.div
            className="h-full rounded-full bg-volt"
            initial={{ width: "14%" }}
            animate={{ width: "64%" }}
            transition={{ duration: 14, ease: "linear" }}
          />
        </div>
        <div className="mt-1.5 flex justify-between font-mono text-[10px] text-mute">
          <span>0:32</span>
          <span>3:48</span>
        </div>
      </motion.div>
      <motion.div {...pop(0.4)} className="mt-3 flex items-center justify-center gap-6">
        <SkipBack className="size-5 text-bone/70" />
        <span className="grid size-14 place-items-center rounded-full bg-volt text-ink">
          <Pause className="size-5" fill="currentColor" />
        </span>
        <SkipForward className="size-5 text-bone/70" />
      </motion.div>
    </div>
  );
}

const RAIN = [8, 10, 12, 18, 34, 62, 80, 74, 52, 30];

export function SearchScreen() {
  return (
    <div className="flex h-full flex-col gap-3 px-4 pt-4">
      <motion.div
        {...pop(0.05)}
        className="self-end rounded-2xl rounded-br-md border border-line bg-coal-2 px-3.5 py-2.5 text-[13px]"
      >
        Will it rain tomorrow?
      </motion.div>
      <motion.div {...pop(0.5)} className="rounded-3xl border border-volt/40 bg-volt/[0.06] p-4">
        <div className="flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.18em] text-volt">
          <span className="orb-mini size-3 rounded-full" /> LEO · answer
        </div>
        <p className="mt-2.5 text-[15px] leading-snug">
          Yes — light rain after <span className="text-volt">4 PM</span>. Take an umbrella.
        </p>
        <div className="mt-4 flex items-end justify-between">
          <div className="flex items-center gap-2">
            <CloudRain className="size-7 text-bone/80" />
            <span className="font-display text-4xl font-bold tracking-tight">24°</span>
          </div>
          <span className="font-mono text-[10px] text-mute">Rain chance</span>
        </div>
        <div className="mt-3 flex h-20 items-end gap-1.5">
          {RAIN.map((v, i) => (
            <motion.span
              key={i}
              initial={{ height: "4%" }}
              animate={{ height: `${v}%` }}
              transition={{ delay: 0.8 + i * 0.05, duration: 0.6, ease: EASE }}
              className={cn("flex-1 rounded-t-md", i >= 4 ? "bg-volt" : "bg-volt/20")}
            />
          ))}
        </div>
        <div className="mt-1.5 flex justify-between font-mono text-[9px] text-mute">
          <span>12P</span>
          <span>4P</span>
          <span>9P</span>
        </div>
      </motion.div>
      <motion.div {...pop(1.1)} className="font-mono text-[10px] text-mute">
        3 sources · answered in 0.8s
      </motion.div>
    </div>
  );
}

export function AlarmScreen() {
  return (
    <div className="flex h-full flex-col px-5 pt-6">
      <motion.div {...pop(0.05)} className="font-mono text-[10px] uppercase tracking-[0.2em] text-mute">
        Alarm · tomorrow
      </motion.div>
      <motion.div {...pop(0.15)} className="mt-3 flex items-end justify-between">
        <div className="flex items-baseline gap-2">
          <span className="font-display text-7xl font-bold leading-none tracking-[-0.06em]">6:00</span>
          <span className="font-display text-xl font-semibold text-mute">AM</span>
        </div>
        <Toggle on delay={0.9} />
      </motion.div>
      <motion.div {...pop(0.3)} className="mt-2 font-mono text-[11px] text-volt">
        Rings in 8 h 19 min
      </motion.div>
      <motion.div {...pop(0.4)} className="mt-6 flex justify-between">
        {["M", "T", "W", "T", "F", "S", "S"].map((d, i) => (
          <span
            key={i}
            className={cn(
              "grid size-8 place-items-center rounded-full font-mono text-[11px]",
              i < 5 ? "bg-volt text-ink" : "bg-coal-2 text-mute",
            )}
          >
            {d}
          </span>
        ))}
      </motion.div>
      <div className="mt-6 flex flex-col divide-y divide-line rounded-2xl border border-line bg-coal">
        {[
          { icon: Sunrise, label: "Sunrise wake-up", on: true },
          { icon: Volume2, label: "Gentle volume ramp", on: true },
          { icon: Moon, label: "Bedtime reminder", on: false },
        ].map((r, i) => (
          <motion.div key={r.label} {...pop(0.5 + i * 0.08)} className="flex items-center gap-3 px-3.5 py-3">
            <r.icon className="size-4 text-bone/60" />
            <span className="flex-1 text-[12px]">{r.label}</span>
            <Toggle on={r.on} delay={0.6 + i * 0.1} />
          </motion.div>
        ))}
      </div>
    </div>
  );
}

export function ControlScreen() {
  const tiles = [
    { icon: Wifi, label: "Wi-Fi", sub: "Home", on: true, delay: 0 },
    { icon: Bluetooth, label: "Bluetooth", sub: "Buds", on: true, delay: 0 },
    { icon: Moon, label: "Do Not Disturb", sub: "Until 7 AM", on: true, delay: 0.9, hero: true },
    { icon: Flashlight, label: "Torch", sub: "Off", on: false, delay: 0 },
  ];
  return (
    <div className="flex h-full flex-col px-4 pt-5">
      <div className="grid grid-cols-2 gap-2.5">
        {tiles.map((t, i) => (
          <motion.div
            key={t.label}
            {...pop(0.05 + i * 0.06)}
            className="relative overflow-hidden rounded-3xl border border-line bg-coal p-3.5"
          >
            {t.on && (
              <motion.span
                className="absolute inset-0 bg-volt"
                initial={{ opacity: t.hero ? 0 : 1 }}
                animate={{ opacity: 1 }}
                transition={{ delay: t.delay, duration: 0.4 }}
              />
            )}
            <div className={cn("relative", t.on ? "text-ink" : "text-bone")}>
              <t.icon className="size-5" />
              <div className="mt-6 font-display text-[13px] font-semibold leading-tight">{t.label}</div>
              <div className={cn("font-mono text-[10px]", t.on ? "text-ink/60" : "text-mute")}>{t.sub}</div>
            </div>
          </motion.div>
        ))}
      </div>
      <motion.div {...pop(0.4)} className="mt-4 rounded-3xl border border-line bg-coal p-4">
        <div className="flex items-center justify-between font-mono text-[10px] uppercase tracking-[0.18em] text-mute">
          <span>Brightness</span>
          <Sun className="size-3.5" />
        </div>
        <div className="mt-3 h-10 overflow-hidden rounded-2xl bg-coal-2">
          <motion.div
            className="h-full rounded-2xl bg-volt"
            initial={{ width: "82%" }}
            animate={{ width: "36%" }}
            transition={{ delay: 1.2, duration: 1.1, ease: EASE }}
          />
        </div>
      </motion.div>
      <motion.div {...pop(1.3)} className="mt-4 flex items-center gap-2 font-mono text-[11px] text-volt">
        <Check className="size-3.5" strokeWidth={3} /> Focus mode on · brightness 36%
      </motion.div>
    </div>
  );
}
