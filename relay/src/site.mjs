const REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const MACOS_ASSET = "Pedals-macOS.dmg";
const MACOS_ZIP_ASSET = "Pedals-macOS.zip";
const APPCAST_ASSET = "appcast.xml";
const DESKTOP_ASSETS = new Map([
  ["/download/macos", MACOS_ASSET],
  ["/download/macos.zip", MACOS_ZIP_ASSET],
  ["/download/macos.zip.sha256", `${MACOS_ZIP_ASSET}.sha256`],
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
        : "The Pedals desktop download is not configured yet.\n",
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

export async function handleWebsiteAsset(request, env) {
  if (!env.ASSETS || typeof env.ASSETS.fetch !== "function") return null;
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
  return new Response(request.method === "HEAD" ? null : response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export { APPCAST_ASSET, MACOS_ASSET, MACOS_ZIP_ASSET };
