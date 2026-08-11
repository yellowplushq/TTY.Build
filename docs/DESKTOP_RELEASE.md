# Desktop release

TTY.Build desktop releases are universal, notarized macOS disk images. The menu
bar app links `TTYBuildDaemonCore` directly and is itself the long-running PTY and
relay service process; it does not launch or embed a second daemon executable.

## GitHub configuration

The `Release desktop app` workflow needs Actions to have read/write repository
permissions and these repository secrets:

| Secret | Value |
|---|---|
| `MACOS_DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key (`.p12`) |
| `MACOS_DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Password used when exporting that `.p12` |
| `APPLE_API_KEY_P8_BASE64` | Base64-encoded App Store Connect API private key (`.p8`) with notarization access |
| `APPLE_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect API issuer ID |
| `SPARKLE_EDDSA_PRIVATE_KEY` | Private Ed25519 key exported by Sparkle's `generate_keys` tool |

Never add the source `.p12`, `.p8`, or Sparkle private key files to the
repository. The matching Sparkle public key is pinned in the desktop app's
Info.plist.

## Publish a release

Create and push a three-part version tag:

```bash
git tag desktop-v1.0.0
git push origin desktop-v1.0.0
```

The workflow tests the shared desktop service core, builds the app for both
`arm64` and `x86_64`, signs it with hardened runtime, creates a DMG, submits it
to Apple's notary service, staples the ticket, and publishes these GitHub
release assets:

- `TTYBuild-macOS.dmg`
- `TTYBuild-macOS.dmg.sha256`
- `TTYBuild-macOS.zip`
- `TTYBuild-macOS.zip.sha256`
- `ttybuild-cli-macOS.zip`
- `ttybuild-cli-macOS.zip.sha256`
- `appcast.xml`

The CLI archive carries the universal `ttybuild` and `ttybuild-hook`
binaries, built by `scripts/build-cli-release.sh`, stamped with the release
version (`ttybuild --version`), Developer ID signed with the stable
identifiers `build.tty.cli.ttybuild` / `build.tty.cli.ttybuild-hook`, and
notarized. The same identifiers are applied to the copies embedded in the
app bundle — macOS TCC grants follow the signing identity, and the
app-embedded and curl-installed CLI must be the same subject. The website's
`/download/cli.zip` and `/download/cli.zip.sha256` routes redirect to these
assets on the latest release.

The zip is packaged after the signed update feed is generated so Sparkle only
ever sees the DMG; the app inside the zip carries the stapled notarization
ticket as well.

The website's `/download/macos` route redirects to the DMG on the latest
GitHub release, while `/download/macos.zip` and `/download/macos.zip.sha256`
redirect to the zip archive and its checksum. Set the Worker's
`DESKTOP_RELEASE_REPOSITORY` variable to the repository slug, for example
`owner/ttybuild`, before deploying the website. The stable `/appcast.xml` route
redirects to the signed feed from the same release. TTY.Build checks it on launch
and every 24 hours, and users can also run `Check for Updates…` from the menu
or Settings. Both the feed and the update archive are verified with the app's
pinned Ed25519 public key before an update is installed.

## Self-install on launch

A release build launched from anywhere outside an Applications folder
(Downloads, the Desktop, a mounted DMG) moves itself to `/Applications`
(falling back to `~/Applications` without write access), relaunches from the
new location, and removes the original — resolving App Translocation to find
the real source, and skipping when another instance already runs from the
destination. Extended attributes survive the move, so a pairing-stamped
download still pairs after relocating. Debug builds and
`TTYBUILD_NO_RELOCATE=1` skip the behavior.

## Curl installation

The website serves `relay/public/install.sh` at `/install.sh` and at the
short alias `/i`, so users can install or reinstall TTY.Build with one
command:

```bash
curl -fsSL https://tty.build/i | bash
```

The script first asks what to install (via `/dev/tty`, so the prompt works
under `curl | bash`): the **app** (recommended; the default with no
terminal to answer) or the **ttybuild CLI** — for headless Macs, or for
giving agents access to TTY.Build. `--app` / `--cli` and
`TTYBUILD_INSTALL=app|cli` skip the prompt. The CLI path downloads
`ttybuild-cli-macOS.zip` through the stable redirect, verifies its
checksum, installs both binaries to `~/.tty.build/bin`, symlinks
`ttybuild` into `/usr/local/bin` (or `~/.local/bin` without write access),
and prints the `serve` / `pair` / `attach` next steps. It never uses sudo.

The iPhone app's pairing screen embeds its enrollment code into the URL of
the copied command (`curl -fsSL https://tty.build/12345678 | bash`) —
the service serves `install.sh` with that code baked in as the `TTYBUILD_PAIR`
default; `--pair 12345678` and the `TTYBUILD_PAIR` environment variable are
the manual equivalents. After extracting, the script stamps the code as an
extended attribute on the installed bundle; the app consumes the stamp on
launch, claims the code, and the computer then appears on the iPhone for a
one-tap confirmation (PROTOCOL.md §2, "Reverse pairing").

`GET /download/<code>/macos.zip` serves the release archive with the same
stamp already injected as a sequestered-xattr (`__MACOSX/._TTYBuild.app`)
entry — the signed app bytes pass through untouched, so Gatekeeper
verification is unaffected. An archive downloaded that way (or AirDropped
onward) pairs on first launch with zero typing.

The script downloads `TTYBuild-macOS.zip` through the stable redirect, verifies
it against the release's SHA-256 checksum before installing anything, copies
`TTYBuild.app` into `/Applications` (falling back to `~/Applications` without
ever using sudo), and launches it. Interactive terminals get a brief
Matrix-style intro (skipped when output is not a TTY, `TERM=dumb`, or
`NO_COLOR` is set), and when an existing install is detected the script shows
its version and offers to update or quit, reading the answer from `/dev/tty`
so the prompt still works through `curl | bash`. Keep the script short,
auditable, and compatible with the bash 3.2 that ships with macOS; it is part
of the trust boundary of the release.

## Build locally

Local builds are unsigned. Xcode 26, Swift 6, and XcodeGen are required:

```bash
TTYBUILD_DESKTOP_VERSION=1.0.0 \
TTYBUILD_DESKTOP_BUILD_NUMBER=1 \
./scripts/build-desktop-release.sh

./scripts/package-desktop-dmg.sh
./scripts/package-desktop-zip.sh
```

Outputs are written below `.artifacts/desktop-release/` and must not be
committed.
