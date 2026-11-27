"use client";

import { motion } from "framer-motion";
import { OrbSphere } from "@/components/orb";
import { EASE } from "@/components/ui/reveal";

const COLUMNS = [
  {
    title: "Product",
    links: [
      { label: "Capabilities", href: "#capabilities" },
      { label: "How it works", href: "#how" },
      { label: "Live demo", href: "#demo" },
      { label: "Get started", href: "#get-started" },
    ],
  },
  {
    title: "Company",
    links: [
      { label: "About", href: "#" },
      { label: "Careers", href: "#" },
      { label: "Press kit", href: "#" },
      { label: "Contact", href: "#" },
    ],
  },
  {
    title: "Trust",
    links: [
      { label: "Privacy", href: "#" },
      { label: "Terms", href: "#" },
      { label: "Security", href: "#" },
    ],
  },
];

const letter = {
  hidden: { y: "105%" },
  show: { y: "0%", transition: { duration: 1.1, ease: EASE } },
};

export function Footer() {
  return (
    <footer className="px-4 pb-6 sm:px-6 lg:px-10">
      <div className="mx-auto max-w-[1360px] overflow-hidden rounded-[32px] border border-line bg-coal md:rounded-[44px]">
        <div className="grid gap-12 p-6 pt-10 md:p-12 lg:grid-cols-12">
          <div className="lg:col-span-5">
            <p className="max-w-sm font-display text-3xl font-bold uppercase leading-[0.95] tracking-[-0.04em] md:text-4xl">
              Your voice is the <span className="text-volt">interface.</span>
            </p>
            <p className="mt-4 max-w-xs text-sm leading-relaxed text-mute">
              LEO is a voice-first personal assistant for the apps you already live in.
            </p>
          </div>
          <nav aria-label="Footer" className="grid grid-cols-2 gap-8 sm:grid-cols-3 lg:col-span-7">
            {COLUMNS.map((col) => (
              <div key={col.title}>
                <div className="font-mono text-[10px] uppercase tracking-[0.2em] text-mute">{col.title}</div>
                <ul className="mt-4 space-y-2.5">
                  {col.links.map((l) => (
                    <li key={l.label}>
                      <a
                        href={l.href}
                        className="group inline-flex items-center gap-2 text-[15px] text-bone/75 transition-colors hover:text-bone"
                      >
                        <span className="h-px w-0 bg-volt transition-all duration-300 group-hover:w-3" />
                        {l.label}
                      </a>
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </nav>
        </div>

        {/* Giant wordmark — the O is the live orb */}
        <motion.p
          aria-label="LEO"
          initial="hidden"
          whileInView="show"
          viewport={{ once: true, amount: 0.4 }}
          variants={{ hidden: {}, show: { transition: { staggerChildren: 0.1 } } }}
          className="flex select-none items-end justify-center px-4 font-display text-volt text-[clamp(7rem,33vw,30rem)] font-bold uppercase leading-[0.78] tracking-[-0.08em]"
        >
          {["L", "E"].map((ch) => (
            <span key={ch} aria-hidden className="inline-block overflow-hidden pb-[0.04em]">
              <motion.span variants={letter} className="inline-block">
                {ch}
              </motion.span>
            </span>
          ))}
          {/* No overflow mask here — it would crop the orb's glow. Scale in instead. */}
          <span aria-hidden className="mb-[0.09em] ml-[0.04em] inline-block">
            <motion.span
              variants={{
                hidden: { scale: 0.3, opacity: 0 },
                show: { scale: 1, opacity: 1, transition: { duration: 1.1, ease: EASE } },
              }}
              className="block"
            >
              <motion.span
                className="block size-[0.7em]"
                animate={{ scale: [1, 1.03, 0.99, 1.02, 1] }}
                transition={{ duration: 2.6, repeat: Infinity, ease: "easeInOut" }}
              >
                <OrbSphere className="relative size-full" />
              </motion.span>
            </motion.span>
          </span>
        </motion.p>

        <div className="flex flex-col gap-2 border-t border-line px-6 py-5 font-mono text-[11px] uppercase tracking-[0.16em] text-mute sm:flex-row sm:justify-between md:px-12">
          <span>© 2026 LEO. All rights reserved.</span>
          <span>Made for voices, not thumbs.</span>
        </div>
      </div>
    </footer>
  );
}
