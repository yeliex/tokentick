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

const github = "https://github.com/yeliex/tokentick";
const download = `${github}/releases/latest`;
const features = [
  {
    id: "limits",
    label: "Limits & resets",
    title: "Know your limits.\nPlan your next session.",
    description:
      "See your Codex usage limits, reset times, available resets, and credits together. Get an estimate of when your allowance will run out—or how much will remain at reset.",
    details: [
      "Five-hour and weekly windows, at a glance.",
      "Forecasts that adapt to your usage pace.",
    ],
    image: "dashboard",
    alt: "TokenTick Overview showing Codex usage limits, reset times, forecasts, and token totals",
  },
  {
    id: "costs",
    label: "Tokens & costs",
    title: "Your tokens. Your costs.\nIn focus.",
    description:
      "Explore Codex token usage and estimated API costs by model, usage mode, and reasoning effort. See the difference that caching, Fast mode, and long context make.",
    details: [
      "From today to your entire usage history.",
      "API-equivalent estimates, not subscription charges.",
    ],
    image: "model-usage",
    alt: "TokenTick model usage rings with token and cost breakdowns",
  },
  {
    id: "tasks",
    label: "Projects & tasks",
    title: "Follow the tokens\nto the task.",
    description:
      "Find the projects and tasks behind your usage. Filter by date or model, drill into individual requests, and turn a big total into something you can actually understand.",
    details: [
      "Explore by day, project, or task.",
      "Export detailed usage as JSON with the CLI.",
    ],
    image: "usage-details",
    alt: "TokenTick usage details with date filters and task-level token and estimated cost totals",
  },
  {
    id: "storage",
    label: "Local storage",
    title: "A clearer view of\nCodex storage.",
    description:
      "See how much disk space Codex uses, from conversation records to worktrees and projectless tasks. Find the directories behind the numbers and reveal them in Finder.",
    details: [
      "Scan on demand. See when data was last checked.",
      "Read-only inspection. Your files stay untouched.",
    ],
    image: "storage",
    alt: "TokenTick Codex storage categories and directory sizes",
  },
];
const faqs = [
  {
    question: "Does my Codex data stay on my Mac?",
    answer:
      "Usage records are stored locally. TokenTick does not upload your conversations, credentials, or usage records. The Mac app sends crash reports, sanitized operational errors, and session statistics to Sentry, using an anonymous installation ID. It also connects to Codex for account limits and fetches public model prices and app updates. The CLI does not initialize Sentry.",
  },
  {
    question: "How much CPU and memory does it use?",
    answer:
      "TokenTick is a native SwiftUI app that processes logs incrementally. Resource use depends on your history and the work in progress: an initial import or repricing can use more resources than routine updates. Disk-space scanning runs only when you first open Storage in a launch or request a refresh. There is no separate persistent daemon.",
  },
  {
    question: "What access and permissions does it need?",
    answer:
      "TokenTick needs read access to your local Codex files and uses Codex’s existing sign-in through its app-server to retrieve account limits. It does not ask you to paste an API key or copy your credentials. You do not need Accessibility or Screen Recording access. The optional CLI installation creates a link in /usr/local/bin; if that directory is not writable, manual installation may require administrator access.",
  },
  {
    question: "Does it keep running when I close the window?",
    answer:
      "Yes. Closing the main window leaves TokenTick in the menu bar so it can continue updating your usage. Choose Quit from the menu to stop the app and collection. Launch at login is optional and can be configured in Settings.",
  },
];

function Brand() {
  return (
    <span className="inline-flex items-center gap-2.5">
      <span className="brand-icon">
        <Image
          src="/mark-light.svg"
          width={30}
          height={30}
          alt=""
          className="light-asset"
        />
        <Image
          src="/mark-dark.svg"
          width={30}
          height={30}
          alt=""
          className="dark-asset"
        />
      </span>
      <span className="text-lg font-semibold tracking-tight">TokenTick</span>
    </span>
  );
}

export default function Home() {
  return (
    <>
      <a href="#main" className="skip-link">
        Skip to content
      </a>
      <header className="site-header">
        <nav
          aria-label="Main navigation"
          className="shell flex h-22 items-center justify-between gap-5"
        >
          <a href="#" aria-label="TokenTick home">
            <Brand />
          </a>
          <div className="flex items-center gap-7 text-sm">
            <a href="#features" className="nav-link hidden sm:block">
              Features
            </a>
            <a href="#faq" className="nav-link">
              FAQ
            </a>
            <a href={github} className="nav-link hidden sm:block">
              GitHub
            </a>
            <Button asChild size="sm">
              <a href={download}>
                Download
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
              Codex usage,
              <br />
              <span className="text-brand">at a glance.</span>
            </h1>
            <p className="hero-description">
              Monitor usage limits and reset times from your Mac menu bar.
              Explore token usage, estimated costs, and local storage in one
              native app.
            </p>
            <div className="mt-8 flex flex-wrap items-center gap-3">
              <Button asChild size="lg">
                <a href={download}>
                  <Download data-icon="inline-start" />
                  Download for Mac
                </a>
              </Button>
              <Button asChild variant="outline" size="lg">
                <a href={github}>
                  View on GitHub
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
              A little more clarity. A lot less guessing.
              <ArrowDown className="size-4" aria-hidden="true" />
            </a>
          </div>
          <figure className="hero-media">
            <Image
              src="/screenshots/menu.png"
              alt="TokenTick menu bar panel with Codex usage limits, reset times, credits, and a usage chart. Sample data."
              width={674}
              height={1544}
              preload
              sizes="(max-width: 640px) 280px, 310px"
              className="menu-image"
            />
            <figcaption>Right there in your menu bar.</figcaption>
          </figure>
        </section>
        <div id="features" className="shell">
          {features.map((feature, index) => (
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
                  aria-label={`View full-size screenshot: ${feature.label}`}
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
                  Sample data <span aria-hidden="true">·</span> Click to explore
                  full size{" "}
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
            <p className="feature-label">Before you install</p>
            <h2 id="faq-title">
              A few things
              <br />
              worth knowing.
            </h2>
            <p className="mt-5 max-w-xs text-muted-foreground">
              Your Mac, your data. Here’s how TokenTick fits in.
            </p>
            <a
              href={`${github}#installation`}
              className="inline-flex items-center gap-2 mt-6 text-sm text-brand hover:underline"
            >
              Installation & documentation
              <ArrowUpRight className="size-4" aria-hidden="true" />
            </a>
          </div>
          <Accordion type="single" collapsible className="w-full">
            {faqs.map((faq, index) => (
              <AccordionItem key={faq.question} value={`faq-${index}`}>
                <AccordionTrigger>{faq.question}</AccordionTrigger>
                <AccordionContent forceMount>{faq.answer}</AccordionContent>
              </AccordionItem>
            ))}
          </Accordion>
        </section>
        <section className="closing shell" aria-labelledby="download-title">
          <Image
            src="/icon-light.png"
            alt=""
            width={72}
            height={72}
            className="light-asset"
          />
          <Image
            src="/icon-dark.png"
            alt=""
            width={72}
            height={72}
            className="dark-asset"
          />
          <h2 id="download-title">Get to know your Codex usage.</h2>
          <p className="text-muted-foreground">
            A little insight, always close at hand.
          </p>
          <Button asChild size="lg">
            <a href={download}>
              <Download data-icon="inline-start" />
              Download for Mac
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
            An independent app. Not affiliated with OpenAI.
          </p>
        </div>
        <nav
          aria-label="Footer navigation"
          className="flex flex-wrap gap-6 text-sm text-muted-foreground"
        >
          <a href={github}>GitHub</a>
          <a href={`${github}#installation`}>Documentation</a>
          <a href={`${github}/releases`}>Releases</a>
          <a href={`${github}/issues`}>Support</a>
        </nav>
      </footer>
    </>
  );
}
