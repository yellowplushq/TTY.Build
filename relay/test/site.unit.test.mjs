import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  APP_STORE_URL,
  APPCAST_ASSET,
  CLI_ZIP_ASSET,
  handleDesktopDownload,
  handleWebsiteAsset,
  MACOS_ASSET,
  MACOS_ZIP_ASSET,
} from "../src/site.mjs";

function request(path, options = {}) {
  return new Request(`https://tty.build${path}`, options);
}

test("the stable download path redirects to the latest desktop release", async () => {
  const req = request("/download/macos");
  const response = handleDesktopDownload(
    req,
    { DESKTOP_RELEASE_REPOSITORY: "yellowplushq/TTY.Build" },
    new URL(req.url),
  );

  assert.equal(response.status, 302);
  assert.equal(
    response.headers.get("location"),
    `https://github.com/yellowplushq/TTY.Build/releases/latest/download/${MACOS_ASSET}`,
  );
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("the stable appcast path redirects to the latest signed update feed", () => {
  const req = request("/appcast.xml", { method: "HEAD" });
  const response = handleDesktopDownload(
    req,
    { DESKTOP_RELEASE_REPOSITORY: "yellowplushq/TTY.Build" },
    new URL(req.url),
  );

  assert.equal(response.status, 302);
  assert.equal(
    response.headers.get("location"),
    `https://github.com/yellowplushq/TTY.Build/releases/latest/download/${APPCAST_ASSET}`,
  );
  assert.equal(response.headers.get("content-length"), "0");
});

test("the zip download paths redirect to the latest release archive and checksum", () => {
  for (const [path, asset] of [
    ["/download/macos.zip", MACOS_ZIP_ASSET],
    ["/download/macos.zip.sha256", `${MACOS_ZIP_ASSET}.sha256`],
    ["/download/cli.zip", CLI_ZIP_ASSET],
    ["/download/cli.zip.sha256", `${CLI_ZIP_ASSET}.sha256`],
  ]) {
    const req = request(path);
    const response = handleDesktopDownload(
      req,
      { DESKTOP_RELEASE_REPOSITORY: "yellowplushq/TTY.Build" },
      new URL(req.url),
    );

    assert.equal(response.status, 302);
    assert.equal(
      response.headers.get("location"),
      `https://github.com/yellowplushq/TTY.Build/releases/latest/download/${asset}`,
    );
  }
});

test("the short download path redirects to the canonical path", () => {
  const req = request("/download", { method: "HEAD" });
  const response = handleDesktopDownload(req, {}, new URL(req.url));

  assert.equal(response.status, 302);
  assert.equal(response.headers.get("location"), "/download/macos");
  assert.equal(response.headers.get("content-length"), "0");
});

test("the iOS download path redirects to the App Store without release config", () => {
  const req = request("/download/ios");
  const response = handleDesktopDownload(req, {}, new URL(req.url));

  assert.equal(response.status, 302);
  assert.equal(response.headers.get("location"), APP_STORE_URL);
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("an unconfigured release repository fails without a misleading link", async () => {
  const req = request("/download/macos");
  const response = handleDesktopDownload(req, {}, new URL(req.url));

  assert.equal(response.status, 503);
  assert.match(await response.text(), /not configured/i);
  assert.equal(response.headers.get("retry-after"), "300");
});

test("download handling ignores unrelated routes and mutating methods", () => {
  const unrelated = request("/styles.css");
  const post = request("/download/macos", { method: "POST" });

  assert.equal(handleDesktopDownload(unrelated, {}, new URL(unrelated.url)), null);
  assert.equal(handleDesktopDownload(post, {}, new URL(post.url)), null);
});

test("website assets receive defense-in-depth response headers", async () => {
  const req = request("/");
  const response = await handleWebsiteAsset(req, {
    ASSETS: {
      fetch: async () =>
        new Response("<!doctype html><title>TTYBuild</title>", {
          headers: { "content-type": "text/html; charset=utf-8" },
        }),
    },
  });

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("x-frame-options"), "DENY");
  assert.equal(response.headers.get("x-content-type-options"), "nosniff");
  assert.equal(
    response.headers.get("strict-transport-security"),
    "max-age=31536000; includeSubDomains",
  );
  assert.match(await response.text(), /TTYBuild/);
});

test("the short /i alias serves the install script without a redirect", async () => {
  const fetched = [];
  const req = request("/i");
  const response = await handleWebsiteAsset(req, {
    ASSETS: {
      fetch: async (assetRequest) => {
        fetched.push(new URL(assetRequest.url).pathname);
        return new Response("#!/usr/bin/env bash\n", {
          headers: { "content-type": "text/x-shellscript" },
        });
      },
    },
  });

  assert.deepEqual(fetched, ["/install.sh"]);
  assert.equal(response.status, 200);
  assert.match(await response.text(), /^#!\/usr\/bin\/env bash/);
});

test("an 8-digit path serves the installer with that enrollment code baked in", async () => {
  const script = await readFile(new URL("../public/install.sh", import.meta.url), "utf8");
  const fetched = [];
  const req = request("/90285513");
  const response = await handleWebsiteAsset(req, {
    ASSETS: {
      fetch: async (assetRequest) => {
        fetched.push(new URL(assetRequest.url).pathname);
        return new Response(script, {
          headers: {
            "content-type": "text/x-shellscript",
            "content-length": String(script.length),
          },
        });
      },
    },
  });

  assert.deepEqual(fetched, ["/install.sh"]);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-length"), null);
  const rendered = await response.text();
  assert.match(rendered, /pair_code="\$\{TTYBUILD_PAIR:-90285513\}"/);
  // The template substitutes exactly one site; the rest of the script is
  // byte-identical.
  assert.equal(rendered.replace("90285513", ""), script);
});

test("the one-screen homepage exposes the product promise and download CTA", async () => {
  const html = await readFile(new URL("../public/index.html", import.meta.url), "utf8");
  assert.match(html, /Your terminal\./);
  assert.match(html, /href="\/favicon-32\.png"/);
  assert.match(html, /src="\/brand-icon\.png"/);
  assert.match(html, /href="\/download\/macos"/);
  assert.match(html, /href="https:\/\/apps\.apple\.com\/us\/app\/tty-build-agents-terminal\/id6792312114"/);
  assert.match(html, /8-digit code/);
  assert.match(html, /Terminal bytes and encryption keys never live on the service/);
  assert.match(html, /href="\/privacy\/"/);
  assert.match(html, /href="\/support\/"/);
});

test("the homepage offers the curl installer with a self-hosted copy button", async () => {
  const html = await readFile(new URL("../public/index.html", import.meta.url), "utf8");
  assert.match(html, /curl -fsSL https:\/\/tty\.build\/i \| bash/);
  assert.match(html, /data-copy="install-command-text"/);
  assert.match(html, /<script src="\/site\.js" defer><\/script>/);

  const script = await readFile(new URL("../public/site.js", import.meta.url), "utf8");
  assert.match(script, /navigator\.clipboard\.writeText/);

  const headers = await readFile(new URL("../public/_headers", import.meta.url), "utf8");
  assert.match(headers, /script-src 'self'/);

  const styles = await readFile(new URL("../public/styles.css", import.meta.url), "utf8");
  assert.match(styles, /\.install-command code \{[^}]*min-width: 0/);
  assert.match(styles, /\.install-command code \{[^}]*overflow-x: auto/);
});

test("the curl installer downloads the zip release and verifies its checksum", async () => {
  const script = await readFile(new URL("../public/install.sh", import.meta.url), "utf8");
  assert.match(script, /^#!\/usr\/bin\/env bash/);
  assert.match(script, /\/download\/macos\.zip/);
  assert.match(script, /\/download\/macos\.zip\.sha256/);
  assert.match(script, /shasum -a 256 -c/);
  assert.match(script, /read -r answer .*\/dev\/tty/);
  assert.doesNotMatch(script, /sudo/);
});

test("the curl installer distinguishes the desktop app from iOS Simulator", async () => {
  const script = await readFile(new URL("../public/install.sh", import.meta.url), "utf8");
  assert.match(script, /APP_BUNDLE_ID="build\.tty\.menubar"/);
  assert.match(
    script,
    /application id \\"\$APP_BUNDLE_ID\\" is running/,
  );
  assert.match(
    script,
    /tell application id \\"\$APP_BUNDLE_ID\\" to quit/,
  );
  assert.match(script, /command_line=.*ps -ww -p "\$pid" -o command=/);
  assert.match(script, /"\$command_line" == "\$executable"/);
});

test("the curl installer relaunches after a graceful quit timeout", async () => {
  const script = await readFile(new URL("../public/install.sh", import.meta.url), "utf8");
  assert.match(script, /TTY\.Build did not quit normally; stopping it before relaunch/);
  assert.match(script, /terminate_desktop_app/);
  assert.match(script, /close it and rerun the installer/);
});

test("the curl installer does not infer launch success from process state", async () => {
  const script = await readFile(new URL("../public/install.sh", import.meta.url), "utf8");
  const launchApp = script.match(/launch_app\(\) \{([\s\S]*?)\n\}/)?.[1] ?? "";
  assert.match(launchApp, /open "\$install_dir\/\$APP_NAME"/);
  assert.doesNotMatch(launchApp, /app_is_running/);
  assert.doesNotMatch(launchApp, /Launched TTYBuild/);
});

test("the curl installer stamps the enrollment code onto the app bundle", async () => {
  const script = await readFile(new URL("../public/install.sh", import.meta.url), "utf8");
  assert.match(script, /--pair\)/);
  assert.match(script, /TTYBUILD_PAIR/);
  assert.match(script, /\[0-9\]\{8\}/);
  assert.match(
    script,
    /xattr -w build\.tty\.pairing-code "\$pair_code" "\$staging"/,
  );
  assert.doesNotMatch(script, /ttybuild:\/\//);
});

test("support and privacy pages expose release-ready public information", async () => {
  const privacy = await readFile(
    new URL("../public/privacy/index.html", import.meta.url),
    "utf8",
  );
  const support = await readFile(
    new URL("../public/support/index.html", import.meta.url),
    "utf8",
  );

  assert.match(privacy, /end-to-end encrypted/i);
  assert.match(privacy, /does not store terminal content/i);
  assert.match(support, /8-digit code/);
  assert.match(support, /apps\.apple\.com\/us\/app\/tty-build-agents-terminal\/id6792312114/);
  assert.match(support, /mailto:eyhn@yellowplus\.app/);
});
