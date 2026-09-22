import { SiteLayout } from "@/components/site-layout";
import { localizedMetadata } from "@/lib/i18n";

export const metadata = localizedMetadata("en");

export default function Layout({ children }: { children: React.ReactNode }) {
  return <SiteLayout locale="en">{children}</SiteLayout>;
}
