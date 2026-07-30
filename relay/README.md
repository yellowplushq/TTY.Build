# Pedals service protocol v2

This Worker is the only Pedals server. It combines an authenticated WebSocket
relay, the device-to-computer binding registry, a Durable Object-owned terminal
directory, and APNs delivery. Terminal frames remain end-to-end encrypted; D1
never stores the pairing encryption secret, terminal bytes, titles, or working
directories.

The public origin is `https://pedals.air.build`. All API responses are JSON with
`Cache-Control: no-store`. JSON request bodies are limited to 16 KiB. Errors use:

```json
{"error":{"code":"machine_code","message":"human readable message"}}
```

Credentials are opaque 32-byte base64url bearer tokens. Put them only in the
`Authorization: Bearer <token>` header, never in a URL or log.

## Website and desktop download

The same Worker serves the one-screen product website from `public/`. API and
WebSocket routes continue to run through the Worker first; all other `GET` and
`HEAD` requests fall through to the static asset binding.

`GET /download/macos` redirects without caching to the fixed
`Pedals-macOS.dmg` asset on the latest GitHub release. Configure the release
repository as a Wrangler variable before deployment:

```json
"vars": {
  "DESKTOP_RELEASE_REPOSITORY": "owner/pedals"
}
```

The route returns `503` instead of sending users to an unverified repository
when that variable is absent or malformed. See `docs/DESKTOP_RELEASE.md` for
the signed and notarized desktop release workflow.

## Enrollment and pairing

### `POST /v2/computers`

No body or `{}`. Creates a host identity.

```json
{"computerId":"32-lowercase-hex","hostToken":"opaque-bearer"}
```

The daemon stores both values in its mode-0600 identity file. It separately
generates the 32-byte E2EE secret; that secret is never sent to this API.

### `POST /v2/computers/:computerId/pairing-sessions`

Host bearer required. Opening the desktop pairing page generates an ephemeral
Curve25519 key and submits only its base64url public key:

```json
{"hostPublicKey":"43-character-base64url"}
```

The response contains an eight-digit single-use code valid for 15 minutes:

```json
{"sessionId":"32-lowercase-hex","code":"12345678","expiresAt":1780000000}
```

Creating a session deletes the computer's prior session. The daemon polls
`GET /v2/computers/:computerId/pairing-sessions/:sessionId`; closing the page
sends `DELETE` to that path. A claimed session exposes the client's ephemeral
public key only to the authenticated host.

### `POST /v2/clients/me/pairing-sessions/claim`

Client control bearer required:

```json
{"code":"12345678","clientPublicKey":"43-character-base64url"}
```

The code only selects the session; it is not encryption key material. After a
claim, the host uses ephemeral Curve25519, HKDF-SHA256, and ChaChaPoly to wrap
the computer's existing 32-byte E2EE secret. `POST
/v2/computers/:computerId/pairing-sessions/:sessionId/complete` atomically
creates the binding and retains only the encrypted envelope for its claiming
client. The client polls `GET /v2/clients/me/pairing-sessions/:sessionId`,
decrypts locally, stores its binding in Keychain, then acknowledges with
`DELETE` so the Worker removes the session.

D1 stores the code hash, public keys, ciphertext, identities, and timestamps;
it never receives the E2EE secret or either ephemeral private key. Completed,
cancelled, acknowledged, and expired sessions cannot be claimed again.

### `DELETE /v2/computers/:computerId`

Host bearer required. Atomically deletes the computer, its state, pairing sessions, and
all bindings, then closes every live host/client WebSocket for that computer.
Returns `204`. A seven-day hashed reset tombstone makes retrying the same reset
with the same host token idempotent. The deletion transaction also commits a
durable revocation outbox entry. The Worker attempts socket closure immediately
and cron retries with bounded backoff until the per-computer RelayChannel
acknowledges it, so a transient Durable Object failure cannot strand access
after reset.

### `PUT /v2/clients/me/bindings`

Client control bearer required. Body: `{"computerIds":[...]}` — the client's
declared authoritative binding set (at most 32 unique computer ids). The
service converges by deleting its own edges, and the delegated Watch's, that
are absent from the list; it never creates an edge, so a declared unknown id is
ignored and pairing remains the only way to add a binding. Returns
`{"computerIds":[...]}`, the server-side set after convergence.

Each removal and a client-targeted relay revocation outbox row commit in one
D1 transaction. The Worker closes the affected control/session sockets
immediately when possible with code `4003`; a handshake racing the deletion is
re-authorized inside the same actor and cannot survive. Cron retries transient
Durable Object failures until the RelayChannel acknowledges closure. Repeating
the declaration is idempotent. A later successful rebind clears any stale
retry row before new relay access is authorized.

### `POST /v2/clients`

No body or `{}`. Creates one logical client installation. An iPhone and its
terminal-viewing Watch use distinct relay client identities; Watch status and
push surfaces still use the iPhone's least-privilege status identity.

```json
{
  "clientId":"32-lowercase-hex",
  "clientToken":"opaque-control-bearer",
  "statusToken":"opaque-status-bearer"
}
```

The tokens are independent. `clientToken` is accepted only for binding changes
and relay WebSockets. `statusToken` is accepted only for state reads and APNs
endpoint management. Crossing those scopes returns `401`; D1 stores only their
independent SHA-256 hashes.

A client may bind at most 32 computers. The pairing completion and binding
limit check share one D1 transaction; a rejected over-limit attempt does not
complete the session.

### `PUT /v2/clients/me/delegated-bindings`

Source client control bearer required. Reconciles a second client principal's
server-side bindings to exactly the source client's current set:

```json
{"clientId":"32-lowercase-hex","clientToken":"opaque-control-bearer"}
```

Both credentials are verified and self-delegation is rejected. The operation
records one `watch-terminal` child relationship and copies only D1 binding
edges; it never accepts a computer E2EE secret. Removed edges commit
client-targeted relay revocations in the same D1 transaction and are closed
immediately when possible. A source-client unbind removes that computer from
both principals atomically. Replacing a lost Watch identity revokes the old
identity and its live sockets. The response is
`{"bindingCount":<number>}`. The iPhone uses this for an independent Watch
relay principal, then transfers the corresponding E2EE bindings directly with
WatchConnectivity.

## Current state

### `GET /v2/clients/me/state`

Status `statusToken` required. `totalRunning` sums the alive entries in each
online computer's current Durable Object directory projection. An offline
computer always reports a zero `runningTTYCount`.

```json
{
  "version": 2,
  "totalRunning": 3,
  "computers": [
    {
      "id":"...",
      "name":"Studio Mac",
      "runningTTYCount":3,
      "online":true,
      "updatedAt":"2026-07-18T03:10:00Z"
    },
    {
      "id":"...",
      "name":"Laptop",
      "runningTTYCount":0,
      "online":false,
      "updatedAt":"2026-07-18T03:09:00Z"
    }
  ],
  "updatedAt":"2026-07-18T03:10:00Z",
  "sequence":7,
  "stale":false
}
```

`sequence` increases whenever this client's binding set or an included
computer's name, online state, or count changes. Dates use ISO 8601 in UTC.
`stale` is false for every successful service response; the app sets it true
only when presenting expired cached data.

## Authenticated WebSocket relay

```text
GET /v2/relay/:computerId?channel=control
GET /v2/relay/:computerId?channel=session&sid=<canonical-u32>
Upgrade: websocket
Authorization: Bearer <host-or-client-token>
```

There is no role parameter. A host token grants the host role only for its own
computer. A client token grants the client role only while its D1 binding
exists. Unknown query parameters, leading-zero session IDs, and IDs above
`UInt32.max` are rejected.

Each computer maps to one hibernatable RelayChannel Durable Object; channel
ownership is
kept in serialized socket attachments. This lets an unbind/reset revoke every
live channel immediately. The newest host per channel replaces its predecessor;
host binary frames broadcast only within that channel, client frames go to its
active host, and absent-peer frames are dropped. One client socket is retained
per logical client/channel. A client principal may hold at most 16 active
logical channels for one computer, and a host may hold at most 256. Reconnecting
an existing channel replaces its old socket without consuming another slot.
Binary frames above 1 MiB and relay metadata above 16 KiB are closed rather
than amplified.

Before forwarding a client binary frame to the host, the Durable Object adds a
source envelope constructed only from the authenticated socket attachment:

```text
0x02 || clientId(32 lowercase ASCII hex bytes) || original E2EE wire
```

Host-to-client frames remain byte-for-byte unchanged. The host requires this
33-byte envelope, checks that its source exactly matches the encrypted client
hello, and binds the source to that hello's pending and active routing tags.
Frames whose source does not own the tag are dropped before decryption and
before replay counters advance. The 1 MiB limit applies to the original peer
wire, so the largest delivered host message is 1 MiB plus 33 bytes.

The active host sends a complete privacy-safe directory on the control socket
after connect, on each session-list change, and every 30 seconds:

```json
{
  "type":"host-snapshot",
  "hostName":"Studio Mac",
  "sessions":[{"id":1,"alive":true},{"id":2,"alive":false}]
}
```

Only the current authenticated host may mutate it. The RelayChannel stores at
most 255
ordered unique `{id,alive}` entries and assigns a revision. Every control client
receives the current value immediately on connect and after changes:

```json
{
  "type":"terminal-directory",
  "revision":12,
  "online":true,
  "hostName":"Studio Mac",
  "sessions":[{"id":1,"alive":true},{"id":2,"alive":false}],
  "updatedAt":1784512800
}
```

`hostName` is trimmed, nonempty, and at most 128 UTF-16 code units. Titles, cwd,
dimensions, and bytes remain E2EE. Clients intersect the encrypted descriptor
list with this directory; a late encrypted frame therefore cannot resurrect a
removed terminal.

`{"type":"host-offline"}` before sleep or orderly exit clears the remote
directory immediately without touching local PTYs. An unexpected control-socket
loss gets a 20-second grace period for weak-network reconnection. A connected
host snapshot has a 90-second lease as a silent-stall backstop. Expiry publishes
an offline directory with an empty session list and a reason. Session-channel
clients separately receive `{"type":"channel-state","online":...}` for
transport feedback; it is not directory authority.

D1 holds only the serialized DO transition's online/name/alive-count projection,
so `/state`, WidgetKit, Live Activities, and Watch all use exactly the same
server-authoritative count. Unchanged heartbeats renew only DO storage and do
not produce redundant APNs work.

Binary terminal frames continue to use the Pedals v2 E2EE format and HKDF salt
`pedals-v2`.

## Push endpoints

### `PUT /v2/clients/me/push-endpoints/:surface`

Status `statusToken` required. Token is opaque APNs token bytes encoded as lowercase
or uppercase hexadecimal. Registration is an upsert.

```json
{"token":"ab12...","environment":"sandbox","activityId":"optional-local-id"}
```

`environment` is `sandbox` or `production`. `activityId` distinguishes
`liveactivity-update` instances; it is rejected on the other three surfaces.
A client may retain at most eight active endpoints. Stale invalidated rows for
the same surface are removed when a new token is registered. Supported
surfaces and fixed APNs routing are:

| surface | `apns-push-type` | topic |
|---|---|---|
| `ios-widget` | `widgets` | `air.build.pedals.push-type.widgets` |
| `watch-widget` | `widgets` | `air.build.pedals.watchapp.push-type.widgets` |
| `liveactivity-start` | `liveactivity` | `air.build.pedals.push-type.liveactivity` |
| `liveactivity-update` | `liveactivity` | `air.build.pedals.push-type.liveactivity` |

The client cannot supply a topic, push type, header, or arbitrary payload.
Widget pushes contain only `aps.content-changed=true`; the refreshed timeline
then reads `GET /v2/clients/me/state`. Live Activity payloads contain
the five camel-case `TTYActivityAttributes.ContentState` fields and an
ActivityKit event. Starts use `attributes-type=TTYActivityAttributes`,
`attributes={"scope":"all"}`, and `input-push-token=1`. Ends include an
immediate `dismissal-date`. ActivityKit uses Foundation's default Codable
representation for `updatedAt`, while the HTTP API uses ISO 8601.

The first start-token registration is evaluated immediately, so installing or
launching the app while terminals are already running can start an activity.
Token rotation preserves the prior sequence/count baseline and therefore does
not create a duplicate activity for the same positive run. An update token
receives `update` while positive and `end` at zero, after which its short-lived
update row is deleted. The app also deletes that row by `activityId` when
ActivityKit reports the activity ended or dismissed. The long-lived start
endpoint is retained for the next zero-to-positive transition.

Activity content becomes stale five minutes after its source snapshot. APNs
may retain start/update events for 15 minutes while a device is offline, and an
end event for four hours so a stranded activity can still be closed. Ordinary
updates use APNs priority 5; start/end use priority 10.

### `DELETE /v2/clients/me/push-endpoints/:surface?activityId=...`

Status `statusToken` required. Idempotent `204`.

APNs `410`, `BadDeviceToken`, `DeviceTokenNotForTopic`, and `Unregistered`
invalidate an endpoint; invalid Live Activity update rows are deleted directly.
`429` and `5xx` responses retry from the durable push coordinator. A valid
`Retry-After` value is honored between one minute and 24 hours; absent or invalid
values use 15 minutes. Non-retryable topic, payload, and configuration failures
are quarantined for 24 hours instead of looping every minute, while a fresh
endpoint registration clears the quarantine immediately. Provider JWTs are
ES256 and cached for 50 minutes so the server does not rotate them too
frequently. Push coordinators are sharded per client; durable in-flight state
plus the minute reconciliation sweep recovers missed invalidations where an
endpoint sequence trails its client sequence. The sweep persists a round-robin
cursor so its 25-client pages cannot starve lexicographically later IDs.

## Abuse and capacity bounds

Every `/v2/` request first consumes a native Workers Rate Limiting token keyed
by Cloudflare's connecting IP. More specific limits are applied after the
relevant identity is known:

| operation | bound |
|---|---:|
| all `/v2/` requests | 300/minute/IP |
| computer registration | 5/minute/IP |
| client registration | 10/minute/IP |
| pairing-code creation | 10/minute/host+IP |
| authenticated binding/reset mutations | 60/minute/principal+IP |
| push endpoint mutations | 30/minute/client+IP |
| relay upgrade attempts | 120/minute/principal+IP |

Rate-limited responses are `429` with `Retry-After`; production fails closed
with `503` if a required limiter binding is unavailable. D1 provides exact
capacity backstops of 128 computers, 512 clients, one active pairing session
per computer, 32 bindings per client, and eight active push endpoints per client.
Native rate limits are intentionally an abuse throttle rather than a billing or
authorization boundary; the D1 predicates remain authoritative under concurrent
registrations.

Minute maintenance removes expired pairing sessions, unbound client identities
older than 24 hours (including their push endpoints), and
never-online, unnamed, unbound computers older than seven days. Each orphan
class is deleted in pages of at most 100 so cleanup work remains bounded.

## Cloudflare resources

Before the first deployment, create D1 and let Wrangler write its real UUID to
`wrangler.jsonc`. Configure all APNs secrets before applying a remote migration,
then use the repository deployment script so a missing secret cannot leave the
remote schema ahead of the deployed Worker:

```bash
npx wrangler d1 create pedals --binding DB --update-config
npx wrangler secret put APNS_PRIVATE_KEY_P8
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
cd ..
./scripts/deploy-relay.sh
```

`APNS_PRIVATE_KEY_P8` is the Apple `.p8` file contents. It must never be stored
in D1, source control, a Wrangler `vars` entry, or logs. The deployment script
runs the full relay tests, verifies all three secret names, applies pending D1
migrations, and captures Wrangler's immutable `Current Version ID`. It waits
until `https://pedals.air.build/healthz` reports that exact version on three
consecutive requests before executing the public contract, preventing an old
edge deployment from satisfying the readiness check. The health response body
remains `ok`; `X-Pedals-Worker-Version` identifies the serving version and all
health responses use `Cache-Control: no-store`.
