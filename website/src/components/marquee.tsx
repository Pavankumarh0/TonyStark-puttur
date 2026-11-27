import { Fragment } from "react";

const VERBS = ["Message", "Call", "Read", "Open", "Play", "Search", "Wake", "Control"];
const PHRASES = ["Stop tapping", "Start talking", "Just say it", "Hands-free", "Eyes-free"];

function Star() {
  return (
    <svg viewBox="0 0 24 24" className="size-[0.55em] shrink-0" aria-hidden>
      <path d="M12 0l2.6 9.4L24 12l-9.4 2.6L12 24l-2.6-9.4L0 12l9.4-2.6z" fill="currentColor" />
    </svg>
  );
}

function Track({ items, className }: { items: string[]; className: string }) {
  // Four identical runs: translateX(-50%) shifts by exactly two, so it loops seamlessly
  // and each half is always wider than the viewport.
  return (
    <div className={`flex w-max ${className}`}>
      {[0, 1, 2, 3].map((copy) => (
        <div key={copy} className="flex shrink-0 items-center" aria-hidden={copy > 0}>
          {items.map((w) => (
            <Fragment key={w}>
              <span className="px-6 md:px-9">{w}</span>
              <Star />
            </Fragment>
          ))}
        </div>
      ))}
    </div>
  );
}

/** Two crossed tapes — RIFT-style energy, LEO's vocabulary. */
export function Marquee() {
  return (
    <section aria-label="What LEO can do" className="relative overflow-hidden py-16 md:py-24">
      <div className="relative -mx-[5vw] -rotate-[2.5deg] bg-volt-deep py-4 md:py-5">
        <Track
          items={PHRASES}
          className="animate-marquee-rev font-display text-3xl font-bold uppercase tracking-[-0.04em] text-ink/75 md:text-5xl"
        />
      </div>
      <div className="relative -mx-[5vw] -mt-10 rotate-[2deg] bg-volt py-4 text-ink shadow-[0_30px_80px_-30px_rgb(46_255_110/0.6)] md:-mt-14 md:py-6">
        <Track
          items={VERBS}
          className="animate-marquee font-display text-4xl font-bold uppercase tracking-[-0.045em] md:text-7xl"
        />
      </div>
    </section>
  );
}
