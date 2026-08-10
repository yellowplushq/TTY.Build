# TTYBuildKit cross-implementation test vectors

Canonical vectors asserted byte-for-byte by both the Swift test suite
(`shared/TTYBuildKit/Tests/TTYBuildKitTests/TestVectorTests.swift`) and the Node reference
implementation (`relay/test/crypto-ref.mjs`). All values are lowercase hex unless noted.

## Inputs

| value  | bytes |
|--------|-------|
| secret | 32 bytes of `0x42` — `4242…42` (×32) |

## HKDF-SHA256 direction keys (PROTOCOL.md §4.1)

`salt = "ttybuild-v2"` (UTF-8, 11 bytes), output length 32 bytes.

| key | info | value |
|-----|------|-------|
| key_h2c | `host->client` | `f57dfa58483b0961b807a597accdf09ad32d7898d6068e2e27606dddced0e878` |
| key_c2h | `client->host` | `bfcae2fa3792508f62ad8fbf386d04ca61577abf5dfed1b3b236dcb16fe3ed96` |

Node reproduction:

```js
const crypto = require('node:crypto');
const secret = Buffer.alloc(32, 0x42);
const key = Buffer.from(
  crypto.hkdfSync('sha256', secret, Buffer.from('ttybuild-v2'), Buffer.from('host->client'), 32));
```

## Sealed message (PROTOCOL.md §4, direction host→client, key_h2c)

Nonces are random on the wire. This vector's nonce was **fixed once at generation time**
(the ASCII string `ttybld-nonce`, exactly 12 bytes) so both implementations can assert the
exact same blob; tests must *decrypt* this embedded message, never re-seal and compare.

| field | value |
|-------|-------|
| plaintext frame | ctl frame: type `0x00` \|\| sessionId 0 (u32 LE) \|\| `"hello"` = `000000000068656c6c6f` |
| seq | 1 |
| AAD (seq u64 LE) | `0100000000000000` |
| nonce | `747479626c642d6e6f6e6365` (`ttybld-nonce`) |
| ciphertext (10 bytes) | `575f3c48a735ba958334` |
| Poly1305 tag (16 bytes) | `81d24d2f06b0a8c4b6ffd7a33074321e` |
| combined (nonce ‖ ct ‖ tag) | `747479626c642d6e6f6e6365575f3c48a735ba95833481d24d2f06b0a8c4b6ffd7a33074321e` |
| **sealed message** (seq ‖ combined) | `0100000000000000747479626c642d6e6f6e6365575f3c48a735ba95833481d24d2f06b0a8c4b6ffd7a33074321e` |

This is the sealed message without its 16-byte routing-tag prefix, sealed with
an empty AAD tag context (AAD = seq only). On the v2 wire (PROTOCOL.md §4),
`RelayLink` prepends the routing tag and includes it in the AAD:
`wire = routingTag(16) ‖ seq ‖ combined` with `AAD = routingTag ‖ seq`.

Expected assertions in both suites:

1. Opening the sealed message with `key_h2c` and AAD `0100000000000000` yields the plaintext
   frame `000000000068656c6c6f` (ctl, sessionId 0, payload `hello`).
2. Opening the same message a second time on the same channel fails (seq 1 is not
   strictly greater than the last accepted seq 1 — replay rejection).
3. Opening the message with `key_c2h` fails authentication (direction keys are distinct).
