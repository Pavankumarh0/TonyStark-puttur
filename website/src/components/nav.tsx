"use client";

import { useState } from "react";
import { AnimatePresence, motion, useMotionValueEvent, useScroll } from "framer-motion";
import { ArrowUpRight, Menu, X } from "lucide-react";
import { EASE } from "@/components/ui/reveal";
import { cn } from "@/lib/utils";

const LINKS = [
  { href: "#capabilities", label: "Capabilities" },
  { href: "#how", label: "How it works" },
  { href: "#demo", label: "In action" },
];

export function Logo({ className }: { className?: string }) {
  return (
    <a href="#top" className={cn("group flex items-center gap-2", className)} aria-label="LEO home">
      <span className="orb-mini size-6 rounded-full transition-transform duration-500 group-hover:scale-110" />
      <span className="font-display text-xl font-bold tracking-[-0.06em]">LEO</span>
    </a>
  );
}

export function Nav() {
  const [open, setOpen] = useState(false);
  const [scrolled, setScrolled] = useState(false);
  const { scrollY } = useScroll();
  useMotionValueEvent(scrollY, "change", (v) => setScrolled(v > 24));

  return (
    <motion.header
      initial={{ y: -40, opacity: 0 }}
      animate={{ y: 0, opacity: 1 }}
      transition={{ duration: 0.9, ease: EASE }}
      className="fixed inset-x-0 top-0 z-50 px-4 pt-4 sm:px-6 lg:px-10"
    >
      <nav
        className={cn(
          "mx-auto flex max-w-[1360px] items-center justify-between rounded-full border py-2 pl-5 pr-2 transition-[background-color,border-color,box-shadow] duration-500",
          scrolled || open
            ? "border-volt/10 bg-ink/75 shadow-[0_10px_40px_-15px_rgb(0_0_0/0.8)] backdrop-blur-xl"
            : "border-volt/10 bg-ink/30 backdrop-blur-md",
        )}
      >
        <div className="flex items-center gap-6">
          <Logo />
          <span className="hidden h-5 w-px bg-volt/15 md:block" />
          <ul className="hidden items-center gap-1 md:flex">
            {LINKS.map((l) => (
              <li key={l.href}>
                <a
                  href={l.href}
                  className="group relative rounded-full px-3.5 py-2 font-mono text-[11px] uppercase tracking-[0.16em] text-bone/65 transition-colors hover:text-bone"
                >
                  {l.label}
                  <span className="absolute inset-x-3.5 bottom-1 h-px origin-left scale-x-0 bg-volt transition-transform duration-500 group-hover:scale-x-100" />
                </a>
              </li>
            ))}
          </ul>
        </div>

        <div className="flex items-center gap-2">
          <a
            href="#get-started"
            className="group hidden items-center gap-2 rounded-full bg-volt py-2 pl-4 pr-2 font-mono text-[11px] font-semibold uppercase tracking-[0.16em] text-ink transition-shadow hover:shadow-[0_0_0_5px_rgb(46_255_110/0.15),0_0_30px_rgb(46_255_110/0.45)] sm:flex"
          >
            Get LEO
            <span className="grid size-6 place-items-center rounded-full bg-ink text-volt transition-transform duration-500 group-hover:rotate-45">
              <ArrowUpRight className="size-3.5" strokeWidth={2.4} />
            </span>
          </a>
          <button
            type="button"
            onClick={() => setOpen((o) => !o)}
            className="grid size-10 place-items-center rounded-full bg-volt text-ink transition-transform active:scale-95 md:hidden"
            aria-label={open ? "Close menu" : "Open menu"}
            aria-expanded={open}
          >
            {open ? <X className="size-5" /> : <Menu className="size-5" />}
          </button>
        </div>
      </nav>

      <AnimatePresence>
        {open && (
          <motion.div
            initial={{ opacity: 0, y: -12, scale: 0.98 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: -12, scale: 0.98 }}
            transition={{ duration: 0.35, ease: EASE }}
            className="mx-auto mt-2 max-w-[1360px] overflow-hidden rounded-[28px] border border-volt/10 bg-ink/90 p-3 backdrop-blur-xl md:hidden"
          >
            {[...LINKS, { href: "#get-started", label: "Get LEO" }].map((l, i) => (
              <motion.a
                key={l.href}
                href={l.href}
                onClick={() => setOpen(false)}
                initial={{ opacity: 0, x: -10 }}
                animate={{ opacity: 1, x: 0 }}
                transition={{ delay: 0.05 * i + 0.1, ease: EASE }}
                className="flex items-center justify-between rounded-2xl px-4 py-4 font-display text-3xl font-bold uppercase tracking-[-0.04em] transition-colors hover:bg-volt/5"
              >
                {l.label}
                <ArrowUpRight className="size-6 text-volt" />
              </motion.a>
            ))}
          </motion.div>
        )}
      </AnimatePresence>
    </motion.header>
  );
}
