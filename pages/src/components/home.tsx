import Image from "next/image";
import { ArrowDown, ArrowUpRight, Download } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "@/components/ui/accordion";
import { cn } from "@/lib/utils";
import { messages, localePaths, type Locale } from "@/lib/i18n";

const github = "https://github.com/yeliex/tokentick";
const download = `${github}/releases/latest`;
function Brand() {
  return (
    <span className="inline-flex items-center gap-2.5">
      <span className="brand-icon">
        <Image
          src="/mark-dark.svg"
          width={30}
          height={30}
          alt=""
        />
      </span>
      <span className="text-lg font-semibold tracking-tight">TokenTick</span>
    </span>
  );
}

export function Home({ locale }: { locale: Locale }) {
  const t = messages[locale];
  const otherLocale = locale === "en" ? "zh-CN" : "en";
  return (
    <>
      <a href="#main" className="skip-link">
        {t.skip}
      </a>
      <header className="site-header">
        <nav
          aria-label={t.navigation}
          className="shell flex h-22 items-center justify-between gap-3"
        >
          <a href="#" aria-label={t.home}>
            <Brand />
          </a>
          <div className="flex items-center gap-3 text-sm sm:gap-7">
            <a href="#features" className="nav-link hidden sm:block">
              {t.featuresLabel}
            </a>
            <a href="#faq" className="nav-link hidden sm:block">
              {t.faqLabel}
            </a>
            <a href={github} className="nav-link hidden sm:block">
              GitHub
            </a>
            <a
              href={localePaths[otherLocale]}
              hrefLang={otherLocale}
              lang={otherLocale}
              className="nav-link whitespace-nowrap"
            >
              {otherLocale === "en" ? "English" : "简体中文"}
            </a>
            <Button asChild size="sm">
              <a href={download}>
                {t.download}
                <ArrowUpRight data-icon="inline-end" />
              </a>
            </Button>
          </div>
        </nav>
      </header>
      <main id="main">
        <section className="shell hero" aria-labelledby="hero-title">
          <div className="hero-copy">
            <h1 id="hero-title">
              {t.heroTitle}
              <br />
              <span className="text-brand">{t.heroAccent}</span>
            </h1>
            <p className="hero-description">
              {t.heroDescription}
            </p>
            <div className="mt-8 flex flex-wrap items-center gap-3">
              <Button asChild size="lg">
                <a href={download}>
                  <Download data-icon="inline-start" />
                  {t.downloadMac}
                </a>
              </Button>
              <Button asChild variant="outline" size="lg">
                <a href={github}>
                  {t.viewGithub}
                  <ArrowUpRight data-icon="inline-end" />
                </a>
              </Button>
            </div>
            <p className="mt-5 text-sm text-muted-foreground">
              macOS 26+{" "}
              <span aria-hidden="true" className="px-2">
                ·
              </span>{" "}
              Apple Silicon
            </p>
            <a href="#features" className="hero-explore">
              {t.explore}
              <ArrowDown className="size-4" aria-hidden="true" />
            </a>
          </div>
          <figure className="hero-media">
            <Image
              src="/screenshots/menu.png"
              alt={t.menuAlt}
              width={674}
              height={1544}
              preload
              sizes="(max-width: 640px) 280px, 310px"
              className="menu-image"
            />
            <figcaption>{t.menuCaption}</figcaption>
          </figure>
        </section>
        <div id="features" className="shell">
          {t.features.map((feature, index) => (
            <section
              key={feature.id}
              id={feature.id}
              className={cn(
                "feature-row",
                index % 2 === 1 && "feature-reverse",
              )}
              aria-labelledby={`${feature.id}-title`}
            >
              <div className="feature-copy">
                <p className="feature-label">{feature.label}</p>
                <h2 id={`${feature.id}-title`}>{feature.title}</h2>
                <p className="feature-description">{feature.description}</p>
                <ul className="feature-details">
                  {feature.details.map((detail) => (
                    <li key={detail}>{detail}</li>
                  ))}
                </ul>
              </div>
              <figure className="feature-media">
                <a
                  href={`/screenshots/${feature.image}.png`}
                  target="_blank"
                  rel="noreferrer"
                  aria-label={`${t.fullSize} ${feature.label}`}
                >
                  <Image
                    src={`/screenshots/${feature.image}.png`}
                    alt={feature.alt}
                    width={2304}
                    height={1584}
                    sizes="(max-width: 900px) 100vw, 740px"
                  />
                </a>
                <figcaption>
                  {t.sampleData} <span aria-hidden="true">·</span> {t.exploreImage}{" "}
                  <ArrowUpRight className="size-3" aria-hidden="true" />
                </figcaption>
              </figure>
            </section>
          ))}
        </div>
        <section
          id="faq"
          className="shell faq-section"
          aria-labelledby="faq-title"
        >
          <div>
            <p className="feature-label">{t.beforeInstall}</p>
            <h2 id="faq-title">
              {t.faqTitle}
              <br />
              {t.faqAccent}
            </h2>
            <p className="mt-5 max-w-xs text-muted-foreground">
              {t.faqDescription}
            </p>
            <a
              href={`${github}#installation`}
              className="inline-flex items-center gap-2 mt-6 text-sm text-brand hover:underline"
            >
              {t.installation}
              <ArrowUpRight className="size-4" aria-hidden="true" />
            </a>
          </div>
          <Accordion type="single" collapsible className="w-full">
            {t.faqs.map((faq, index) => (
              <AccordionItem key={faq.question} value={`faq-${index}`}>
                <AccordionTrigger>{faq.question}</AccordionTrigger>
                <AccordionContent forceMount>{faq.answer}</AccordionContent>
              </AccordionItem>
            ))}
          </Accordion>
        </section>
        <section className="closing shell" aria-labelledby="download-title">
          <Image
            src="/icon-dark.png"
            alt=""
            width={72}
            height={72}
          />
          <h2 id="download-title">{t.closingTitle}</h2>
          <p className="text-muted-foreground">
            {t.closingDescription}
          </p>
          <Button asChild size="lg">
            <a href={download}>
              <Download data-icon="inline-start" />
              {t.downloadMac}
            </a>
          </Button>
          <p className="text-xs text-muted-foreground">
            macOS 26+ · Apple Silicon · English & 简体中文
          </p>
        </section>
      </main>
      <footer className="shell site-footer">
        <div>
          <Brand />
          <p className="mt-3 text-xs text-muted-foreground">
            {t.disclaimer}
          </p>
        </div>
        <nav
          aria-label={t.footerNavigation}
          className="flex flex-wrap gap-6 text-sm text-muted-foreground"
        >
          <a href={github}>GitHub</a>
          <a href={`${github}#installation`}>{t.documentation}</a>
          <a href={`${github}/releases`}>{t.releases}</a>
          <a href={`${github}/issues`}>{t.support}</a>
        </nav>
      </footer>
    </>
  );
}
