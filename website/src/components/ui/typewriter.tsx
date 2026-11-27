"use client";

import { useEffect, useState } from "react";
import { cn } from "@/lib/utils";

type TypewriterProps = {
  text: string;
  /** ms per character */
  speed?: number;
  /** ms before typing begins */
  delay?: number;
  start?: boolean;
  caret?: boolean;
  className?: string;
  onDone?: () => void;
};

/** Types text out character by character. Remount (via key) to restart. */
export function Typewriter({ text, speed = 32, delay = 0, start = true, caret = true, className, onDone }: TypewriterProps) {
  const [count, setCount] = useState(0);

  useEffect(() => {
    if (!start) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setCount(text.length);
      onDone?.();
      return;
    }
    let i = 0;
    let interval: ReturnType<typeof setInterval> | undefined;
    const timeout = setTimeout(() => {
      interval = setInterval(() => {
        i += 1;
        setCount(i);
        if (i >= text.length) {
          clearInterval(interval);
          onDone?.();
        }
      }, speed);
    }, delay);
    return () => {
      clearTimeout(timeout);
      clearInterval(interval);
    };
    // onDone is intentionally not a dependency: callers pass inline closures.
  }, [text, speed, delay, start]);

  const typing = start && count < text.length;

  return (
    <span className={className}>
      <span className="sr-only">{text}</span>
      <span aria-hidden>{text.slice(0, count)}</span>
      {caret && (
        <span
          aria-hidden
          className={cn(
            "ml-[1px] inline-block h-[1em] w-[2px] translate-y-[0.15em] bg-volt",
            typing ? "opacity-100" : "animate-pulse",
          )}
        />
      )}
    </span>
  );
}
