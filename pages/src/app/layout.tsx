import type { Metadata } from "next";
import { Analytics } from "@vercel/analytics/next";
import "./globals.css";
import { siteURL } from "@/lib/site";
const title = "TokenTick — Codex Usage Tracker for Mac";
const description =
  "Track Codex usage limits and reset times from your Mac menu bar. Explore token usage, estimated API costs, and local disk space with TokenTick.";
export const metadata: Metadata = {
  title,
  description,
  metadataBase: new URL(siteURL),
  alternates: { canonical: "/" },
  openGraph: {
    title,
    description,
    type: "website",
    locale: "en_US",
    url: siteURL,
    images: [
      {
        url: "/screenshots/dashboard.png",
        alt: "TokenTick usage dashboard with sample data",
      },
    ],
  },
  twitter: { card: "summary", title, description },
  icons: {
    icon: [
      { url: "/mark-light.svg", media: "(prefers-color-scheme: light)" },
      { url: "/mark-dark.svg", media: "(prefers-color-scheme: dark)" },
    ],
  },
};
export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>
        {children}
        <Analytics />
      </body>
    </html>
  );
}
