# Pedals Protocol Specification v2

Pedals exposes encrypted remote terminals while keeping a privacy-safe terminal
directory in each computer's Durable Object for clients, widgets, and Live
Activities.

```text
iPhone / Watch ── HTTPS ──> Cloudflare Worker + D1 ── APNs ──> system surfaces
       │                         │
       └──── E2EE over WSS ─────┴──── E2EE over WSS ──── desktop daemon
```

The service stores computer/client identifiers, explicit bindings, host names,
terminal IDs plus their alive flags, and the derived alive count. It never
receives the E2EE secret, terminal titles, working directories, stdin, stdout,
or replay buffers.

## 1. Identities and authorization

`POST /v2/computers` creates a computer identity and returns a 32-hex
`computerId` plus an opaque `hostToken`. The daemon generates its independent
32-byte E2EE secret locally and stores all three values in
`~/.pedals/identity.json` with mode 0600. D1 stores only a SHA-256 hash of the
host token.

`POST /v2/clients` creates one installation identity and returns `clientId`,
`clientToken`, and an independently generated `statusToken`. iOS keeps its
full `ClientIdentity` in the Keychain:

- `clientToken` authorizes binding mutations and relay access. It stays in the
  containing app and is never copied to an extension. The paired Watch uses a
  separately registered client identity, never the iPhone's relay principal.
- `statusToken` is a least-privilege credential for `/state` and push-endpoint
  registration. Only `clientId`, the service origin, and this token are copied
  to the app group and companion Watch.

Neither credential contains terminal encryption material. E2EE secrets remain
in each `ComputerBinding` in the iPhone Keychain.

Every authenticated HTTP or WebSocket request uses:

```http
Authorization: Bearer <hostToken-or-clientToken-or-statusToken>
```

The Worker hashes the presented token and derives both its role and scope from
D1. A request cannot select `host`, `client`, or a credential scope in a URL or
body. In particular, a `statusToken` cannot mutate bindings or open a relay.

## 2. One-time pairing and durable bindings

Opening the desktop pairing surface generates an ephemeral Curve25519 key and
requests an eight-digit, single-use rendezvous code:

```http
POST /v2/computers/:computerId/pairing-sessions
Authorization: Bearer <hostToken>
Content-Type: application/json

{"hostPublicKey":"<base64url Curve25519 public key>"}
```

The response contains `sessionId`, `code`, and `expiresAt`. A code is valid for
15 minutes and only while its desktop pairing surface remains open. Opening a
new surface replaces the computer's prior session; closing it sends `DELETE
/v2/computers/:computerId/pairing-sessions/:sessionId`. Expiry, cancellation,
a successful claim, or completion prevents another client from using the code.

iOS creates or loads its client identity, generates its own ephemeral key, and
claims the code:

```http
POST /v2/clients/me/pairing-sessions/claim
Authorization: Bearer <clientToken>
Content-Type: application/json

{"code":"12345678","clientPublicKey":"<base64url Curve25519 public key>"}
```

The daemon polls its authenticated session. Once claimed, it derives a shared
key using ephemeral Curve25519 plus HKDF-SHA256, then seals the existing
32-byte computer E2EE secret with ChaChaPoly. The session ID is authenticated
as AEAD associated data. The daemon submits only that ciphertext envelope;
the Worker atomically creates the durable client-computer edge and never sees
the plaintext secret. iOS polls its claimed session, decrypts the envelope,
stores the `ComputerBinding` in the Keychain, and acknowledges the session so
the Worker deletes it.

The eight-digit code is therefore only a short-lived rendezvous handle, not
encryption key material. `DELETE
/v2/clients/me/bindings/:computerId` atomically deletes the binding and commits
a client-targeted socket-revocation outbox row before the local key is removed.
The Worker attempts closure immediately and cron retries transient Durable
Object failures, so established sockets cannot outlive an unbind indefinitely.

For terminal viewing, the iPhone registers an independent Watch client and
reconciles its server-side edges through:

```http
PUT /v2/clients/me/delegated-bindings
Authorization: Bearer <iphone-clientToken>
Content-Type: application/json

{"clientId":"<watch-clientId>","clientToken":"<watch-clientToken>"}
```

The Worker verifies both opaque client credentials, rejects self-delegation,
records one `watch-terminal` child relationship, and makes the Watch client's
binding set exactly equal to the iPhone client's current set. Removed edges
commit client-targeted socket revocations in the same transaction. A later
iPhone unbind removes the same computer edge from both principals atomically.
Replacing a lost Watch identity revokes the prior identity and its sockets.
The request contains no computer secret. After it succeeds,
the iPhone transfers the independent Watch identity and its locally held E2EE
`ComputerBinding` values over WatchConnectivity; the Watch stores them in its
own Keychain. Thus simultaneous iPhone and Watch relay sockets have distinct
principals and cannot replace one another.

Neither the code nor either ephemeral private key is persisted. Pairing session
rows contain only code hashes, public keys, ciphertext, identities, and expiry
metadata, and are removed on acknowledgement or expiry.

## 3. Authenticated relay

Relay WebSockets connect to:

```text
GET /v2/relay/:computerId?channel=control
GET /v2/relay/:computerId?channel=session&sid=<u32>
```

- A host bearer must belong to `computerId`.
- A client bearer must have an active D1 binding to `computerId`.
- The edge Worker injects the verified role into an internal request and routes
  `(computerId, channel)` to one hibernatable Durable Object.
- The newest host replaces the prior host. Any number of bound clients can
  coexist. Host-to-client binary messages broadcast; client-to-host messages
  go to the active host.
- Messages are never queued. A reconnecting session channel requests a fresh
  replay snapshot from the daemon.
- Relay text messages are the server-owned control plane; encrypted peer frames
  are binary.

Client-to-host binary delivery has a fixed relay-authenticated source envelope:

```text
client sends:  e2eeWire
host receives: 0x02 || clientId(32 lowercase ASCII hex bytes) || e2eeWire
```

The Durable Object constructs the 33-byte prefix only from the `principalId`
in the client's serialized WebSocket attachment, after bearer and binding
authorization. It never accepts a source prefix from the client payload. A
host-role `RelayLink` requires version `0x02`; client-role links receive the
unchanged host E2EE wire. The 1 MiB peer-frame limit applies before this
33-byte envelope is added.

### 3.0 Client HTTP long-poll transport

watchOS proxies plain HTTP through the paired iPhone's Bluetooth link but
cannot open a WebSocket without a direct Wi-Fi/cellular path, so clients (and
only clients — hosts always use WebSockets) may carry the identical wire
protocol over HTTP:

```text
GET  /v2/relay/:computerId/http?channel=...&session=<32hex>[&after=<u53>]
POST /v2/relay/:computerId/http?channel=...
```

Both verbs authenticate exactly like the upgrade (client bearer + active D1
binding, rechecked inside the Durable Object). `GET` is a long poll: the first
call with a fresh client-generated `session` token registers an in-memory
queue keyed by `(principalId, channel)` — replacing that principal's previous
queue like a WebSocket replacement — and immediately returns the same initial
control-plane message a socket would receive (directory or channel-state).
Later polls park up to 20 s and return:

```json
{ "next": 7, "messages": [{ "t": "<relay text>" }, { "b": "<base64 wire>" }] }
```

`after=<cursor>` acknowledges every message with sequence <= cursor; anything
unacknowledged is redelivered on the next poll, so a response lost in transit
cannot drop frames (E2EE replay protection discards duplicates the client
already opened). A poll naming a session the Durable Object no longer holds
(isolate eviction, 60 s idle expiry, replacement, or a >2 MiB / >256-message
backlog) answers `{ "reset": true }`: the client must open a fresh transport
and redo the E2EE handshake, exactly like a socket reconnect.

`POST` bodies batch client-to-host wires as `u32be length || wire`, repeated
(max 64 wires; each wire capped at the 1 MiB peer-frame limit). The Durable
Object applies the same authenticated source envelope per wire before
forwarding to the active host socket. Sends are serialized client-side, so
uplink ordering matches the WebSocket transport. A session-opening poll is
rate-limited like a socket upgrade; continuation polls and sends ride the
global request limiter only.

### 3.1 Server-authoritative terminal directory

The host and every bound client keep their authenticated `control` WebSocket
open continuously. Immediately after connecting, whenever a session is
created, closed, or exits, and every 30 seconds as a full-snapshot heartbeat,
the active host sends:

```json
{
  "type":"host-snapshot",
  "hostName":"MacBook Pro",
  "sessions":[{"id":7,"alive":true},{"id":9,"alive":false}],
  "agents":{"running":2,"waiting":1}
}
```

This is an idempotent complete snapshot, not a delta. The Durable Object accepts
it only from the current active control host, canonicalizes at most 255 ordered
unique terminal IDs, renews a 90-second lease, and stores the directory in DO
storage. Repeating an unchanged snapshot only renews the lease; it does not
increment the revision or send duplicate push updates.

`agents` carries the per-state coding-agent aggregate counts — the only
agent-derived data that is server-visible (each value 0–255; `waiting` folds
in error states, since both park the agent on the user; `done` is
deliberately absent — it grows without bound, so it stays client-side). The
key is optional for backward compatibility (absent ⇒ all-zero); when present
it must contain exactly `{running, waiting}`. The counts flow into the D1
projection next to the alive-TTY count and from there into widget snapshots
and the Live Activity content state; the Live Activity lifecycle edge is
`totalRunning + agentsRunning + agentsWaiting` crossing zero. Rich agent
detail (names, projects, messages) stays exclusively in the encrypted
`agents` ctl frame (§5).

Every control client receives the current directory as soon as its WebSocket is
accepted and again whenever the directory changes:

```json
{
  "type":"terminal-directory",
  "revision":12,
  "online":true,
  "hostName":"MacBook Pro",
  "sessions":[{"id":7,"alive":true},{"id":9,"alive":false}],
  "updatedAt":1784512800
}
```

The client accepts the initial directory and then only strictly newer revisions;
equal duplicates and older deliveries are ignored. This directory decides
which terminal tabs exist and whether each is alive. The separate encrypted
`sessions` frame supplies private display fields such as title, cwd, and size;
the client intersects it with the DO directory, so delayed encrypted frames can
never resurrect a terminal that the server has removed.

Before sleep or orderly process exit, the desktop sends
`{"type":"host-offline"}` and briefly waits for WebSocket delivery. The DO
immediately publishes an offline directory with an empty session list and the
reason `host-requested`. A lost control socket instead starts a 20-second grace
period: reconnecting and sending a fresh full snapshot within that period keeps
the directory online, which prevents ordinary weak-network handoffs from
flashing every terminal away. If it does not recover, the DO alarm publishes
`connection-lost`; if a nominally connected socket stops sending snapshots for
90 seconds, the alarm closes it and publishes `lease-expired`.

Going offline changes only remote visibility. Sleep or a transient network loss
does not close local PTYs; a reconnect republishes the full live local list. D1
stores only the DO's derived `online`, host name, and alive count projection,
which is updated in the same serialized directory transition used to notify
widgets and APNs.

On a session-channel WebSocket, clients receive
`{"type":"channel-state","online":true|false}` for transport feedback. It
never controls tab visibility; only `terminal-directory` does.

## 4. End-to-end encryption and connection handshake

The pairing-transferred 32-byte secret is long-lived, but application traffic
keys are unique to a live peer connection. Every peer generates a fresh 32-byte
`nonce` and random 32-bit `connEpoch` whenever it opens a WebSocket.

Every peer E2EE wire has a clear routing tag followed by a sealed message:

```text
wire = routingTag(16) || seq(u64 LE) || combined
combined = ChaChaPoly.seal(plaintextFrame, key,
                           aad=routingTag || seqBytes).combined
```

`combined` is nonce(12) + ciphertext + Poly1305 tag(16). The routing tag is
therefore visible to the relay but authenticated as AEAD context; changing a
tag makes decryption fail.

### 4.1 Bootstrap hello

The all-zero 16-byte tag is reserved for bootstrap frames. Its key uses the
long-term secret directly with the channel-specific v2 derivation:

```text
bootstrapTag = 0x00000000000000000000000000000000
key_h2c_bootstrap = HKDF-SHA256(secret, salt="pedals-v2",
                               info="host->client" + channelSuffix, 32)
key_c2h_bootstrap = HKDF-SHA256(secret, salt="pedals-v2",
                               info="client->host" + channelSuffix, 32)
```

The control suffix is empty; a session suffix is `:session:<sid>`. The only
peer frame valid under a bootstrap key is:

```text
hello {who,principal,connEpoch,nonce,ver,host?}
```

`ver` is 2, `nonce` is 32 bytes encoded as base64 by JSON, and `connEpoch`
must equal the high 32 bits of the authenticated sequence number. `principal`
is the sender's stable 32-hex identity: `computerId` for a host and `clientId`
for a client. `host` is optional and is sent only by the daemon. On the host,
the encrypted client `principal` must exactly equal the authenticated source
envelope before the hello can create a pending candidate. A mismatch is
dropped without committing bootstrap replay state.

A valid hello creates a pending peer candidate; it does not authorize
application traffic. This distinction is required because a bootstrap hello
is encrypted with long-term keys and can be replayed by an untrusted relay.

### 4.2 Connection-bound keys and ready proof

After receiving a valid peer hello, both sides order the two fresh nonces as
host then client and derive:

```text
connectionSalt = SHA256("pedals-v2-connection" || hostNonce || clientNonce)
routingTag = first16(SHA256("pedals-v2-tag" || hostNonce || clientNonce))

key_h2c = HKDF-SHA256(secret, salt=connectionSalt,
                      info="host->client" + channelSuffix, 32)
key_c2h = HKDF-SHA256(secret, salt=connectionSalt,
                      info="client->host" + channelSuffix, 32)
```

Each peer then sends, under the connection-bound key and `routingTag`:

```text
ready {who,echoNonce}
```

`echoNonce` must equal the nonce from the recipient's hello. A candidate
becomes active only after its `ready` decrypts with the derived key and echoes
the local nonce. Thus a captured hello or application ciphertext from an older
connection cannot become active when either fresh nonce changes.

Only active tags may carry application frames. On the host, distinct client
principals remain active concurrently, each with an independent tag and cipher
state. A proven reconnect with the same stable principal replaces that
principal's previous tag. Pending and active tags retain that authenticated
source principal; every later client frame must carry the same source before
decryption or receive-counter advancement. A client keeps only the newly
proven host tag.

### 4.3 Sequence and channel isolation

`seq` embeds the sender's `connEpoch` in its high 32 bits and a counter starting
at 1 in its low 32 bits. The receiver tracks the greatest accepted counter per
epoch and rejects duplicates and stale frames. Authentication also fails for a
different direction, routing tag, connection nonce pair, or channel suffix.
This prevents the relay from moving ciphertext between clients, connections,
the control channel, or terminal channels.

## 5. Encrypted frames

```text
frame = type(u8) || sessionId(u32 LE) || payload
```

| type | name | direction | payload |
|---|---|---|---|
| `0x00` | ctl | both | UTF-8 control JSON |
| `0x01` | stdin | client to host | raw PTY bytes |
| `0x02` | stdout | host to client | raw PTY bytes |
| `0x03` | resize | both | cols u16 LE, rows u16 LE |
| `0x04` | replay | host to client | raw replay-buffer snapshot |

Handshake control frames use `sessionId = 0` on every WebSocket channel:

- `hello {who,principal,connEpoch,nonce,ver,host?}` is the bootstrap frame.
- `ready {who,echoNonce}` is the first connection-bound frame.

After `ready` promotes the tag, the control channel accepts:

- `sessions {list:[{id,title,cwd,rows,cols,createdAt,alive}]}`
- `dismiss-agent {agentId}` — client to host: remove one observed agent from
  the registry. The agent list is bidirectional: a dismissal removes the
  record for every client (clients hide the row optimistically first, no
  persistence), and the agent's next hook event recreates it.
- `agents {agents:[{id,agent,state,sessionName?,cwd,action?,message?,prompt?,sessionId?,term?,updatedAt}]}`
  — host to client: full snapshot of coding-agent sessions observed via
  daemon-installed hooks (docs/AGENT_MONITORING_DESIGN.md). `state` is
  `running|waiting|error|done`; `sessionId` is set when the agent runs inside
  a daemon-owned PTY (the dedup rule), `sessionName` is the user-facing session
  title, and `term` names the terminal app for unmanaged agents. Broadcast
  debounced on change and replayed after `sessions` on every client hello.
  Rich agent content exists only inside these encrypted frames, never in relay
  metadata.
- `create {cwd,cols,rows,req?}` / `created {id,req?}`
- `close {id}`, `title {id,title}`, `exit {id,code}`
- `err {msg,req?}`

An active session channel accepts `requestReplay {}` from client to host as a
ctl frame with `sessionId = 0`. The host answers with a current `replay` frame;
this is how a reconnect recovers output because the relay never queues it.
`stdin`, `stdout`, `resize`, and `replay` frames carry the authenticated URL's
session ID and are rejected if it differs.

After applying a client resize to the PTY, the host sends the authoritative
`resize` frame back on the session channel before any `stdout` caused by the
resulting `SIGWINCH`. The host also sends the current size immediately before a
requested `replay`. Small renderers such as the Watch projection therefore
update their grid before parsing cursor-addressed output, without relying on
ordering from the separate control channel's `sessions` message.

Terminal titles, paths, dimensions, and contents exist only inside these
encrypted frames. Session IDs and alive flags are deliberately duplicated into
the privacy-safe DO directory so every client and widget uses one authoritative
online state.

## 6. Status state and APNs endpoints

An authenticated `statusToken` reads its server-authoritative aggregate from:

```http
GET /v2/clients/me/state
```

```json
{
  "version": 2,
  "totalRunning": 3,
  "agentsRunning": 2,
  "agentsWaiting": 1,
  "agentsDone": 0,
  "computers": [
    {
      "id": "...",
      "name": "MacBook Pro",
      "runningTTYCount": 3,
      "agents": {"running": 2, "waiting": 1, "done": 0},
      "online": true,
      "updatedAt": "2026-07-18T00:00:00.000Z"
    }
  ],
  "updatedAt": "2026-07-18T00:00:00.000Z",
  "sequence": 42,
  "stale": false
}
```

Offline computers contribute zero to `totalRunning` and to the agent counts;
their last reported values are never presented as current.

WidgetKit and ActivityKit tokens are registered with:

```http
PUT /v2/clients/me/push-endpoints/:surface
{"token":"<hex>","environment":"sandbox|production","activityId":"..."?}
```

Allowed surfaces are `ios-widget`, `watch-widget`, `liveactivity-start`, and
`liveactivity-update`. APNs topics and push types
are fixed by the Worker, not accepted from clients.

- Widget push uses `apns-push-type: widgets` and only asks WidgetKit to reload;
  the timeline provider then reads `/state`.
- Live Activity start/update/end uses `apns-push-type: liveactivity`, attributes
  `TTYActivityAttributes {scope:"all"}`, and content state containing
  `totalRunning`, `agentsRunning`, `agentsWaiting`, `agentsDone`, online/offline
  computer counts, `updatedAt`, and `sequence`. In the foreground the app
  requests a normal activity locally, without an alert. Count invalidations
  never consume a push-to-start token. A remote start is reserved for an
  attention event and therefore carries the ActivityKit-required alert. The
  activity ends when the aggregate returns to zero.
- APNs provider keys exist only as encrypted Worker secrets. Invalid device
  tokens are removed; throttled/server failures are retried with backoff.

### 6.1 Rich agent Live Activity content

The daemon sends the most recent agent as transient host metadata:

```json
{"type":"agent-activity","activity":{"eventID":"<uuid>",
 "state":"running|waiting|error|done","updatedAt":1770000000000,
 "alert":false,"sealed":"<base64>"}}
```

The Worker immediately fans this to bound clients' Live Activity endpoints
and retains only the newest opaque envelope per active computer in that
client's PushCoordinator Durable Object. The envelope is removed when the
agent disappears or the Activity ends and is never written to D1. This lets a
durable terminal-count retry re-attach the concrete agent card instead of
replacing it with aggregate fallback content. `sealed` is
`ChaChaPoly(key_activity, aad=computerId)`
over the compact agent/project/prompt/action/message snapshot, where

```
key_activity = HKDF-SHA256(ikm=secret, salt="pedals-v2", info="live-activity", 32)
```

is deliberately distinct from both traffic keys. The phone mirrors only this
derived key into the widget extension's shared keychain group, and the widget
decrypts the content while rendering the Lock Screen and Dynamic Island.
Running content is throttled and silent. Entry into `waiting`, `error`, or
`done` sets `alert=true`; only those events can remotely start and visibly
expand the island. The APNs alert remains generic because the provider cannot
read the ciphertext, and it deliberately has no sound. The aggregate counts
remain the durable fallback if a transient rich update is lost.

## 7. Desktop local control

`~/.pedals/pedals.sock` carries newline-delimited JSON requests for `ls`, `new`,
`kill`, `pair`, `cancelPair`, `status`, `agent-event`, and `agents`. Responses
use `{"ok":true,...}` or `{"ok":false,"err":"..."}`.

`agent-event` is sent by the `pedals-hook` reporter (installed into coding
agents' hook settings by `pedals hooks install` or the menu bar app):
`{"cmd":"agent-event","noReply":true,"agent":"claude","event":"session-start|prompt|ask|tool|
busy|notify|compact|stop|session-end","agentSessionId":"...","sessionName"?,
"cwd"?,"prompt"?,"message"?,"action"?,"agentError"?,
"lineage":[{"pid","name","tty"?}]}`. The daemon's AgentMonitor applies the
state machine, matches `lineage`/`tty` against daemon-owned PTYs, and broadcasts
the encrypted `agents` ctl snapshot. `noReply=true` makes reporter delivery
strictly one-way: stdin and socket operations are bounded and the daemon does
not write an acknowledgement after the reporter exits. For managed sessions, the daemon's live
terminal title is authoritative for `sessionName`; otherwise an agent adapter
may report an explicit session-name field.
`pedals hooks install|uninstall|status <agent>` manages ten agents — claude,
codex, copilot, grok, kimi, kiro, opencode, omp, pi, hermes — writing
sentinel-marked entries (`# pedals-managed-hook`) into each agent's own hook
settings, or a marker-owned generated plugin file for the plugin-based agents;
user content is never overwritten.
`agents` returns the current registry as `{"ok":true,"agents":[...]}` in the
ctl `agents` entry shape. `pair` returns a fresh eight-digit `code` and
`expiresAt`, revoking any prior pairing session for that computer. `cancelPair`
revokes the current session when its pairing surface closes. `pair --reset`
registers a new computer identity and rotates the host token and E2EE secret
before requesting the code.

The daemon launches interactive login shells in PTYs, keeps a 256 KiB raw
replay buffer per session, parses OSC 0/2 titles locally, limits the directory
to 255 sessions, and persists a session ID high-water mark so a terminal channel
key is never reused. It reports offline before macOS sleep and `SIGINT`/`SIGTERM`,
then publishes a complete snapshot after wake or reconnect.
