# Exclusive attach and local takeover — design

Status: **implemented** (daemon arbiter + gating, control-socket attach
upgrade, `ttybuild-attach`, menu bar "Open in Terminal" + PATH install, and
the iPhone placeholder). One deliberate deviation from §5: the iPhone keeps
a preempted session's data channel open (the pooled emulator stays fed, so
reclaiming needs no replay); detaching to save bandwidth remains an option
later. Protocol details live in PROTOCOL.md §5 and §7.1.

This document specifies taking
over a session from the user's own terminal application on the Mac (iTerm2,
Terminal.app, Warp, …) and the exclusive-holder model that replaces the
current "any number of concurrent interactive clients" semantics.

## 1. Goal and UX

Sessions are daemon-owned PTYs; today the iPhone is the only interactive
surface. This feature adds a local attach client that runs **inside the
user's normal terminal**, and makes interactive attachment **exclusive**: at
any moment a session has at most one *holder*.

- In any terminal, `ttybuild-attach <id>` (final command name TBD, §9)
  attaches full-screen to that session, tmux-attach style. Attaching claims
  the session.
- The menu bar's session list gets an "Open in Terminal" row action that
  launches the user's *own* terminal running the attach command — the
  command line is the mechanism, the menu item is the convenience. The
  terminal is chosen by MRU: the app tracks which known terminal
  (Terminal.app, iTerm2, Ghostty, kitty, Alacritty, WezTerm, …) the user
  last activated, seeding from running processes (a running third-party
  terminal outranks Terminal.app). Launching never uses AppleScript or
  keystroke injection: Terminal.app/iTerm2 execute the `.command` file
  directly, the others take it via `open -na <app> --args` CLI arguments,
  and apps with neither channel (Warp) fall back to Terminal.app.
- When a terminal on the Mac holds the session, the iPhone terminal shows a
  full-screen placeholder ("In use in iTerm2 — tap to take over"). Tapping
  claims it back.
- When the iPhone holds the session, the attach client clears its screen and
  shows the mirror-image placeholder ("In use on iPhone — press ⏎ to take
  over, q to quit").
- A claim always succeeds. Both surfaces belong to the same user; preemption
  is an explicit tap/keypress, never a permission flow.

Exclusivity also removes resize contention: only the holder's grid size is
ever applied, so there is no SIGWINCH ping-pong between differently sized
windows.

## 2. Ownership model

The daemon keeps one in-memory holder per session:

```text
holder := none | attach(connId) | client(principal)
```

- `attach(connId)` is one local attach connection. Each attach process is
  its own holder — two terminal windows attached to the same session are
  exclusive against *each other* too, not just against the phone. The daemon
  labels it with the attaching process's terminal app name when resolvable
  (via the socket peer pid → process lineage), falling back to "Terminal".
- `client(principal)` is a bound client's 32-hex relay principal (iPhone, or
  the Watch's delegate identity — the Watch is an ordinary client here).
- `none` means unheld (fresh CLI-created session, or all attachers gone).

Rules:

1. **Claim is unconditional and last-writer-wins.** Any claim replaces the
   current holder and is broadcast to everyone.
2. **Initial holder = creator.** A session created via the `create` ctl
   frame starts held by the requesting client's principal (from the
   authenticated 0x02 source envelope). A session created by
   `ttybuild-attach --new` starts held by that attach connection.
3. **Only the holder's `stdin` and `resize` are applied.** The daemon drops
   both from any other source. This is the enforcement point; placeholders
   are cosmetic on top of it.
4. **Attach disconnect releases; client disconnect does not.** When the
   holding attach connection's socket closes, holder → `none` (the process
   is gone for good). A phone that drops off the network keeps its stale
   holder: it blocks nobody (rule 1), and auto-release would invite
   reclaim ping-pong.
5. Ownership is not persisted. Sessions die with the daemon process, so
   holder state is rebuilt from rule 2 alone.

The holder gates *interaction*, not *visibility*. `stdout`/`replay`
broadcast exactly as today; a non-holder that keeps a channel open receives
output but cannot type. New phone clients will instead close the session
channel and show the placeholder (§5), so non-holders consume no terminal
bandwidth.

## 3. Relay protocol changes (ctl, control channel)

Two new ctl kinds on the E2EE control channel. Holder metadata (terminal app
names, device names) is content and must never appear in relay metadata or
D1 — this feature adds **no** Worker or D1 changes at all.

```text
claim    {id, req?}                              client → host
takeover {id, holder:{kind, principal?, name?}}  host → client (broadcast)
```

- `claim` sets the holder to the sender's authenticated principal (never a
  payload-supplied identity). The state answer is the broadcast `takeover`;
  failures answer `err {req}`.
- `takeover.holder.kind` is `"attach" | "client" | "none"`. `principal` is
  present for `kind == "client"` so each client can compare against its own
  identity. `name` is the display label ("iTerm2", "iPhone"); clients must
  tolerate its absence.
- The host broadcasts the full holder map after `sessions` on every client
  hello (one `takeover` per session, mirroring the `agents` replay), so a
  reconnecting client recovers holder state without asking.

Compatibility: both peers already drop undecodable ctl frames without
reconnecting (`try? frame.controlMessage()` at each consumer), and the
daemon ignores unknown client requests. An old iPhone build degrades to a
**read-only mirror**: it never sees `takeover`, keeps rendering output, and
its keystrokes are dropped by rule 3. Acceptable for internal TestFlight;
the placeholder UX requires a client update.

## 4. Local attach transport (control socket upgrade)

The attach client talks plaintext to the daemon over the existing 0600
same-user Unix socket — no E2EE, no relay. The current `ControlServer` is a
one-shot NDJSON request/response loop with 10 s timeouts; attach upgrades a
connection into a long-lived byte stream:

1. Client sends the usual NDJSON request:
   `{"cmd":"attach","id":N}` (or `{"cmd":"attach","new":true,"cwd":...}`
   to create-and-attach).
2. Daemon replies `{"ok":true,"id":N}` and from that point the connection
   stops being NDJSON: both sides switch to length-prefixed plaintext
   frames, reusing the TTYBuildKit `Frame` codec (`u32 LE length || frame`;
   the prefix restores the message boundaries WebSockets provided). Recv/
   send timeouts come off; the per-connection thread becomes the read pump.
3. Frames carry the same types as the relay path: `stdin`, `stdout`,
   `resize`, `replay`, and ctl for `claim` / `takeover` / `exit`. The
   daemon applies the resize-before-replay ordering contract on claim,
   identical to PROTOCOL.md §5, so the attach client is just another
   consumer of the existing semantics.
4. Attach connections are registered with the arbiter as `attach(connId)`;
   socket close releases per §2 rule 4.

The frame vocabulary over this socket is a strict subset of the relay
protocol — no session directory, no agents, no hooks. `PROTOCOL.md` §7
(control socket) gains an "attach upgrade" subsection.

## 5. iPhone app

`ComputerConnection` keeps a `[sessionId: Holder]` map from `takeover`
frames. Per terminal:

- **I am holder** (or pre-update daemon: no holder info ever received →
  behave exactly as today): normal interactive terminal.
- **Someone else / none**: detach the session data channel, render the
  full-screen placeholder (reuse the `TerminalStatusOverlay` pattern;
  black/white per VISUAL_STYLE). `none` reads "tap to attach";
  `attach`/other-client reads "In use in ⟨name⟩ — tap to take over".
- Tap → send `claim` → on `takeover` naming me: reopen the session channel,
  send `resize` with my grid, then `requestReplay` (existing reconnect
  machinery already does all of this).

Home list and agent rows are unaffected; holder state never leaves the E2EE
control channel.

## 6. Attach client behavior (in the user's terminal)

A small terminal program: raw mode on the controlling tty, forward
stdin/SIGWINCH, render stdout/replay bytes verbatim. States:

- **Holding**: pure passthrough. On `SIGWINCH`, send `resize`. Detach key
  is `Ctrl-\ Ctrl-\` (double-tap, dtach precedent; single `Ctrl-\` passes
  through after a short grace so SIGQUIT for the remote process remains
  reachable). Detaching restores the local tty and exits 0; the arbiter
  releases via socket close.
- **Preempted** (received `takeover` naming someone else): drain any
  buffered local input (so keystrokes in flight at preemption cannot
  instantly reclaim), clear screen, show the placeholder with the holder's
  name. Local keys are interpreted, not forwarded: `⏎` or `t` claims back,
  `q` / `Ctrl-C` exits cleanly.
- **Claiming**: send ctl `claim`, then current window size as `resize`; the
  daemon answers `takeover` + `resize` + `replay` and the client repaints.
- **Session exit**: print the exit status, restore the tty, exit.
- **Daemon gone** (socket EOF): report and exit non-zero.

On successful claim the client also emits an OSC 0 title so the user's
terminal tab shows the session title.

## 7. Packaging and the CLI constraint

The debug `ttybuild` CLI stays internal-only (AGENTS.md invariant). The
attach client ships as a **separate, attach-only binary** embedded in the
menu bar app bundle:

- New SwiftPM target in `desktop/TTYBuildDaemon` (working name
  `ttybuild-attach`) linking only the socket client + tty handling — none of
  serve/pair/reset.
- The menu bar app gains "Install command line tool" (VS Code/VibeTunnel
  pattern): symlink from the app bundle into `/usr/local/bin` (or
  `~/.local/bin` fallback without admin rights).
- "Open in Terminal" launches the default terminal via `NSWorkspace` with
  the embedded binary's absolute path, so it works before the symlink is
  installed.
- AGENTS.md's CLI sentence gets amended to distinguish the internal debug
  CLI from the shipped attach helper.

## 8. Edge cases

- **Holder's phone goes offline**: holder stays stale; any terminal or
  other phone claims through it unconditionally. No grace timers.
- **Two terminals on one session**: exclusive against each other; the
  non-holding one shows the placeholder ("In use in iTerm2 …").
- **Watch**: claims like any client when opening its projection; its tiny
  grid now only applies while it holds — an improvement over today.
- **Attach process killed (SIGKILL / terminal window closed)**: socket
  close → release to `none`; phone placeholder flips to "tap to attach".
- **Session exit while preempted**: exit wins over the placeholder on both
  surfaces; arbiter entry dropped.
- **Old phone build**: read-only mirror (§3); no placeholder until updated.
- **Scrollback**: replay on claim is the 256 KiB ring, same bound as the
  phone. The user's terminal keeps its own native scrollback only for
  output received while attached.

## 9. Open questions (deferred)

- User-visible command name (`ttybuild-attach` is the working name; the
  installed symlink could be shorter, e.g. `ttyb` or `tb`). Decide at
  packaging time.
- Client display names for `takeover.name` on the phone side: the daemon
  resolves terminal app names for attach holders, but has no device name
  for phone holders; v1 uses "iPhone"/"Apple Watch" generics. A
  pairing-time device name would be a small TTYBuildKit addition later.
- Whether `none` sessions should render live output on the phone (mirror)
  instead of a placeholder. v1: placeholder everywhere for consistency.
- A menu-bar-owned terminal window (previous draft of this design) remains
  possible later as a second consumer of the same arbiter; out of scope.

## 10. Testing

- `TTYBuildDaemonCoreTests`: arbiter claim/release/initial-holder; stdin
  and resize gating by source; release on attach-socket close (not on
  client disconnect); holder cleanup on session exit; `takeover` broadcast
  and hello replay; attach upgrade handshake + frame pump on the control
  socket.
- `TTYBuildKitTests`: codec round-trip for `claim`/`takeover`; old-decoder
  drop test (unknown kind must not kill the link).
- Attach client: pty-based integration test (spawn daemon + attach under a
  test pty; assert replay splice, resize, preempt/reclaim, detach key,
  buffered-input drain on preemption).
- E2E (`scripts/e2e.sh` extension): phone creates → terminal attaches and
  claims → phone shows placeholder → phone reclaims → attach client shows
  placeholder → `q` exits cleanly.
- Visual smoke: placeholder light/dark on iPhone; placeholder rendering in
  Terminal.app and iTerm2.
