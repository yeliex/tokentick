import { SiteLayout } from "@/components/site-layout";
import { localizedMetadata } from "@/lib/i18n";

export const metadata = localizedMetadata("zh-CN");

export default function Layout({ children }: { children: React.ReactNode }) {
  return <SiteLayout locale="zh-CN">{children}</SiteLayout>;
}
