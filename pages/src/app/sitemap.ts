import type { MetadataRoute } from "next";
import { siteURL } from "@/lib/site";
import { languageAlternates, localePaths } from "@/lib/i18n";

export const dynamic = "force-static";

export default function sitemap(): MetadataRoute.Sitemap {
  const languages = Object.fromEntries(
    Object.entries(languageAlternates).map(([locale, path]) => [
      locale,
      new URL(path, siteURL).href,
    ]),
  );
  return Object.values(localePaths).map((path) => ({
    url: new URL(path, siteURL).href,
    alternates: { languages },
  }));
}
