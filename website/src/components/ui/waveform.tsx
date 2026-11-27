import { cn, r3, seeded } from "@/lib/utils";

type WaveformProps = {
  bars?: number;
  seed?: number;
  active?: boolean;
  className?: string;
  barClassName?: string;
};

/** Row of equalizer bars. The parent sets height and colour (bars use currentColor). */
export function Waveform({ bars = 24, seed = 0, active = true, className, barClassName }: WaveformProps) {
  return (
    <div className={cn("flex items-center gap-[3px]", className)} aria-hidden>
      {Array.from({ length: bars }, (_, i) => {
        const r = seeded(i + seed * 97);
        return (
          <span
            key={i}
            className={cn("w-[3px] shrink-0 rounded-full bg-current transition-transform duration-500", active && "eq", barClassName)}
            style={{
              height: `${r3(28 + r * 72)}%`,
              animationDuration: `${r3(0.65 + seeded(i + seed * 97 + 41) * 0.9)}s`,
              animationDelay: `${r3(-seeded(i + seed * 13 + 7) * 1.6)}s`,
              transform: active ? undefined : "scaleY(0.22)",
            }}
          />
        );
      })}
    </div>
  );
}
