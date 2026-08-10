import assert from "node:assert/strict";

const baseURL = new URL(process.env.RELAY_HTTP_URL ?? "https://tty.build");
const timeoutMilliseconds = 15_000;
const clientSourceEnvelopeBytes = 33;

async function request(path, { method = "GET", token, body } = {}) {
  const headers = new Headers({ accept: "application/json" });
  if (token) headers.set("authorization", `Bearer ${token}`);
  const init = {
    method,
    headers,
    signal: AbortSignal.timeout(timeoutMilliseconds),
  };
  if (body !== undefined) {
    headers.set("content-type", "application/json");
    init.body = JSON.stringify(body);
  }
  return fetch(new URL(path, baseURL), init);
}

async function json(path, options, expectedStatus) {
  const response = await request(path, options);
  const text = await response.text();
  assert.equal(
    response.status,
    expectedStatus,
    `${options?.method ?? "GET"} ${path}: HTTP ${response.status} ${text}`,
  );
  return text === "" ? null : JSON.parse(text);
}

function eventQueue() {
  const values = [];
  const waiters = [];
  return {
    push(value) {
      const waiter = waiters.shift();
      if (waiter) waiter.resolve(value);
      else values.push(value);
    },
    next(label) {
      if (values.length > 0) return Promise.resolve(values.shift());
      return new Promise((resolve, reject) => {
        const waiter = { resolve };
        waiters.push(waiter);
        const timer = setTimeout(() => {
          const index = waiters.indexOf(waiter);
          if (index !== -1) waiters.splice(index, 1);
          reject(new Error(`timed out waiting for ${label}`));
        }, timeoutMilliseconds);
        waiter.resolve = (value) => {
          clearTimeout(timer);
          resolve(value);
        };
      });
    },
  };
}

async function connect(computerId, token) {
  const url = new URL(`/v2/relay/${computerId}?channel=control`, baseURL);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  const ws = new WebSocket(url, {
    headers: { authorization: `Bearer ${token}` },
  });
  ws.binaryType = "arraybuffer";
  const binary = eventQueue();
  const text = eventQueue();
  const opened = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("WebSocket open timed out")), timeoutMilliseconds);
    ws.addEventListener("open", () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
    ws.addEventListener("error", () => {
      clearTimeout(timer);
      reject(new Error(`WebSocket upgrade failed for ${url}`));
    }, { once: true });
  });
  ws.addEventListener("message", (event) => {
    if (typeof event.data === "string") text.push(event.data);
    else binary.push(new Uint8Array(event.data));
  });
  await opened;
  return {
    ws,
    nextBinary: () => binary.next("binary relay frame"),
    nextText: () => text.next("relay metadata"),
  };
}

function decodeClientSourceEnvelope(message) {
  assert.ok(message.length > clientSourceEnvelopeBytes, "client source envelope is truncated");
  assert.equal(message[0], 0x02, "unexpected client source envelope version");
  const principalId = new TextDecoder().decode(message.subarray(1, 33));
  assert.match(principalId, /^[0-9a-f]{32}$/);
  return { principalId, wire: message.subarray(clientSourceEnvelopeBytes) };
}

async function waitForState(statusToken, predicate) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    const state = await json(
      "/v2/clients/me/state",
      { token: statusToken },
      200,
    );
    if (predicate(state)) return state;
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  throw new Error("timed out waiting for state propagation");
}

let computer = null;
let host = null;
let clientSocket = null;
let delegatedSocket = null;
try {
  computer = await json("/v2/computers", { method: "POST" }, 201);
  const client = await json("/v2/clients", { method: "POST" }, 201);
  assert.match(computer.computerId, /^[0-9a-f]{32}$/);
  assert.match(computer.hostToken, /^[A-Za-z0-9_-]{43}$/);
  assert.match(client.clientId, /^[0-9a-f]{32}$/);
  assert.match(client.clientToken, /^[A-Za-z0-9_-]{43}$/);
  assert.match(client.statusToken, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(client.clientToken, client.statusToken);

  const hostPublicKey = "A".repeat(43);
  const clientPublicKey = "B".repeat(43);
  const encryptedSecret = "C".repeat(80);
  const pairing = await json(
    `/v2/computers/${computer.computerId}/pairing-codes`,
    {
      method: "POST",
      token: computer.hostToken,
      body: { publicKey: hostPublicKey },
    },
    201,
  );
  assert.match(pairing.codeId, /^[0-9a-f]{32}$/);
  assert.match(pairing.code, /^\d{8}$/);
  assert.equal(pairing.singleUse, true);
  assert.ok(pairing.expiresAt > Math.floor(Date.now() / 1000));

  const claim = await json(
    "/v2/clients/me/pairing-codes/claim",
    {
      method: "POST",
      token: client.clientToken,
      body: { code: pairing.code, publicKey: clientPublicKey },
    },
    200,
  );
  assert.match(claim.claimId, /^[0-9a-f]{32}$/);
  assert.equal(claim.computerId, computer.computerId);
  assert.equal(claim.hostPublicKey, hostPublicKey);

  const claimed = await json(
    `/v2/computers/${computer.computerId}/pairing-codes/${pairing.codeId}`,
    { token: computer.hostToken },
    200,
  );
  assert.equal(claimed.status, "claimed");
  assert.equal(claimed.claimId, claim.claimId);
  assert.equal(claimed.clientPublicKey, clientPublicKey);

  await json(
    `/v2/computers/${computer.computerId}/pairing-claims/${claim.claimId}/complete`,
    {
      method: "POST",
      token: computer.hostToken,
      body: { encryptedSecret },
    },
    204,
  );
  const sealed = await json(
    `/v2/clients/me/pairing-claims/${claim.claimId}`,
    { token: client.clientToken },
    200,
  );
  assert.equal(sealed.status, "sealed");
  assert.equal(sealed.encryptedSecret, encryptedSecret);
  await json(
    `/v2/clients/me/pairing-claims/${claim.claimId}/accept`,
    { method: "POST", token: client.clientToken },
    201,
  );

  host = await connect(computer.computerId, computer.hostToken);
  clientSocket = await connect(computer.computerId, client.clientToken);
  assert.deepEqual(JSON.parse(await clientSocket.nextText()), {
    type: "terminal-directory",
    revision: 0,
    online: false,
    hostName: null,
    sessions: [],
    updatedAt: 0,
  });

  const down = Uint8Array.from([0, 2, 4, 8, 16, 32, 64, 128, 255]);
  host.ws.send(down);
  assert.deepEqual(await clientSocket.nextBinary(), down);
  const up = Uint8Array.from([255, 127, 63, 31, 15, 7, 3, 1, 0]);
  clientSocket.ws.send(up);
  const forwarded = decodeClientSourceEnvelope(await host.nextBinary());
  assert.equal(forwarded.principalId, client.clientId);
  assert.deepEqual(forwarded.wire, up);

  host.ws.send(JSON.stringify({
    type: "host-snapshot",
    hostName: "Contract Mac",
    sessions: [{ id: 1, alive: true }],
  }));
  const directory = JSON.parse(await clientSocket.nextText());
  assert.equal(directory.type, "terminal-directory");
  assert.equal(directory.revision, 1);
  assert.equal(directory.online, true);
  assert.equal(directory.hostName, "Contract Mac");
  assert.deepEqual(directory.sessions, [{ id: 1, alive: true }]);
  assert.ok(Number.isSafeInteger(directory.updatedAt) && directory.updatedAt > 0);
  const state = await waitForState(
    client.statusToken,
    (value) => value.version === 2 && value.totalRunning === 1,
  );
  assert.equal(state.computers[0].name, "Contract Mac");
  assert.equal(state.computers[0].runningTTYCount, 1);

  const delegated = await json("/v2/clients", { method: "POST" }, 201);
  const synchronized = await json(
    "/v2/clients/me/delegated-bindings",
    {
      method: "PUT",
      token: client.clientToken,
      body: {
        clientId: delegated.clientId,
        clientToken: delegated.clientToken,
      },
    },
    200,
  );
  assert.equal(synchronized.bindingCount, 1);
  delegatedSocket = await connect(computer.computerId, delegated.clientToken);
  const delegatedDirectory = JSON.parse(await delegatedSocket.nextText());
  assert.equal(delegatedDirectory.type, "terminal-directory");
  assert.equal(delegatedDirectory.online, true);
  assert.deepEqual(delegatedDirectory.sessions, [{ id: 1, alive: true }]);
  const delegatedState = await waitForState(
    delegated.statusToken,
    (value) => value.version === 2 && value.totalRunning === 1,
  );
  assert.equal(delegatedState.computers[0].id, computer.computerId);

  const legacy = await request(`/v1/room/${computer.computerId}`);
  assert.equal(legacy.status, 404, "v1 route must not exist");
  console.log(`v2 contract passed: ${baseURL.origin}`);
} finally {
  try {
    host?.ws.close(1000, "contract complete");
    clientSocket?.ws.close(1000, "contract complete");
    delegatedSocket?.ws.close(1000, "contract complete");
  } catch {
    // Cleanup continues through the authenticated HTTP reset.
  }
  if (computer) {
    try {
      await request(`/v2/computers/${computer.computerId}`, {
        method: "DELETE",
        token: computer.hostToken,
      });
    } catch {
      // Preserve the original contract failure if best-effort cleanup fails.
    }
  }
}

// Node's built-in WebSocket can retain its transport while the remote close
// handshake drains. All assertions and authenticated cleanup are complete at
// this point, so do not let that implementation detail hang release workflows.
process.exit(0);
