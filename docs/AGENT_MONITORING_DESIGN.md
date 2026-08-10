# Agent activity monitoring — design discussion record

Status: **direction agreed, no implementation breakdown yet.** This document
records the product/design discussion for TTY.Build' second major capability:
subscribing to coding-agent activity (Claude Code, Codex, and similar CLIs)
and surfacing it on iPhone, Apple Watch, widgets, and the Dynamic Island.
Implementation planning happens later in a separate pass.

## 1. Motivation and positioning

TTY.Build today is a remote terminal: Mac daemon + Cloudflare relay + iPhone /
Watch clients, with the alive-TTY count on widgets, complications, and the
Live Activity. The second capability adds agent awareness: install hooks into
coding agents on the Mac (a settings panel in the menu bar app, comparable to
supacode's "Coding Agents" developer panel), report session state through the
daemon and relay, and notify the user when an agent is blocked or finished.

Why this fits TTY.Build:

- The push pipeline (daemon → Worker → APNs → widgets / Live Activity /
  Watch) and the pairing/identity/E2EE system already exist. Agent state is
  one more event source, not a second architecture.
- Differentiation: supacode's monitoring is bound to its own Mac terminal
  app, and its notifications land on the Mac. The TTY.Build daemon is
  system-wide — agents running in iTerm, VS Code, Warp, anywhere are visible —
  and notifications reach the phone and wrist when the user is away from the
  Mac. The mobile surface is the product.

The product story: **watch your agents from anywhere; step into the terminal
when one needs you.** Monitoring is the eyes; the remote terminal is the
hands. The two capabilities stay individually complete: monitoring is useful
with zero takeover, and the terminal is useful with zero hooks.

## 2. Capability tiers (and what hooks cannot do)

| Tier | Coverage | Capability |
|---|---|---|
| Monitor | Any agent with hooks installed, any terminal | Status, notifications, widgets, Live Activity |
| Full terminal | Sessions running on a daemon-owned PTY | Arbitrary input, complete takeover |

Two approaches were considered and **rejected** for closing the loop on
sessions the daemon does not own:

- **Hook-based remote approval (rejected).** Claude Code's `PreToolUse` hook
  runs before the permission system and cannot know whether a given call
  would auto-pass or prompt, so remote approval would require blocking every
  tool call on a phone round-trip. The hook that actually fires when the
  agent is waiting on a permission prompt is the `Notification` hook, which
  is fire-and-forget and cannot answer the prompt. Other agents' hooks are
  weaker still. Ceiling of hooks: you can know a session is blocked, not
  unblock it.
- **AppleScript / keystroke injection into the user's terminal (rejected).**
  Technically possible for iTerm2/Terminal.app (both expose per-session tty
  paths), but tightly coupled to each agent's TUI key layout, incomplete
  across terminals, and a mis-injection types garbage into a live user
  terminal. Not worth the risk.

The accepted path to takeover for locally started sessions is a
**transparent CLI shim** (opt-in, per agent, future work): installing
"remote control" for an agent puts a PATH shim in front of its CLI. The user
keeps typing `claude` in their usual terminal; the shim runs the real process
on a daemon-owned PTY and mirrors it to the local terminal. Local experience
is unchanged; the phone gains full takeover. VibeTunnel (`vt claude`)
validates the mechanism; the engineering cost is the usual PTY-in-the-middle
details (resize, signals, mouse reporting). The shim is deliberately **not**
part of the first iteration — monitoring must stand on its own first.

Sessions started from the phone are daemon-owned by construction and always
have full takeover.

## 3. Mac settings panel

A "Coding Agents" page in the menu bar app: one row per supported agent with
an Install button and an honest description of what gets written where
(e.g. hooks in `~/.claude/settings.json`). All hooks funnel into one thin
reporter command shipped with the daemon (working name `ttybuild-hook`) that
talks to the daemon over a local socket with a small stable event
vocabulary: `session-start`, `blocked`, `done`, `session-end`, plus the tty
path / PID lineage of the reporting process. Keep the per-agent adapters
thin; the hook protocol is the stable surface. Initial agent support starts
narrow (Claude Code first, then Codex) with the panel honestly labelling
per-agent capability differences.

The reporter is a fail-open observer, never part of the agent's control path:
stdin and local-socket work have a 100 ms budget, requests are one-way, every
failure exits zero and silently, and installed synchronous hooks have a one
second host-enforced ceiling. Codex title/transcript metadata is resolved in
the daemon rather than read twice inside each high-frequency hook.

When the shim tier ships later, it appears in the same panel as a separate
opt-in toggle per agent ("Enable remote control"), distinct from hook
installation.

## 4. iPhone home screen

The top-left settings button goes away. Home becomes a tab; from the
terminal you reach it with a left swipe, and the gear moves into a corner of
the home screen. Home is the launch landing page: it is the global overview,
the terminal is one swipe away, and tapping any terminal row jumps straight
into that terminal.

Home has two sections:

1. **Terminals** — the tty.build-hosted TTY list. A row has two states: with no
   agent running it shows the tty title and info; while an agent runs in it,
   the row morphs to the shared agent presentation: agent icon + state,
   session name as the title, and the latest assistant message/output (falling
   back to the latest user message only when no assistant message exists) as
   the description. Tapping the row always
   opens the terminal; the morph changes information density, never the
   interaction model.
2. **Agents** — agents detected outside any tty.build-hosted tty, shown as
   status rows using the same session title and latest-output description.
   These rows are glanceable, not attachable.

**Ownership/dedup rule (hard rule):** an agent appears in exactly one place.
The hook reports its tty/PID lineage; the daemon matches it against the PTYs
it owns. Match → the agent renders inside its terminal row only. No match →
it lands in the Agents section. A failed match degrades harmlessly to
"unmanaged". Never render the same agent in both sections.

**Do not expose the managed/unmanaged concept to users.** The UI vocabulary
is just "terminals" and "agents". The only user-visible difference is
whether a row can be opened and operated, which users discover naturally and
which follows from choices they made themselves.

**Multiple computers:** do not group by computer. Both sections are flat,
merged across all bound computers. Each row carries a short hostname chip
(thin outline, consistent with the black/white style); when exactly one
computer is bound the chip is hidden entirely. Users with many computers get
an optional filter chip row at the top (All · host1 · host2), defaulting to
All. Offline computers do not contribute rows or counts; the status surfaces
describe only computers that are currently alive.

**Sorting:** within each section, attention first —
waiting-for-you > running > done > idle tty. Because section order is fixed
(Terminals above Agents), a blocked unmanaged agent could sit below idle
ttys; when any session is in a waiting state, a compact "needs you" summary
strip appears at the very top of the page (tap scrolls to the row). It is
absent otherwise.

**Empty states are the discovery funnel:** an empty Agents section points to
installing hooks via the Mac menu bar app; an empty Terminals section keeps
the existing pairing / new-session guidance.

## 5. Widgets, Live Activity, Watch

- The iPhone has no ordinary notification or Notification Service Extension
  channel. Agent attention is expressed only through Live Activity and the
  Dynamic Island.
- Finished attention events are held back (30s, `Tuning.doneAttentionDelay`) and
  cancelled by any state edge in the window: Claude fires Stop whenever its
  main loop parks — including mid-task waits on background subagents — so an
  immediate "finished" alert is often premature. Waiting/error alerts stay
  immediate, and the E2EE list snapshot still flips to done in real time.
- Widgets, complications, and the Live Activity extend the existing count
  model to per-state aggregates (e.g. `2 running · 1 waiting · 3 ttys`).
  "Waiting for you" is the one state that can justify color under the
  black/white rule.
- Home, Watch, Lock Screen, and the expanded Dynamic Island share the same
  agent text model: title = session name; description = latest assistant
  message/output, falling back to the latest user message only when no
  assistant message exists. Tool names/actions are never used as the visible
  description. Compact and minimal islands keep only the agent glyph and
  state because those families do not have room for readable session text.
- Foreground status starts the island locally and silently. A first remote
  appearance occurs only for waiting/error/done and carries the required
  ActivityKit alert; ordinary running/count updates never alert.
- Agent events are far more frequent than TTY lifecycle changes; the daemon
  must coalesce/debounce before pushing to respect APNs budgets for widget
  and Live Activity updates.

## 6. Privacy mapping

The existing invariant holds unchanged: the Worker stores identities,
bindings, counts, and push endpoint state — never content.

- **D1 sees aggregate counts only** — per-computer
  running/blocked/recently-done counts, structurally identical to the
  alive-TTY count. A Live Activity envelope adds only a state, timestamp,
  alert bit, and opaque ciphertext. The newest envelope is retained
  temporarily in the per-client PushCoordinator Durable Object for delivery
  retries, never in D1, and is deleted when its agent is no longer active.
- **Rich content is E2EE.** Agent names, project names, current-action
  lines, and last messages travel from the daemon to the app over the
  existing E2EE relay channel, peer to terminal bytes.
- **Rich Live Activity content** is daemon-sealed with a dedicated derived
  key and decrypted by the widget extension from a shared keychain group.
  The root pairing secret never leaves the app's private keychain group.

## 7. Open questions (deferred)

- Hook/event protocol details and the per-agent adapter list.
- Exact agent-state model (is `done` a state or an event? staleness/timeout
  semantics for agents that die without a hook firing).
- Shim tier: scope, packaging, and whether it ever becomes default.
- Watch app layout for the two-section model on a small screen.
