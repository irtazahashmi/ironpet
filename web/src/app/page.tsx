import Link from "next/link";
import { GhostDemo } from "@/components/ghost/GhostDemo";
import { DownloadButtons } from "@/components/DownloadButtons";
import { type Clip, FeatureVideo } from "@/components/FeatureVideo";
import { getFaq } from "@/lib/content";
import { latestRelease } from "@/lib/release";
import { agents, site } from "@/lib/site";

const privacy = [
  { label: "Your chats, memory and inbox", value: "On your Mac" },
  { label: "ironpet servers", value: "None" },
  { label: "API keys", value: "None. Your agents' own sign-in" },
  { label: "Network integrations", value: "Off until you turn them on" },
  { label: "Analytics", value: "None" },
];

const windowClip = { width: 1752, height: 1312 };

const features: { title: string; body: string; clip: Clip; link: { href: string; label: string } }[] = [
  {
    title: "Knows what every agent is doing.",
    body: "Sessions from Cursor, Claude Code, Codex, Gemini CLI, GitHub Copilot and Pi report to Ghost through hooks. He shows the most urgent one, needs input, failed, done or working, and tells you in a bubble what the agent did. Click a session to jump to its terminal tab or editor.",
    clip: { name: "agents", ...windowClip, label: "The Agents section as four agents work: one asks for input, one fails and two finish" },
    link: { href: "/docs/agents/", label: "Watching agents" },
  },
  {
    title: "Puts every request in front of you.",
    body: "Press ⌥⌘G to chat with any agent that speaks the Agent Client Protocol, in your current project. When the agent asks before editing a file or running a command, you get a card with the agent's own options. Allow with ⌘↩.",
    clip: { name: "chat", ...windowClip, label: "A chat about a flaky test: the agent runs commands, asks before running one, and reports that the test passes" },
    link: { href: "/docs/chat/", label: "Chat and approvals" },
  },
  {
    title: "Catches CI, reviews and Sentry.",
    body: "Opt in to GitHub and Sentry alerts and Ghost tells you when CI fails or passes, a review comes in, or an issue escalates. Ask Ghost on any alert starts a chat that looks into it.",
    clip: { name: "alerts", ...windowClip, label: "Pull request alerts arrive, then Ghost explains in the chat why CI failed" },
    link: { href: "/docs/alerts/", label: "Alerts" },
  },
  {
    title: "One pet for each agent.",
    body: "Add a pet and it runs an agent of its own, with its own harness, model and instructions. Bunny can work in Claude Code while Ghost works in Cursor, each asking you in its own bubble.",
    clip: { name: "multi", width: 1054, height: 1060, label: "Ghost finishes a task while Bunny asks before running a command" },
    link: { href: "/docs/pets/#several-pets", label: "Several pets" },
  },
  {
    title: "Keeps one inbox.",
    body: "Action items from your meetings, and what your watchers or agents find, like an email that needs a reply, wait in the Inbox until you mark them done or remove them.",
    clip: { name: "inbox", ...windowClip, label: "Meeting action items and an email from the Gmail watcher arrive in the Inbox, and one is marked done" },
    link: { href: "/docs/inbox/", label: "Inbox" },
  },
  {
    title: "Remembers what matters.",
    body: "When a chat goes quiet, Ghost saves the lasting facts about you, your projects and the people you work with as notes you can read and edit. Every new chat starts with them.",
    clip: { name: "memory", ...windowClip, label: "After a chat about Maya, the Memory section gains a page about her, linked to her project" },
    link: { href: "/docs/memory/", label: "Memory" },
  },
  {
    title: "Builds you dashboards.",
    body: "Ask for “a board of what needs me today” and Ghost writes a small native app that sits in the sidebar, with its own data and buttons that act. It reaches only what you approve.",
    clip: { name: "dashboards", ...windowClip, label: "Ghost writes a Work dashboard from a chat message, and it opens from the sidebar" },
    link: { href: "/docs/dashboards/", label: "Dashboards" },
  },
  {
    title: "Catches you up.",
    body: "Step away, and Ghost sums up what happened in one bubble: who's waiting, what failed, what finished. It's built from what ironpet already recorded on your Mac, and nothing is sent anywhere.",
    clip: { name: "welcome", width: 1054, height: 684, label: "Ghost waves with a welcome back bubble listing what happened while you were away" },
    link: { href: "/docs/using-ironpet/#welcome-back", label: "Welcome back" },
  },
  {
    title: "Looks after you, too.",
    body: "Water, stretch and eye breaks, counted only while you're at the keyboard. While an agent works they come a little early, so you take the break while you'd be waiting anyway. Ghost drinks along with you.",
    clip: { name: "pet", width: 1054, height: 746, label: "Ghost works, cheers when the agent finishes, asks before a command, then drinks water with a break reminder" },
    link: { href: "/docs/automations/", label: "Reminders and automations" },
  },
];

const more = [
  { title: "Listens", body: "Dictate, hear replies read aloud, or talk hands-free in voice mode.", href: "/docs/voice/" },
  { title: "Sees your screen", body: "⇧⌥⌘G asks about the front window, ⌃⌥⌘G about a region you drag.", href: "/docs/screen/" },
  { title: "Runs automations", body: "Reminders, watchers and scheduled jobs that an agent can set up for you.", href: "/docs/automations/" },
  { title: "Takes meeting notes", body: "Records and transcribes meetings, then writes a summary with action items.", href: "/docs/meetings/" },
  { title: "Comes with you", body: "Pair an iPhone to chat, approve and check on agents away from the Mac.", href: "/docs/iphone/" },
  { title: "Answers on Telegram", body: "Chat with Ghost from Telegram when you're away from your desk.", href: "/docs/telegram/" },
];

export default async function Home() {
  const release = await latestRelease();
  const faq = getFaq().slice(0, 5);

  return (
    <>
      <section className="hero">
        <div className="hero-glow" aria-hidden="true" />
        <div className="hero-copy">
          <p className="eyebrow">a little pet that watches your coding agents</p>
          <h1>Your agents work. Ghost keeps watch.</h1>
          <p className="lede">
            ironpet is a desktop pet for macOS. Ghost tells you when Cursor, Claude Code or Codex needs you, shows you every
            command an agent asks to run, and chats with your agents right from your desktop.
          </p>
          <DownloadButtons release={release} />
        </div>
        <GhostDemo />
      </section>

      <section className="section privacy" aria-labelledby="privacy-title">
        <div className="privacy-copy">
          <h2 id="privacy-title">Private by design.</h2>
          <p>
            ironpet runs on your Mac and talks to your agents with the sign-in they already have. Anything that reaches the
            network, like GitHub alerts, voice or the iPhone app, stays off until you turn it on.
          </p>
          <a className="text-link" href={site.security}>
            Read everything ironpet touches →
          </a>
        </div>
        <dl className="privacy-table">
          {privacy.map((row) => (
            <div key={row.label}>
              <dt>{row.label}</dt>
              <dd>{row.value}</dd>
            </div>
          ))}
        </dl>
      </section>

      <section className="section" aria-labelledby="features-title">
        <h2 id="features-title" className="section-title">
          What Ghost does
        </h2>
        <div className="features">
          {features.map((f) => (
            <article key={f.title} className="feature">
              <div className="feature-copy">
                <h3>{f.title}</h3>
                <p>{f.body}</p>
                <Link className="text-link" href={f.link.href}>
                  {f.link.label} →
                </Link>
              </div>
              <figure className="feature-shot is-clip">
                <FeatureVideo clip={f.clip} />
              </figure>
            </article>
          ))}
        </div>
        <div className="more">
          {more.map((m) => (
            <Link key={m.title} href={m.href} className="more-item">
              <h3>{m.title}</h3>
              <p>{m.body}</p>
            </Link>
          ))}
        </div>
      </section>

      <section className="section works-with" aria-labelledby="agents-title">
        <h2 id="agents-title" className="section-title">
          Works with the agents you already use
        </h2>
        <ul className="agent-list">
          {agents.map((a) => (
            <li key={a}>{a}</li>
          ))}
        </ul>
        <p className="muted">
          And any other agent in the{" "}
          <a href="https://github.com/agentclientprotocol/registry" className="text-link">
            ACP registry
          </a>{" "}
          that you have installed.
        </p>
      </section>

      <section className="section pets" aria-labelledby="pets-title">
        <h2 id="pets-title" className="section-title">
          Not a wolf person?
        </h2>
        <p className="muted pets-copy">Pick one of six pets, or ask your agent to draw you a new one.</p>
        <img
          src="/screenshots/pets.png"
          width={2304}
          height={476}
          alt="The six pets waving: Ghost the direwolf, Mochi the mint wolf, a hamster, a panda, a bunny and a cat"
          loading="lazy"
        />
      </section>

      {faq.length > 0 && (
        <section className="section faq-section" aria-labelledby="faq-title">
          <h2 id="faq-title" className="section-title">
            Questions, answered.
          </h2>
          <div className="faq">
            {faq.map((item) => (
              <details key={item.q}>
                <summary>{item.q}</summary>
                <p>{item.a}</p>
              </details>
            ))}
          </div>
          <Link className="text-link" href="/faq/">
            All questions →
          </Link>
        </section>
      )}

      <section className="section cta" aria-labelledby="cta-title">
        <h2 id="cta-title">Ghost is one download away.</h2>
        <DownloadButtons release={release} centered />
      </section>
    </>
  );
}
