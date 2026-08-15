<div align="center">

<img src="https://tty.build/brand-icon.png" width="88" height="88" alt="TTY.Build icon">

# TTY.Build

**Your terminal. Wherever you are.**

Keep the terminals — and the coding agents — on your computer within reach
from iPhone. End-to-end encrypted. No open ports.

[**Download on the App Store**](https://apps.apple.com/us/app/tty-build-agents-terminal/id6792312114) ·
[**Download for macOS**](https://tty.build/download/macos) ·
[**tty.build**](https://tty.build)

<img src="https://tty.build/og.png" width="640" alt="TTY.Build connecting a Mac terminal to an iPhone">

</div>

## What it is

TTY.Build pairs your computer with your iPhone once, using an 8-digit
one-time code, and from then on the terminals running on that computer are
available on the phone — a real terminal, not a remote desktop.

- **End-to-end encrypted.** Terminal bytes, titles, and working directories
  are encrypted between your devices. The relay service can't read them and
  never stores them.
- **No open ports.** Both devices connect outward to the relay. There is no
  port forwarding, no public IP, and no VPN to set up.
- **Built for agents.** Watch long-running coding agents from your pocket and
  get nudged when one needs input — with hook integrations for Claude Code,
  Codex, Copilot, Grok, Kimi, Kiro, OpenCode, and more. Live Activity and
  Dynamic Island show session state at a glance.
- **Everywhere on Apple platforms.** iPhone app, widgets, Apple Watch app and
  complications, and a macOS menu bar app with a full `ttybuild` CLI.

## Install

**iPhone** — get [TTY.Build on the App Store](https://apps.apple.com/us/app/tty-build-agents-terminal/id6792312114).

**macOS** — [download the app](https://tty.build/download/macos) (universal, macOS 14+), or install from the terminal:

```bash
curl -fsSL https://tty.build/i | bash
```

Open **Connect** on the Mac, enter the one-time code on the iPhone, done.

## How it works

```text
┌──────────────┐   outbound TLS    ┌─────────────────┐   outbound TLS   ┌──────────────┐
│ macOS daemon │ ────────────────► │  tty.build       │ ◄─────────────── │  iPhone app  │
│  (PTY host)  │   E2EE frames     │  Cloudflare      │   E2EE frames    │  (terminal)  │
└──────────────┘                   │  Worker relay    │                  └──────────────┘
                                   └─────────────────┘
```

The relay is zero-knowledge by construction: it authenticates devices, routes
opaque encrypted frames, and maintains only the minimal state needed for
widgets and push — identities, binding state, alive-session counts, and push
endpoints. The pairing secret that encrypts your terminals never leaves your
devices. The full wire protocol is documented in
[`docs/PROTOCOL.md`](docs/PROTOCOL.md) and
[`relay/README.md`](relay/README.md).

## Repository layout

```text
relay/                    Cloudflare Worker: relay, Durable Objects, D1, APNs, website
shared/TTYBuildKit/       Swift E2EE, v2 pairing, frame codec, service API types
desktop/TTYBuildDaemon/   macOS daemon core + the public `ttybuild` CLI
desktop/TTYBuildMenubar/  macOS menu bar app
ios/                      iPhone app, widgets, Live Activity, Watch app + widgets
docs/                     protocol and architecture documentation
scripts/                  build, release, and end-to-end test scripts
```

## Developing

The supported host is macOS with Xcode 26, Swift 6, XcodeGen, Node.js 22+,
and Wrangler 4. `AGENTS.md` is the complete operating guide; the fast
validation loop is:

```bash
(cd relay && npm ci && npm test)
(cd shared/TTYBuildKit && swift test)
(cd desktop/TTYBuildDaemon && swift test)
```

The generated `.xcodeproj` files are ignored — edit `ios/project.yml` or
`desktop/TTYBuildMenubar/project.yml` and regenerate with XcodeGen.

## Third-party software

TTY.Build ships with, and is grateful for, the following open-source work:

| Project | License | Used for |
|---|---|---|
| [Ghostty](https://github.com/ghostty-org/ghostty) (libghostty, via [libghostty-spm](https://github.com/Lakr233/libghostty-spm)) | MIT | Terminal emulation and rendering in the iPhone app |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | MIT | Signed automatic updates for the macOS app |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 | `ttybuild` CLI argument parsing |
| [AEOTPTextField](https://github.com/AbdelrhmanKamalEliwa/AEOTPTextField) | MIT | Pairing-code entry field on iPhone (vendored and adapted; see [`ios/ThirdParty/AEOTPTextField`](ios/ThirdParty/AEOTPTextField)) |

Build and test tooling (not shipped in any binary): Cloudflare
[Wrangler](https://github.com/cloudflare/workers-sdk), [Vitest](https://vitest.dev),
and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## License

TTY.Build is released under the [MIT License](LICENSE).
Copyright © 2026 YellowPlus, Inc.

Vendored third-party code keeps its original license and copyright notice
alongside the source.
