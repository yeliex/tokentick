import { Analytics } from "@vercel/analytics/next";
import type { Locale } from "@/lib/i18n";
import "@/app/globals.css";

export function SiteLayout({ children, locale }: {
  children: React.ReactNode;
  locale: Locale;
}) {
  return (
    <html lang={locale}>
      <body>
        {children}
        <Analytics />
      </body>
    </html>
  );
}
