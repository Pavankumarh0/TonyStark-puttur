import { AlarmClock, Phone } from "lucide-react";
import type { SVGProps } from "react";

/*
 * Simplified, monochrome app glyphs drawn in Lucide's stroke style
 * (Lucide no longer ships brand marks). They inherit currentColor.
 */

type GlyphProps = SVGProps<SVGSVGElement>;

const base = {
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.8,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
};

export function WhatsAppGlyph(props: GlyphProps) {
  return (
    <svg {...base} {...props}>
      <path d="M3.6 20.4 4.9 16.5A8.6 8.6 0 1 1 8 19.3Z" />
      <path d="M9.2 8.3c.3-.5.9-.5 1.2 0l.6 1.2c.2.4.1.8-.2 1.1l-.4.4c.5 1.1 1.5 2.1 2.6 2.6l.4-.4c.3-.3.7-.4 1.1-.2l1.2.6c.5.3.5.9 0 1.2-.6.5-1.4.8-2.2.6-2.4-.6-4.3-2.5-4.9-4.9-.2-.8.1-1.6.6-2.2Z" />
    </svg>
  );
}

export function InstagramGlyph(props: GlyphProps) {
  return (
    <svg {...base} {...props}>
      <rect x="3" y="3" width="18" height="18" rx="5.2" />
      <circle cx="12" cy="12" r="4.1" />
      <circle cx="17.4" cy="6.6" r="0.9" fill="currentColor" stroke="none" />
    </svg>
  );
}

export function YouTubeGlyph(props: GlyphProps) {
  return (
    <svg {...base} {...props}>
      <rect x="2.5" y="5.5" width="19" height="13" rx="4" />
      <path d="M10.2 9.4v5.2l4.4-2.6Z" fill="currentColor" />
    </svg>
  );
}

export function GmailGlyph(props: GlyphProps) {
  return (
    <svg {...base} {...props}>
      <rect x="2.8" y="5" width="18.4" height="14" rx="2.4" />
      <path d="M3.4 6.4 12 13l8.6-6.6" />
      <path d="M5.6 18.6v-8.2M18.4 18.6v-8.2" />
    </svg>
  );
}

export const APP_GLYPHS = {
  whatsapp: WhatsAppGlyph,
  instagram: InstagramGlyph,
  youtube: YouTubeGlyph,
  gmail: GmailGlyph,
  phone: Phone,
  alarm: AlarmClock,
} as const;

export type AppKey = keyof typeof APP_GLYPHS;
