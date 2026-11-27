"use client";

import { Fragment } from "react";
import { motion, type Variants } from "framer-motion";
import { cn } from "@/lib/utils";

export const EASE = [0.22, 1, 0.36, 1] as const;

type RevealProps = {
  children: React.ReactNode;
  className?: string;
  delay?: number;
  y?: number;
};

/** Fade + rise when scrolled into view. */
export function Reveal({ children, className, delay = 0, y = 32 }: RevealProps) {
  return (
    <motion.div
      className={className}
      initial={{ opacity: 0, y }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "0px 0px -12% 0px" }}
      transition={{ duration: 0.9, delay, ease: EASE }}
    >
      {children}
    </motion.div>
  );
}

type Word = string | { text: string; className?: string };
type Line = string | Word[];

const wordVariants: Variants = {
  hidden: { y: "115%", rotate: 5 },
  show: { y: "0%", rotate: 0, transition: { duration: 1, ease: EASE } },
};

const tags = { h1: motion.h1, h2: motion.h2, h3: motion.h3, p: motion.p };

type SplitHeadingProps = {
  as?: keyof typeof tags;
  lines: Line[];
  className?: string;
  lineClassName?: string;
  delay?: number;
  stagger?: number;
  /** Animate on mount instead of on scroll. */
  immediate?: boolean;
};

/** Heading whose words slide up out of a mask, line by line. */
export function SplitHeading({
  as = "h2",
  lines,
  className,
  lineClassName,
  delay = 0,
  stagger = 0.06,
  immediate = false,
}: SplitHeadingProps) {
  const Tag = tags[as];
  const trigger = immediate
    ? { animate: "show" }
    : { whileInView: "show", viewport: { once: true, margin: "0px 0px -10% 0px" } };

  return (
    <Tag
      className={className}
      initial="hidden"
      {...trigger}
      variants={{ hidden: {}, show: { transition: { staggerChildren: stagger, delayChildren: delay } } }}
    >
      {lines.map((line, li) => {
        const words: Word[] = typeof line === "string" ? line.split(" ") : line;
        return (
          <span key={li} className={cn("block", lineClassName)}>
            {words.map((w, wi) => {
              const text = typeof w === "string" ? w : w.text;
              const cls = typeof w === "string" ? undefined : w.className;
              return (
                <Fragment key={wi}>
                  <span className="-mb-[0.12em] inline-block overflow-hidden pb-[0.12em] align-bottom">
                    <motion.span
                      className={cn("inline-block origin-[0%_100%] will-change-transform", cls)}
                      variants={wordVariants}
                    >
                      {text}
                    </motion.span>
                  </span>
                  {wi < words.length - 1 ? " " : null}
                </Fragment>
              );
            })}
          </span>
        );
      })}
    </Tag>
  );
}

/** Small mono eyebrow label: "(02) Capabilities". */
export function SectionLabel({ index, children, className }: { index: string; children: React.ReactNode; className?: string }) {
  return (
    <Reveal className={cn("flex items-center gap-3 font-mono text-xs uppercase tracking-[0.18em] text-mute", className)}>
      <span className="size-1.5 rounded-full bg-volt shadow-[0_0_10px_#2eff6e]" />
      <span className="text-bone/80">({index})</span>
      <span>{children}</span>
    </Reveal>
  );
}
