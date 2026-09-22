import type { Metadata } from "next";
import { siteURL } from "./site";
import { en } from "./messages/en";
import { zhCN } from "./messages/zh-CN";

export const messages = { en, "zh-CN": zhCN };
export type Locale = keyof typeof messages;
export const localePaths = { en: "/", "zh-CN": "/zh-CN" } as const;
export const languageAlternates = { ...localePaths, "x-default": "/" };

export function localizedMetadata(locale: Locale): Metadata {
  const { title, description, dashboardAlt } = messages[locale];
  return {
    title,
    description,
    metadataBase: new URL(siteURL),
    alternates: { canonical: localePaths[locale], languages: languageAlternates },
    openGraph: {
      title,
      description,
      type: "website",
      locale: locale === "en" ? "en_US" : "zh_CN",
      alternateLocale: locale === "en" ? "zh_CN" : "en_US",
      url: localePaths[locale],
      images: [{ url: "/screenshots/dashboard.png", alt: dashboardAlt }],
    },
    twitter: { card: "summary", title, description },
    icons: {
      icon: "/mark-dark.svg",
    },
  };
}
