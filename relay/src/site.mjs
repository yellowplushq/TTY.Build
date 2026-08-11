import { clientAddress, enforceRateLimit } from "./core.mjs";
import { injectPairingCode } from "./paired-zip.mjs";

const REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const UPSTREAM_ZIP_CACHE_SECONDS = 5 * 60;
const MACOS_ASSET = "TTYBuild-macOS.dmg";
const MACOS_ZIP_ASSET = "TTYBuild-macOS.zip";
const CLI_ZIP_ASSET = "ttybuild-cli-macOS.zip";
const APPCAST_ASSET = "appcast.xml";
const DESKTOP_ASSETS = new Map([
  ["/download/macos", MACOS_ASSET],
  ["/download/macos.zip", MACOS_ZIP_ASSET],
  ["/download/macos.zip.sha256", `${MACOS_ZIP_ASSET}.sha256`],
  // The signed universal ttybuild CLI, published next to the app in the
  // same release (install.sh --cli).
  ["/download/cli.zip", CLI_ZIP_ASSET],
  ["/download/cli.zip.sha256", `${CLI_ZIP_ASSET}.sha256`],
  ["/appcast.xml", APPCAST_ASSET],
]);

function redirect(location, method) {
  return new Response(null, {
    status: 302,
    headers: {
      "cache-control": "no-store",
      location,
      ...(method === "HEAD" ? { "content-length": "0" } : {}),
    },
  });
}

export function handleDesktopDownload(request, env, url) {
  if (!["GET", "HEAD"].includes(request.method)) return null;
  if (url.pathname === "/download") return redirect("/download/macos", request.method);
  const asset = DESKTOP_ASSETS.get(url.pathname);
  if (!asset) return null;

  const repository = String(env.DESKTOP_RELEASE_REPOSITORY ?? "").trim();
  if (!REPOSITORY.test(repository)) {
    return new Response(
      request.method === "HEAD"
        ? null
        : "The TTY.Build desktop download is not configured yet.\n",
      {
        status: 503,
        headers: {
          "cache-control": "no-store",
          "content-type": "text/plain; charset=utf-8",
          "retry-after": "300",
        },
      },
    );
  }

  return redirect(
    `https://github.com/${repository}/releases/latest/download/${asset}`,
    request.method,
  );
}

// Short aliases that serve an existing static asset without a redirect, so
// `curl https://tty.build/i | bash` stays a single round trip.
const ASSET_ALIASES = new Map([["/i", "/install.sh"]]);

// `curl https://tty.build/12345678 | bash` — the shortest install
// command: an 8-digit path serves install.sh with that enrollment code baked
// in as the TTYBUILD_PAIR default. Purely textual — the code is never checked
// against the token table here, so the route leaks nothing about which codes
// exist.
const INSTALL_CODE_PATH = /^\/(\d{8})$/;

/// `GET /download/<code>/macos.zip` — the release zip with the enrollment
/// code stamped in as an AppleDouble xattr entry, so an AirDropped or
/// browser-downloaded archive pairs on first launch with zero typing. The
/// signed TTYBuild.app bytes pass through untouched; when the archive cannot
/// be rewritten safely the untouched original is served instead. The code is
/// never validated here — the URL reveals nothing about which codes exist.
export async function handlePairedDownload(
  request,
  env,
  code,
  fetchImpl = globalThis.fetch,
) {
  if (!["GET", "HEAD"].includes(request.method)) return null;
  const repository = String(env.DESKTOP_RELEASE_REPOSITORY ?? "").trim();
  if (!REPOSITORY.test(repository)) {
    return new Response(
      request.method === "HEAD"
        ? null
        : "The TTY.Build desktop download is not configured yet.\n",
      {
        status: 503,
        headers: {
          "cache-control": "no-store",
          "content-type": "text/plain; charset=utf-8",
          "retry-after": "300",
        },
      },
    );
  }

  const headers = {
    "cache-control": "no-store",
    "content-type": "application/zip",
    "content-disposition": `attachment; filename="${MACOS_ZIP_ASSET}"`,
    "x-content-type-options": "nosniff",
  };
  if (request.method === "HEAD") {
    return new Response(null, { status: 200, headers });
  }

  // The stamped response itself must never be cached (it is per-code), but
  // the untouched upstream archive can be, bounding upstream bandwidth when
  // codes are fetched in bursts. Per-address rate limiting bounds the
  // archive-sized buffers a single caller can force.
  await enforceRateLimit(env, "INVITE_LIMITER", clientAddress(request), {
    code: "download_rate_limited",
    message: "too many paired downloads from this address",
  });

  const upstreamURL =
    `https://github.com/${repository}/releases/latest/download/${MACOS_ZIP_ASSET}`;
  const cache = globalThis.caches?.default;
  const cacheKey = new Request(upstreamURL);
  let upstream = await cache?.match(cacheKey);
  if (!upstream) {
    upstream = await fetchImpl(upstreamURL, { redirect: "follow" });
    if (!upstream.ok) {
      return new Response("The TTY.Build release download failed upstream.\n", {
        status: 502,
        headers: {
          "cache-control": "no-store",
          "content-type": "text/plain; charset=utf-8",
          "retry-after": "300",
        },
      });
    }
    if (cache) {
      const cacheable = new Response(upstream.body, upstream);
      cacheable.headers.set(
        "cache-control",
        `public, max-age=${UPSTREAM_ZIP_CACHE_SECONDS}`,
      );
      upstream = cacheable;
      await cache.put(cacheKey, cacheable.clone());
    }
  }
  const original = new Uint8Array(await upstream.arrayBuffer());
  const injected = injectPairingCode(original, code) ?? original;
  return new Response(injected, { status: 200, headers });
}

export async function handleWebsiteAsset(request, env) {
  if (!env.ASSETS || typeof env.ASSETS.fetch !== "function") return null;
  const url = new URL(request.url);
  const codeMatch = INSTALL_CODE_PATH.exec(url.pathname);
  const alias = codeMatch ? "/install.sh" : ASSET_ALIASES.get(url.pathname);
  if (alias) {
    url.pathname = alias;
    request = new Request(url, request);
  }
  const response = await env.ASSETS.fetch(request);
  const headers = new Headers(response.headers);
  headers.set("x-content-type-options", "nosniff");
  headers.set("referrer-policy", "no-referrer");
  headers.set("x-frame-options", "DENY");
  headers.set(
    "permissions-policy",
    "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
  );
  if (new URL(request.url).protocol === "https:") {
    headers.set("strict-transport-security", "max-age=31536000; includeSubDomains");
  }

  let body = request.method === "HEAD" ? null : response.body;
  if (codeMatch && response.ok) {
    headers.delete("content-length");
    if (body !== null) {
      const script = await response.text();
      body = script.replace("TTYBUILD_PAIR:-", `TTYBUILD_PAIR:-${codeMatch[1]}`);
    }
  }
  return new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export { APPCAST_ASSET, CLI_ZIP_ASSET, MACOS_ASSET, MACOS_ZIP_ASSET };
