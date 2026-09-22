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

export const en = {
  skip: "Skip to content",
  navigation: "Main navigation",
  home: "TokenTick home",
  featuresLabel: "Features",
  faqLabel: "FAQ",
  download: "Download",
  heroTitle: "Codex usage,",
  heroAccent: "at a glance.",
  heroDescription: "Monitor usage limits and reset times from your Mac menu bar. Explore token usage, estimated costs, and local storage in one native app.",
  downloadMac: "Download for Mac",
  viewGithub: "View on GitHub",
  explore: "A little more clarity. A lot less guessing.",
  menuAlt: "TokenTick menu bar panel with Codex usage limits, reset times, credits, and a usage chart. Sample data.",
  menuCaption: "Right there in your menu bar.",
  fullSize: "View full-size screenshot:",
  sampleData: "Sample data",
  exploreImage: "Click to explore full size",
  beforeInstall: "Before you install",
  faqTitle: "A few things",
  faqAccent: "worth knowing.",
  faqDescription: "Your Mac, your data. Here’s how TokenTick fits in.",
  installation: "Installation & documentation",
  closingTitle: "Get to know your Codex usage.",
  closingDescription: "A little insight, always close at hand.",
  disclaimer: "An independent app. Not affiliated with OpenAI.",
  footerNavigation: "Footer navigation",
  documentation: "Documentation",
  releases: "Releases",
  support: "Support",
  title: "TokenTick — Codex Usage Tracker for Mac",
  description: "Track Codex usage limits and reset times from your Mac menu bar. Explore token usage, estimated API costs, and local disk space with TokenTick.",
  dashboardAlt: "TokenTick usage dashboard with sample data",
  features,
  faqs,
};
