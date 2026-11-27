# LEO — landing page

Marketing site for the LEO voice assistant. Built with Next.js 16 (App Router), React 19, TypeScript, Tailwind CSS 4, Framer Motion and Lucide icons.

## Run locally

```bash
cd website
npm install
npm run dev        # http://localhost:3000
```

Other scripts: `npm run build`, `npm start`, `npm run typecheck`.

## Where things live

- `src/app/globals.css` — colour tokens (`volt`, `ink`, `coal`, `bone`, …), the orb's gradients and CSS keyframes. Change the palette here.
- `src/app/page.tsx` — section order.
- `src/components/` — one file per section (`hero`, `capabilities`, `how-it-works`, `in-action`, `final-cta`, `footer`), plus the `orb`, `phone-screens` and shared `ui/` pieces.

## Before launch

- Get Started and footer links are placeholders (`#`).
- The "40+ apps", "< 1 second" and "On-device" chips in the hero are placeholder claims.
- App icons in `app-glyphs.tsx` are simplified drawings, not official brand marks.

## Deploying

On Vercel (or similar), set the project's root directory to `website`.
