import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono, Space_Grotesk } from "next/font/google";
import "./globals.css";

const display = Space_Grotesk({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700"],
  variable: "--font-space-grotesk",
});

const sans = Geist({
  subsets: ["latin"],
  variable: "--font-geist",
});

const mono = Geist_Mono({
  subsets: ["latin"],
  variable: "--font-geist-mono",
});

export const metadata: Metadata = {
  title: "LEO — Your entire digital world. Under your command.",
  description:
    "Meet LEO — your intelligent personal assistant that listens, understands, and takes action through your voice.",
  openGraph: {
    title: "LEO — Stop tapping. Start talking.",
    description:
      "Your intelligent personal assistant that listens, understands, and takes action through your voice.",
    type: "website",
  },
};

export const viewport: Viewport = {
  themeColor: "#04190c",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${display.variable} ${sans.variable} ${mono.variable}`}>
      <body className="font-sans">{children}</body>
    </html>
  );
}
