# TokenTick website

Single-page product website built with Next.js App Router, Tailwind CSS, and shadcn/ui. `pages/` is the website project directory, not the Next.js Pages Router.

```sh
pnpm install --frozen-lockfile
pnpm dev
pnpm lint
pnpm build
```

The static site is exported to `out/`. Vercel deploys this directory as a Next.js project with `pages/` as the repository root directory and `master` as the production branch. The production URL is https://tokentick.makesth.fun. `src/lib/site.ts` defines the canonical origin used by metadata, robots.txt, and sitemap.xml. Cloudflare manages the domain's DNS; the website is hosted on Vercel.

Screenshots in `public/screenshots/` show sample data. Feature screenshots come from the repository's `assets/screenshots/`; `menu.png` is a separate capture including the system menu bar, starting at the TokenTick icon. When replacing it, keep its intrinsic dimensions in the homepage in sync. Brand assets use the app's warm white/amber and graphite/mint appearances. The website follows the system color scheme.

Downloads link to GitHub Releases. Documentation and support stay on GitHub. No website analytics or third-party fonts are loaded.
