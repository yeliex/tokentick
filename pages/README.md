# TokenTick website

Single-page product website built with Next.js App Router, Tailwind CSS, and shadcn/ui. `pages/` is the website project directory, not the Next.js Pages Router.

```sh
pnpm install --frozen-lockfile
pnpm dev
pnpm lint
pnpm build
```

The static site is exported to `out/`. Vercel deploys this directory as a Next.js project with `pages/` as the repository root directory and `master` as the production branch. The production URL is https://tokentick.makesth.fun. `src/lib/site.ts` defines the canonical origin used by metadata, robots.txt, and sitemap.xml. Cloudflare manages the domain's DNS; the website is hosted on Vercel.

Screenshots in `public/screenshots/` show sample data. Feature screenshots come from the repository's `assets/screenshots/`; `menu.png` is a separate capture including the system menu bar, starting at the TokenTick icon. When replacing it, keep its intrinsic dimensions in the homepage in sync. The website always uses the app's dark graphite/mint palette and dark brand assets, regardless of the system color scheme.

Downloads link to GitHub Releases. Documentation and support stay on GitHub. Vercel Web Analytics records website visits through the root layout. No third-party fonts are loaded.

## Localization

English is served at `/` and Simplified Chinese at `/zh-CN`. The header links between the two static pages; the URL determines the language, without automatic redirects. Both use the same homepage component and existing screenshots. Typed dictionaries in `src/lib/messages/` cover page copy, accessible labels, image descriptions, and metadata. Locale root layouts set the HTML language at build time. Canonical URLs, language alternates (including the English `x-default`), Open Graph metadata, and the sitemap describe both versions. No server middleware or additional localization dependency is required.
