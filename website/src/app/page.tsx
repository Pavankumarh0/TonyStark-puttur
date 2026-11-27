import { Capabilities } from "@/components/capabilities";
import { FinalCta } from "@/components/final-cta";
import { Footer } from "@/components/footer";
import { Hero } from "@/components/hero";
import { HowItWorks } from "@/components/how-it-works";
import { InAction } from "@/components/in-action";
import { Marquee } from "@/components/marquee";
import { Nav } from "@/components/nav";
import { Providers } from "@/components/providers";

export default function Home() {
  return (
    <Providers>
      <a
        href="#main"
        className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[200] focus:rounded-full focus:bg-volt focus:px-4 focus:py-2 focus:text-ink"
      >
        Skip to content
      </a>
      <Nav />
      <main id="main">
        <Hero />
        <Marquee />
        <Capabilities />
        <HowItWorks />
        <InAction />
        <FinalCta />
      </main>
      <Footer />
    </Providers>
  );
}
