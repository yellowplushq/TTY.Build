# TTY.Build Architecture

TTY.Build v2 combines a zero-knowledge terminal relay with a deliberately small
status service for widgets, Dynamic Island, and Apple Watch.

```text
ttybuild/
├── relay/                    Cloudflare Worker, Durable Objects, D1, APNs
├── shared/TTYBuildKit/         Swift E2EE, v2 pairing, relay and REST clients
├── desktop/TTYBuildDaemon/     Shared PTY/relay service core + headless CLI
├── desktop/TTYBuildMenubar/    macOS service process and menu bar UI
├── ios/
│   ├── Sources/              UIKit terminal app and binding lifecycle
│   ├── SharedStatus/         app-group state, status API, ActivityKit bridge
│   ├── Widgets/              iPhone Widget + Live Activity/Dynamic Island
│   ├── WatchApp/             companion watchOS SwiftUI app
│   └── WatchWidgets/         watch complications / Smart Stack widget
└── docs/                     v2 protocol and this implementation map
```

## Cloudflare service

The Worker at `https://tty.build` owns four distinct responsibilities:

1. REST enrollment and explicit client-computer bindings in D1.
2. Authenticated, hibernatable E2EE WebSocket routing through `RelayChannel`
   Durable Objects.
3. Serialized aggregate recomputation and APNs delivery through per-client
   `PushCoordinator` Durable Objects.
4. The static one-screen website and a stable desktop download redirect to the
   latest signed GitHub release.

D1 stores token and eight-digit pairing-code hashes, ephemeral public keys,
encrypted pairing envelopes, the binding graph, the DO-derived online/name/alive
count projection, APNs endpoints, and delivery fingerprints. Each computer DO
owns the current privacy-safe `{sessionId,alive}` directory. Neither store holds
E2EE secrets, ephemeral private keys, titles, working directories, or terminal
bytes. Host/client roles are derived from bearer credentials; the public relay
route has no role parameter.

Computer reset and client unbind commit a relay-revocation outbox entry in the
same D1 transaction that removes authorization. The Worker eagerly asks the
per-computer Durable Object to close affected sockets; the minute cron retries
with bounded backoff until that close is acknowledged. A successful rebind
removes a stale client-targeted retry before granting relay access again.

For each client-to-host binary message, `RelayChannel` prepends wire version
`0x02` and the 32-byte lowercase client ID from the authenticated, serialized
socket attachment. The host compares that source with the encrypted hello and
binds every pending/active routing tag to it before decrypting later frames.
This prevents one bound client, despite possessing the computer's shared
pairing secret, from claiming or advancing another client's relay identity.
Host-to-client ciphertext remains unchanged and broadcast by routing tag.

APNs uses one ES256 provider key held only in Worker secrets. Topics are fixed
per surface:

| surface | push type | topic |
|---|---|---|
| iPhone Widget | `widgets` | `air.build.pedals.push-type.widgets` |
| watch Widget | `widgets` | `air.build.pedals.watchapp.push-type.widgets` |
| Live Activity | `liveactivity` | `air.build.pedals.push-type.liveactivity` |

Widget pushes trigger a fresh authenticated timeline request. Live Activity
pushes carry the aggregate content state because ActivityKit renders it without
running app networking code.

## Desktop service

`TTYBuildDaemonCore` owns the PTY processes, replay buffers, Unix control socket,
and authenticated relay links. The menu bar app links this core directly and
owns its lifecycle, so quitting TTY.Build also stops the service. It opens directly
to pairing on an unpaired computer and never asks the user to configure or
start a daemon. The optional headless `ttybuild` executable exposes `serve`, `ls`,
`new`, `kill`, `pair`, and `status` through Swift Argument Parser for CLI use.

First launch registers a computer with the configured HTTPS service and stores
`~/.tty.build/identity.json` (mode 0600). Opening the app's pairing surface requests
a fresh 15-minute, eight-digit pairing code; closing it revokes the current
code. The headless CLI provides the same pairing behavior, and `--reset` rotates
the server identity, host bearer, and E2EE secret.

`RelayHostClient` publishes the complete privacy-safe `{id,alive}` session
directory and local host name on control-link connect, every list change, and a
30-second heartbeat. The DO owns its revision and online state, gives unexpected
disconnects a 20-second recovery grace, and enforces a 90-second snapshot lease.
The desktop reports offline before sleep or orderly exit and republishes the
complete local list after wake. Titles, cwd, replay data, stdin, and stdout
remain encrypted peer frames.

## iPhone app

The iOS 26 UIKit target `TTYBuild` uses GhosttyKit for terminal rendering and
TTYBuildKit for transport and E2EE.

- `PairingStore` stores the v2 installation identity and durable
  `ComputerBinding` values in the Keychain. It persists an E2EE secret only
  after the desktop completes the ephemeral Curve25519 exchange and the Worker
  commits the binding.
- `TerminalManager` owns every bound `ComputerConnection`, intersects private
  encrypted descriptors with the DO-authoritative directory, removes offline
  tabs with a toast, and pools per-terminal session links. Settings reports each
  computer's directory-backed online/offline state.
- `AppServices` is created once by `AppDelegate`, shared by scenes, and owns the
  status-surface lifecycle. It installs the client status credential in the app
  group, refreshes server state, updates Live Activity, reloads the Widget, and
  sends the latest context to Watch.
- The app-group identifier is `group.air.build.pedals`.

The app supports multiple bound computers. Only session IDs and alive flags
leave the encrypted terminal path; titles, cwd, dimensions, and bytes do not.

## Widget and Live Activity

`TTYBuildWidgets` contains both the Home/Lock Screen Widget and
`ActivityConfiguration<TTYActivityAttributes>`.

- The Widget supports small, medium, circular, rectangular, and inline
  families. Its timeline fetches `/v2/clients/me/state` and keeps a 15-minute
  recovery policy.
- iOS 26 `WidgetPushHandler` registers the WidgetKit APNs token directly with
  the Worker. The shared store retains the latest observed token even when
  WidgetKit temporarily reports no configured instances; the first real
  timeline request restores that registration idempotently, without creating a
  push/register loop.
- The Live Activity shows total TTYs, online/offline computer counts, and
  freshness on Lock Screen and Dynamic Island compact/minimal/expanded views.
- The app observes push-to-start tokens, remotely created activities, each
  activity's rotating update token, and terminal activity states. APNs starts
  the surface; foreground refreshes update/end existing activities immediately.

No App Intent is needed because these surfaces are read-only. A tap opens the
main app; terminal mutations remain inside the authenticated terminal UI.

## Apple Watch

`TTYBuildWatch` is a companion watchOS 26 SwiftUI app. The phone transfers the
read-only status credential and last snapshot using `WCSession` application
context. For terminal viewing it also transfers the Watch's independent
delegate relay identity plus E2EE `ComputerBinding` secrets as a versioned
`WatchTerminalContext` (v2) envelope. After a transfer, the Watch talks to the
Worker and relay directly and works with the phone unavailable.

The v2 envelope is designed so a bad credential can never wedge the Watch:

- Every field is validated on decode (`ClientIdentity`/`ComputerBinding`
  decode through their throwing initializers); an invalid payload fails
  decoding instead of materializing a value that traps in the connect path.
- The phone stamps each update with a monotonic `revision`. The Watch ignores
  older updates, so a durable-but-stale `applicationContext` delivery cannot
  regress or wipe a fresher credential, and an undecodable payload is never
  interpreted as "clear credentials".
- The Watch Keychain store is self-healing: an item that fails decoding or
  validation is deleted and treated as absent, and the Watch re-requests the
  current context from the phone.
- The phone only clears the Watch credential when the installation is
  authoritatively unpaired; transient Keychain or network failures keep the
  last-known-good context (the relay remains the enforcement point for
  anything revoked server-side).
- When the relay rejects the Watch's bearer (HTTP 401/403), the Watch asks the
  phone for a fresh context (throttled), and the phone re-runs delegate
  provisioning whenever the Watch asks.

`TTYBuildWatchWidgets` implements circular, corner, rectangular, and inline
complications/Smart Stack families. Its own iOS 26 `WidgetPushHandler` registers
the watch WidgetKit token through the same timeline-backed recovery path, so
APNs refresh does not depend on waking the iPhone.

## Apple resources

| target | bundle identifier |
|---|---|
| iPhone app | `air.build.pedals` |
| iPhone Widget / Live Activity | `air.build.pedals.widgets` |
| watch app | `air.build.pedals.watchapp` |
| watch Widget | `air.build.pedals.watchapp.widgets` |

All targets use team `QDJ93ZUQ9B` and the shared App Group. The main app and
both Widget extensions have Push Notifications capability. Debug builds use
sandbox APNs; Release builds use production APNs.

## Build and verification

- `swift test` in `shared/TTYBuildKit` checks v2 pairing, frame codec, channel
  isolation, replay rejection, and cross-language crypto vectors.
- `swift test` in `desktop/TTYBuildDaemon` checks PTY lifecycle and local control.
- `npm test` in `relay` checks D1 enrollment/bindings, authenticated relay,
  terminal-directory leases, APNs JWT/payload/error handling, and push delivery.
- Generate Apple projects with `xcodegen` from `ios/project.yml`; do not edit the
  generated `.xcodeproj` by hand.
- `scripts/deploy-relay.sh` applies D1 migrations, deploys the Worker, and waits
  for the custom domain to report the new immutable Worker version three times
  consecutively before running the public v2 contract.
- `scripts/e2e.sh` covers computer/client registration, one-time pairing, E2EE
  terminal traffic, state aggregation, and the iOS simulator UI.
