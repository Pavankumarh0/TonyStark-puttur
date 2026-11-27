import { cn } from "@/lib/utils";

/** Circular rotating text badge. Caller supplies display (e.g. `grid`) and size. */
export function RotatingBadge({
  id,
  text,
  children,
  className,
  textClassName,
}: {
  id: string;
  text: string;
  children?: React.ReactNode;
  className?: string;
  textClassName?: string;
}) {
  return (
    <div className={cn("relative place-items-center rounded-full", className)}>
      <svg viewBox="0 0 100 100" className="absolute inset-0 size-full animate-spin-slow" aria-hidden>
        <defs>
          <path id={id} d="M50,50 m-39,0 a39,39 0 1,1 78,0 a39,39 0 1,1 -78,0" />
        </defs>
        <text className={cn("fill-current font-mono text-[9px] font-medium uppercase", textClassName)}>
          <textPath href={`#${id}`} textLength={243} lengthAdjust="spacing">
            {text}
          </textPath>
        </text>
      </svg>
      {children}
    </div>
  );
}

function burstPoints(spikes: number) {
  return Array.from({ length: spikes * 2 }, (_, i) => {
    const r = i % 2 ? 41 : 50;
    const a = (Math.PI * i) / spikes - Math.PI / 2;
    return `${(50 + r * Math.cos(a)).toFixed(2)},${(50 + r * Math.sin(a)).toFixed(2)}`;
  }).join(" ");
}

/** Starburst sticker. Caller supplies position, display (e.g. `grid`) and size. */
export function Burst({
  children,
  className,
  rotate = -10,
  spikes = 18,
}: {
  children: React.ReactNode;
  className?: string;
  rotate?: number;
  spikes?: number;
}) {
  return (
    <div className={cn("place-items-center", className)} style={{ rotate: `${rotate}deg` }}>
      <svg viewBox="0 0 100 100" className="absolute inset-0 size-full" aria-hidden>
        <polygon points={burstPoints(spikes)} className="fill-volt" />
      </svg>
      <span className="relative text-center font-display text-sm font-bold uppercase leading-[0.9] tracking-tight text-ink">
        {children}
      </span>
    </div>
  );
}

/** Tilted label sticker. */
export function Tag({ children, className, rotate = -5 }: { children: React.ReactNode; className?: string; rotate?: number }) {
  return (
    <span
      className={cn(
        "inline-block rounded-xl border-2 border-ink bg-volt px-3.5 py-2 font-display text-sm font-bold uppercase leading-[0.95] tracking-tight text-ink shadow-[4px_4px_0_0_#12c24f]",
        className,
      )}
      style={{ rotate: `${rotate}deg` }}
    >
      {children}
    </span>
  );
}
