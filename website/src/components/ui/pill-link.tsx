import { ArrowUpRight } from "lucide-react";
import { cn } from "@/lib/utils";

type Variant = "volt" | "ghost" | "ink";

const surface: Record<Variant, string> = {
  volt: "bg-volt text-ink hover:shadow-[0_0_0_6px_rgb(46_255_110/0.14),0_18px_50px_-12px_rgb(46_255_110/0.55)]",
  ghost: "border border-volt/20 text-bone hover:border-volt/50 hover:bg-volt/[0.04]",
  ink: "bg-ink text-volt hover:shadow-[0_24px_60px_-18px_rgb(0_0_0/0.8)]",
};

const knob: Record<Variant, string> = {
  volt: "bg-ink text-volt",
  ghost: "bg-volt/10 text-bone group-hover:bg-volt group-hover:text-ink",
  ink: "bg-volt text-ink",
};

type PillLinkProps = {
  href: string;
  children: string;
  variant?: Variant;
  size?: "md" | "lg" | "xl";
  icon?: React.ReactNode;
  className?: string;
};

/** Pill CTA with a rolling label and a spinning arrow knob. */
export function PillLink({ href, children, variant = "volt", size = "md", icon, className }: PillLinkProps) {
  const sizes = {
    md: { root: "gap-3 py-1.5 pl-5 pr-1.5 text-sm", knob: "size-9", icon: "size-4" },
    lg: { root: "gap-4 py-2 pl-7 pr-2 text-base", knob: "size-11", icon: "size-5" },
    xl: { root: "gap-5 py-2.5 pl-9 pr-2.5 text-xl md:text-2xl", knob: "size-14 md:size-16", icon: "size-6 md:size-7" },
  }[size];

  return (
    <a
      href={href}
      className={cn(
        "group inline-flex items-center rounded-full font-display font-semibold uppercase tracking-tight transition-[box-shadow,background-color,border-color,transform] duration-300 active:scale-[0.98]",
        sizes.root,
        surface[variant],
        className,
      )}
    >
      <span className="relative block overflow-hidden leading-[1.15]">
        <span className="block transition-transform duration-500 ease-[cubic-bezier(.2,.8,.2,1)] group-hover:-translate-y-full">
          {children}
        </span>
        <span
          aria-hidden
          className="absolute inset-0 block translate-y-full transition-transform duration-500 ease-[cubic-bezier(.2,.8,.2,1)] group-hover:translate-y-0"
        >
          {children}
        </span>
      </span>
      <span
        className={cn(
          "grid shrink-0 place-items-center rounded-full transition-[transform,background-color,color] duration-500 ease-[cubic-bezier(.2,.8,.2,1)] group-hover:rotate-45",
          sizes.knob,
          knob[variant],
        )}
      >
        {icon ?? <ArrowUpRight className={sizes.icon} strokeWidth={2.2} />}
      </span>
    </a>
  );
}
