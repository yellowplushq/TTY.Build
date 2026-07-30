# Pedals development and release guide

This is the repository-level operating guide for agents and maintainers. Run
commands from the repository root unless a section explicitly changes
directories. Prefer the checked-in scripts over ad-hoc equivalents because the
scripts include the production safety checks that this project relies on.

## Non-negotiable project invariants

| Item | Canonical value |
|---|---|
| Product and on-device name | `Pedals` |
| App Store Connect name | `Pedals - Remote Terminal` |
| App Store Connect app ID | `6792312114` |
| Apple team ID | `QDJ93ZUQ9B` |
| iOS app | `air.build.pedals` |
| iOS widget and Live Activity | `air.build.pedals.widgets` |
| watchOS app | `air.build.pedals.watchapp` |
| watchOS widgets | `air.build.pedals.watchapp.widgets` |
| macOS menu bar app | `air.build.pedals.menubar` |
| App Group | `group.air.build.pedals` |
| Production service | `https://pedals.air.build` |
| Cloudflare D1 database | `pedals` |
| Internal TestFlight group | `a3f73f1d-e7a5-47d8-9b57-8ada4baad549` |
| External TestFlight group | Create after the first valid build |

- Do not add compatibility with protocol v1, the former Node relay, or the
  retired identifier namespace. There is one server implementation:
  `relay/src/worker.mjs` on Cloudflare Workers.
- The generated `.xcodeproj` files are ignored. Edit `ios/project.yml` or
  `desktop/PedalsMenubar/project.yml`, then regenerate with XcodeGen.
- The server-authoritative value is the number of alive TTYs across computers
  bound to a client. Do not infer this total independently in widgets.
- Terminal bytes, terminal titles, working directories, and the pairing E2EE
  secret must not be stored by the Worker. D1 stores identities, binding state,
  current counts, and push endpoint state only.
- Keep the UI and all widgets minimal and black/white. Use color only for a
  semantic state that cannot be communicated clearly without it.
- Never commit `.p8`, `.mobileprovision`, `.ipa`, `.xcarchive`, `.dev.vars`,
  Wrangler state, build output, or anything below `.artifacts/`.

Before handing off a migration or release, this audit must return no matches:

```bash
rg -n -uu --hidden \
  --glob '!.git/**' \
  --glob '!node_modules/**' \
  --glob '!AGENTS.md' \
  'in\.eyhn\.pedals|group\.in\.eyhn\.pedals|app\.yellowplus\.pedals|group\.app\.yellowplus\.pedals|pedals\.(eyhn\.in|yellowplus\.app)|5RWWZ7DDG9|6792224057|Pedals TTY|PEDALS-20260718' .
```

## Toolchain

The supported development host is macOS with:

- Xcode 26.x and iOS/watchOS 26.x simulators
- Swift 6
- XcodeGen
- Node.js 22 or newer and npm
- Wrangler 4.x, authenticated to the YellowPlus Cloudflare account for `air.build`
- `asc` 3.x, authenticated to the `YellowPlus, Inc.` App Store Connect account
- Baguette for headless simulator inspection and screenshots

Useful authentication checks are read-only:

```bash
npx wrangler whoami
asc auth status
asc web auth status
```

Apple public APIs do not expose App Group registration or Bundle ID-to-group
assignment. Those two operations must be checked in Apple Developer Portal.
Do not assume that enabling the `APP_GROUPS` capability proves assignment.

## Repository map

- `relay/`: Cloudflare Worker, Durable Objects, D1 migrations, APNs provider,
  and service tests.
- `shared/PedalsKit/`: v2 frame codec, pairing invitation, E2EE, and shared
  service API types.
- `desktop/PedalsDaemon/`: macOS daemon and `pedals` command-line client. The
  `pedals` CLI is for internal debugging only — never ship it in external
  releases; the menu bar app is the only released desktop frontend.
- `desktop/PedalsMenubar/`: macOS menu bar UI.
- `ios/`: iPhone app, iPhone widgets, Live Activity/Dynamic Island, Watch app,
  Watch widgets, shared status code, entitlements, and XcodeGen project source.
- `scripts/e2e.sh`: isolated local Worker-to-daemon-to-iOS end-to-end test.
- `scripts/deploy-relay.sh`: canonical production Worker deployment.
- `docs/PROTOCOL.md` and `relay/README.md`: protocol and service behavior.

## Fast validation

Run these before changing release state:

```bash
cd relay
npm ci
npm test
cd ../shared/PedalsKit
swift test
cd ../../desktop/PedalsDaemon
swift test
```

The expected suites currently contain 24 Node tests, 50 Worker tests, 86
PedalsKit tests, and 41 daemon tests. A changed count is not automatically a
failure, but every discovered test must pass.

Check the deployed v2 contract separately; it creates temporary identities and
removes its test computer during cleanup:

```bash
cd relay
npm run test:contract
```

## Local Worker debugging

Install dependencies, migrate an isolated local D1 database, and start the
Worker:

```bash
cd relay
npm ci
npm run db:migrate:local
npm run dev
```

The default local origin is `http://127.0.0.1:8787`. Basic checks:

```bash
curl -i http://127.0.0.1:8787/healthz
RELAY_HTTP_URL=http://127.0.0.1:8787 npm run test:contract
```

Unit and Worker tests inject their own APNs test credentials. A real APNs key is
not needed for ordinary local tests. If a device-level push test genuinely
requires one, keep it only in an ignored `relay/.dev.vars` file and remove it
afterward. Never print the private key or a device token.

Wrangler needs permission to bind localhost and write its normal log/cache
directories. An `EPERM` for `127.0.0.1` or the Wrangler log directory is an
execution-sandbox problem, not a test failure; rerun the same command with the
required host permissions.

## Desktop debugging

Run daemon tests and build the executable:

```bash
swift test --package-path desktop/PedalsDaemon
swift build --package-path desktop/PedalsDaemon
```

Start the daemon against a local Worker:

```bash
swift run --package-path desktop/PedalsDaemon pedals serve \
  --service http://127.0.0.1:8787
```

In another shell, use the same built package to inspect the control path:

```bash
swift run --package-path desktop/PedalsDaemon pedals status
swift run --package-path desktop/PedalsDaemon pedals pair
swift run --package-path desktop/PedalsDaemon pedals new
swift run --package-path desktop/PedalsDaemon pedals ls
swift run --package-path desktop/PedalsDaemon pedals kill SESSION_ID
```

Use an isolated `PEDALS_HOME` below `/tmp` when testing identity reset or
pairing. Never point destructive reset tests at a user's normal daemon state.

Generate and build the menu bar app:

```bash
cd desktop/PedalsMenubar
xcodegen generate
xcodebuild \
  -project PedalsMenubar.xcodeproj \
  -scheme PedalsMenubar \
  -configuration Debug \
  build
```

## iPhone, widgets, Live Activity, and Watch debugging

`ios/project.yml` is the source of truth. Regenerate before every Xcode build
after project, entitlement, asset, target, or dependency changes:

```bash
cd ios
xcodegen generate
cd ..
```

List schemes and available simulators:

```bash
xcodebuild -project ios/Pedals.xcodeproj -list
baguette list --json
xcrun simctl list pairs
```

Choose an available iPhone simulator UDID and run the unit tests:

```bash
PEDALS_IOS_UDID=REPLACE_WITH_UDID
baguette boot --udid "$PEDALS_IOS_UDID"
xcodebuild \
  -project ios/Pedals.xcodeproj \
  -scheme Pedals \
  -destination "platform=iOS Simulator,id=$PEDALS_IOS_UDID" \
  -derivedDataPath .artifacts/dd-ios-tests \
  test
```

Build, install, and launch the iPhone app:

```bash
xcodebuild \
  -project ios/Pedals.xcodeproj \
  -scheme Pedals \
  -destination "platform=iOS Simulator,id=$PEDALS_IOS_UDID" \
  -derivedDataPath .artifacts/dd-ios \
  build
baguette install \
  --udid "$PEDALS_IOS_UDID" \
  .artifacts/dd-ios/Build/Products/Debug-iphonesimulator/Pedals.app
xcrun simctl launch "$PEDALS_IOS_UDID" air.build.pedals
```

For Watch testing, use a Watch simulator already paired to the selected iPhone,
boot both devices, and build the `PedalsWatch` scheme for the Watch UDID:

```bash
PEDALS_WATCH_UDID=REPLACE_WITH_PAIRED_WATCH_UDID
baguette boot --udid "$PEDALS_WATCH_UDID"
xcodebuild \
  -project ios/Pedals.xcodeproj \
  -scheme PedalsWatch \
  -destination "platform=watchOS Simulator,id=$PEDALS_WATCH_UDID" \
  -derivedDataPath .artifacts/dd-watch \
  build
baguette install \
  --udid "$PEDALS_WATCH_UDID" \
  .artifacts/dd-watch/Build/Products/Debug-watchsimulator/PedalsWatch.app
xcrun simctl launch "$PEDALS_WATCH_UDID" air.build.pedals.watchapp
```

Use Baguette for repeatable visual evidence and accessibility inspection:

```bash
baguette screenshot \
  --udid "$PEDALS_IOS_UDID" \
  --output .artifacts/ios-smoke.jpg
baguette describe-ui \
  --udid "$PEDALS_IOS_UDID" \
  --output .artifacts/ios-smoke-ui.json
baguette logs \
  --udid "$PEDALS_IOS_UDID" \
  --bundle-id air.build.pedals \
  --level debug
```

Visual smoke testing must cover:

- paired and unpaired iPhone states;
- one and multiple terminal sessions;
- black and white appearance in light and dark system modes;
- iPhone `systemSmall`, `systemMedium`, circular, rectangular, and inline
  widget families;
- Lock Screen Live Activity and Dynamic Island expanded, compact, and minimal
  presentations;
- Watch app plus circular, corner, rectangular, and inline complications;
- counts changing `0 -> 1 -> N -> 0`, an offline computer, and stale cached
  state.

Baguette screenshots are evidence, not a replacement for XCTest, signed archive
validation, or the service contract.

## Full local end-to-end test

The preferred integration test creates isolated temporary daemon and D1 state,
starts a local Worker, registers and binds a client, verifies TTY aggregation,
pairs the simulator by driving the pairing UI (typing the eight-digit code),
proves the encrypted relay handshake, and saves a screenshot:

```bash
SIM_DEVICE='iPhone 17 Pro' ./scripts/e2e.sh
```

It writes diagnostics below `.artifacts/` and removes its temporary `/tmp`
state on exit. If the chosen simulator name does not exist, select one returned
by `baguette list --json`.

## APNs and status debugging

Production must contain exactly these secret names; listing names does not
reveal their values:

```bash
cd relay
npx wrangler secret list --config wrangler.jsonc
```

Required names:

- `APNS_PRIVATE_KEY_P8`
- `APNS_KEY_ID`
- `APNS_TEAM_ID`

Fixed APNs topics are part of the security boundary:

| Surface | Topic |
|---|---|
| iPhone widget | `air.build.pedals.push-type.widgets` |
| Watch widget | `air.build.pedals.watchapp.push-type.widgets` |
| Live Activity start/update/end | `air.build.pedals.push-type.liveactivity` |

The client must never supply an APNs topic, push type, arbitrary header, or
arbitrary payload. Debug builds register sandbox tokens; Release builds register
production tokens. Treat `BadDeviceToken`, `DeviceTokenNotForTopic`, and
`Unregistered` as endpoint invalidation, not as a reason to retry forever.

To configure a new team-wide APNs `.p8` after explicit authorization:

```bash
node scripts/configure-relay-apns.mjs \
  --p8 /ABSOLUTE/PATH/AuthKey_KEY_ID.p8 \
  --key-id KEY_ID \
  --team-id QDJ93ZUQ9B
```

The helper writes only Wrangler secrets and verifies their names. The `.p8`
must remain outside the repository.

## Production Worker release

Publishing changes remote state. Do it only when the user explicitly asks for
a deployment.

The canonical release command is:

```bash
./scripts/deploy-relay.sh
```

The script performs all of the following:

1. `npm ci` and the complete Relay/Worker test suite.
2. Presence checks for all three APNs secret names.
3. Remote D1 migrations.
4. `wrangler deploy` to the custom domain.
5. Verification that `/healthz` serves the exact immutable Worker version on
   three consecutive requests.
6. The public v2 production contract.
7. Recording the URL and version under `.artifacts/`.

Post-deploy checks:

```bash
cd relay
npx wrangler deployments list --config wrangler.jsonc
npx wrangler d1 migrations list pedals --remote --config wrangler.jsonc
npm run test:contract
curl -i https://pedals.air.build/healthz
```

If the production contract fails after a deploy, inspect the immutable version
IDs before rolling back. A rollback is a production mutation and also requires
authorization:

```bash
cd relay
npx wrangler deployments list --config wrangler.jsonc
npx wrangler rollback VERSION_ID \
  --config wrangler.jsonc \
  --message 'Rollback failed Pedals deployment'
```

## Apple signing configuration

Release builds use manual signing. These profile names are referenced by
`ios/project.yml` and must match App Store Connect exactly:

| Bundle ID | Profile name |
|---|---|
| `air.build.pedals` | `Pedals YellowPlus App Store` |
| `air.build.pedals.widgets` | `Pedals Widgets YellowPlus App Store` |
| `air.build.pedals.watchapp` | `Pedals Watch YellowPlus App Store` |
| `air.build.pedals.watchapp.widgets` | `Pedals Watch Widgets YellowPlus App Store` |

Before archiving:

```bash
security find-identity -v -p codesigning
asc certificates list --output table
asc profiles list --output table
```

Every profile must contain its exact application identifier,
`group.air.build.pedals`, `beta-reports-active=true`, and the production APNs
entitlement where applicable. Do not recreate profiles merely because Xcode
cannot see them; first download and install the existing active profiles. If
profiles have actually expired, recreate all four against one active iOS
distribution certificate, then update the stable profile names above.

## TestFlight release

Uploading or distributing a build changes App Store Connect. Do it only after
an explicit release request.

### 1. Choose and apply the version

Inspect existing builds and choose a build number that has never been uploaded:

```bash
asc builds list --app 6792312114 --output table
```

Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` for the app and all
three embedded products in `ios/project.yml`. Their versions must match. Then:

```bash
cd ios
xcodegen generate
cd ..
git diff --check
```

### 2. Run the release gate

Run the fast validation, the full iOS tests, `./scripts/e2e.sh`, and the legacy
identifier audit from this guide. Also confirm:

```bash
asc apps view --id 6792312114 --output table
asc testflight groups list --app 6792312114 --output table
```

The app record must resolve to bundle ID `air.build.pedals`. Do not upload an IPA
created for another App Store Connect record.

### 3. Create ExportOptions.plist

Create an ignored release directory below `.artifacts/` and put an
`ExportOptions.plist` there. Use `method=app-store-connect`, `destination=export`,
team `QDJ93ZUQ9B`, manual signing, and this exact profile mapping:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key><string>export</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>method</key><string>app-store-connect</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>air.build.pedals</key><string>Pedals YellowPlus App Store</string>
    <key>air.build.pedals.widgets</key><string>Pedals Widgets YellowPlus App Store</string>
    <key>air.build.pedals.watchapp</key><string>Pedals Watch YellowPlus App Store</string>
    <key>air.build.pedals.watchapp.widgets</key><string>Pedals Watch Widgets YellowPlus App Store</string>
  </dict>
  <key>signingCertificate</key><string>iPhone Distribution</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>QDJ93ZUQ9B</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
```

Validate it before use:

```bash
plutil -lint .artifacts/testflight-release/ExportOptions.plist
```

If more than one distribution identity is installed, replace the generic
`signingCertificate` value in the ignored plist with the intended identity's
SHA-1 from `security find-identity`; never guess.

### 4. Archive and export

```bash
xcodebuild \
  -project ios/Pedals.xcodeproj \
  -scheme Pedals \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath .artifacts/testflight-release/Pedals.xcarchive \
  archive

asc xcode export \
  --archive-path .artifacts/testflight-release/Pedals.xcarchive \
  --export-options .artifacts/testflight-release/ExportOptions.plist \
  --ipa-path .artifacts/testflight-release/Pedals.ipa \
  --timeout 20m \
  --output json \
  --pretty
```

Never reuse an old archive or IPA. Delete or move aside the intended output
directory before starting a new build only after resolving the exact path and
ensuring it contains no user-owned evidence.

### 5. Verify the signed archive

Verify all four bundles, not just the containing app:

```bash
codesign --verify --strict --verbose=4 \
  .artifacts/testflight-release/Pedals.xcarchive/Products/Applications/Pedals.app
codesign --verify --strict --verbose=4 \
  .artifacts/testflight-release/Pedals.xcarchive/Products/Applications/Pedals.app/PlugIns/PedalsWidgets.appex
codesign --verify --strict --verbose=4 \
  .artifacts/testflight-release/Pedals.xcarchive/Products/Applications/Pedals.app/Watch/PedalsWatch.app
codesign --verify --strict --verbose=4 \
  .artifacts/testflight-release/Pedals.xcarchive/Products/Applications/Pedals.app/Watch/PedalsWatch.app/PlugIns/PedalsWatchWidgets.appex
```

Use `codesign -d --entitlements - BUNDLE_PATH` and
`security cms -D -i BUNDLE_PATH/embedded.mobileprovision` to confirm the exact
application identifier, App Group, production APNs environment, and profile
name. Do not print full provisioning profiles into issue comments or logs.

### 6. Upload to internal TestFlight

Set task-specific release values from `ios/project.yml` and the unused build
number selected in step 1:

```bash
PEDALS_RELEASE_VERSION=REPLACE_WITH_VERSION
PEDALS_RELEASE_BUILD=REPLACE_WITH_BUILD_NUMBER
```

Then upload, wait for processing, write What to Test, distribute internally,
and enable tester notification:

```bash
asc publish testflight \
  --app 6792312114 \
  --ipa .artifacts/testflight-release/Pedals.ipa \
  --version "$PEDALS_RELEASE_VERSION" \
  --build-number "$PEDALS_RELEASE_BUILD" \
  --group a3f73f1d-e7a5-47d8-9b57-8ada4baad549 \
  --test-notes 'Connect a computer and verify TTY count synchronization across Pedals, iPhone widgets, Live Activity and Dynamic Island, and Apple Watch widgets, including background APNs updates.' \
  --locale en-US \
  --wait \
  --timeout 45m \
  --poll-interval 30s \
  --notify \
  --output json \
  --pretty
```

Success requires `processingState=VALID` and the build linked to the internal
group. A successful upload alone is not a successful release.

### 7. External TestFlight

External distribution requires Apple Beta App Review. Only submit externally
when the user requested it and the Beta description, feedback email, review
contact, and review notes are already present in App Store Connect. Keep review
contact PII in App Store Connect, not in this repository.

After the build is `VALID`, create an external group if one does not exist, set
its identifier, and distribute the existing build ID:

```bash
PEDALS_EXTERNAL_GROUP_ID=REPLACE_WITH_EXTERNAL_GROUP_ID
asc publish testflight \
  --app 6792312114 \
  --build BUILD_ID \
  --group "$PEDALS_EXTERNAL_GROUP_ID" \
  --wait \
  --notify \
  --submit \
  --confirm \
  --output json \
  --pretty
```

Apple sends invitations only when the external build becomes installable after
Beta Review. Check existing tester records before adding anyone so duplicate
records are not created.

### 8. Verify App Store Connect state

```bash
asc builds info \
  --app 6792312114 \
  --build-number "$PEDALS_RELEASE_BUILD" \
  --version "$PEDALS_RELEASE_VERSION" \
  --platform IOS \
  --output json \
  --pretty
asc testflight testers list --app 6792312114 --output table
asc testflight review submissions list --build-id BUILD_ID --output table
```

Internal availability is complete when the build is `VALID` and linked to the
internal group. External availability remains pending while Apple reports
`WAITING_FOR_REVIEW` or `IN_REVIEW`; do not repeatedly resubmit it.

## Release handoff checklist

A release handoff should state:

- the deployed Worker version ID and `https://pedals.air.build` contract result;
- whether remote D1 has pending migrations;
- that all three APNs secret names exist, without revealing values;
- marketing version, build number, TestFlight build ID, and processing state;
- internal and external group linkage and Beta Review state;
- XCTest, Swift, Worker, and E2E results;
- archive signature/profile verification for all four embedded products;
- any Apple-maintained historical record that cannot be hard-deleted.

Do not claim external TestFlight invitation delivery while Beta Review is still
pending, and do not claim a production release solely because archive/export
succeeded.
