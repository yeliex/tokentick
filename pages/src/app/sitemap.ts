import type { MetadataRoute } from "next";
import { siteURL } from "@/lib/site";
export const dynamic = "force-static";
export default function sitemap(): MetadataRoute.Sitemap {
  return [{ url: new URL("/", siteURL).href }];
}
