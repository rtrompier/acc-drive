# AccDrive

A native **macOS** app that mounts **Autodesk Construction Cloud (ACC) / BIM 360** files
directly in Finder using Apple's FileProvider framework — like *Google Drive for Desktop*,
but for Autodesk. Files appear as on-demand placeholders in a Finder sidebar location and
are downloaded only when opened.

> There is no official Autodesk Desktop Connector for macOS — this fills that gap.

## Features

- Browse your ACC/BIM 360 **Hubs → Projects → Folders → Files** natively in Finder
- **On-demand download**: files are placeholders until opened (real bytes fetched from S3)
- **Full read/write**: create, rename, move and delete — **files _and_ folders** — pushed back
  to ACC. Editing a file uploads a **new version**.
- **Two-way sync**: changes made in the ACC web UI (add / rename / delete inside a project)
  propagate to Finder automatically (~30 s)
- Menu bar app (no Dock icon): sign in / sign out / open in Finder / refresh
- OAuth (APS) with **PKCE** — no client secret — tokens stored in the Keychain, silent refresh
- **Mock mode** to try the whole experience with zero Autodesk setup

## Architecture

Two targets in one Xcode project (generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

| Target | Type | Role |
| --- | --- | --- |
| `AccDrive` | Menu bar app (`LSUIElement`) | Authentication + status, registers the FileProvider domain |
| `AccDriveFileProvider` | `NSFileProviderReplicatedExtension` | All Finder integration (enumeration, downloads, mutations, change tracking) |

Shared code (`Shared/`) is compiled into both targets:

- `APSClient` — APS Data Management + OSS API wrapper (async/await, 401 refresh, 429/5xx backoff);
  read **and** write (upload, create folder, rename, move, delete, versions)
- `APSAuth` / `TokenManager` / `OAuthToken` / `TokenStore` — OAuth **Authorization Code + PKCE**
  (public client, no secret), silent refresh, tokens in Keychain
- `KeychainHelper` — generic-password storage
- `IdentifierStore` — persistent `[NSFileProviderItemIdentifier: APSItemRef]` map, per-container
  snapshots and a monotonic working-set sync anchor, stored in the **extension's own
  Application Support container**
- `APSItemRef` / `APSModels` — domain model + JSON:API decoding
- `MockAPS` — canned data used when `MOCK_MODE` is enabled

No third-party runtime dependencies — only Foundation, FileProvider, AuthenticationServices,
Security, CryptoKit, OSLog and SwiftUI.

## Using AccDrive

Whichever option you pick, **one thing is always required**: an ACC **account admin must
authorize a Client ID** on the account. A user login alone is *not* enough — Autodesk requires
third-party apps to be approved by the account admin (see
[Authorizing the app](#-authorizing-the-app-on-an-acc--bim-360-account-the-important-part)).

There are two ways to run the app.

> **⚠️ Signing caveat.** The prebuilt binary in Releases is **unsigned**. Gatekeeper blocks it
> on first launch, and on **Apple Silicon** an unsigned FileProvider extension may refuse to
> load. If the drive never shows up in Finder, use **Option 2** (build & sign with your own
> Apple Developer team) — signing the extension yourself is the reliable path.

### Option 1 — Prebuilt app + authorize our Client ID (turnkey)

Nothing to build. Download the app and have your account admin authorize **our** Client ID.

1. Download `AccDrive.app.zip` from the [latest release](https://github.com/rtrompier/acc-drive/releases),
   unzip, and move **AccDrive.app** to `/Applications`.
2. First launch: right-click → **Open** → *Open* (or System Settings → *Privacy & Security* →
   **Open Anyway**) to get past Gatekeeper.
3. Ask your ACC **account admin** to authorize **AccDrive's Client ID** on the account:
   ```
   BJi0IecwujUIBNqdh0qKsTKwYhKjpPEwnjZZSqATfZguyZyo
   ```
   at <https://acc.autodesk.com/> → **Account admin → Settings → Custom Integrations →
   Add a custom integration**, checking **BOTH** *Account Administration* **and** *Document
   Management* (full details + the Autodesk activation email are
   [below](#-authorizing-the-app-on-an-acc--bim-360-account-the-important-part)).
4. [Enable the extension](#enabling-the-extension), then ☁️ → **Sign in to Autodesk**.

### Option 2 — Build with your own Client ID

Full control: your own APS app and your own code signing (also the reliable path on Apple
Silicon, since you sign the extension with your own team).

1. **Create your own APS app** at <https://aps.autodesk.com/myapps> (the free APS plan is enough):
   - Type: **Desktop, Mobile, Single-Page App** — a **public client** using **PKCE**
     (⚠️ *not* "Traditional Web App"; there is **no client secret**)
   - Callback URL: **`accdrive://oauth/callback`**
   - APIs: **Data Management API** (+ OSS)
   - Copy the **Client ID**
2. Build & sign:
   ```sh
   git clone git@github.com:rtrompier/acc-drive.git
   cd acc-drive
   cp Config.plist.example Config.plist      # put YOUR APS_CLIENT_ID in it
   xcodegen generate
   open AccDrive.xcodeproj                     # both targets → pick your team, then build & run
   ```
   Requires **macOS 13+**, **full Xcode** (Command Line Tools alone can't build/sign an app
   extension), **XcodeGen** (`brew install xcodegen`), and a paid **Apple Developer Program**
   team — a free *Personal Team* rejects the required entitlements.
3. Have your ACC **account admin** authorize **your** Client ID on the account (same Custom
   Integration steps as Option 1, [below](#-authorizing-the-app-on-an-acc--bim-360-account-the-important-part)).
4. [Enable the extension](#enabling-the-extension), then ☁️ → **Sign in**.

### Enabling the extension

macOS disables third-party file providers by default (same as Google Drive / OneDrive on first
run): System Settings → *General → Login Items & Extensions → File Providers* → turn
**AccDrive** on. A cloud icon (☁️) sits in the menu bar for sign in / out / refresh; after
signing in, the *Autodesk Construction Cloud* location appears in Finder's sidebar.

### Trying it without an Autodesk account (mock mode)

Building from source (Option 2)? Set `MOCK_MODE` to `true` in `Config.plist`, build & run. The
app auto-mounts a demo tree (hubs → projects → folders → files) with on-demand download, no
sign-in or APS app needed — great for seeing the Finder integration work end-to-end.

## ⚠️ Authorizing the app on an ACC / BIM 360 account (the important part)

A valid user login is **not enough**. For **enterprise** ACC/BIM 360 hubs, Autodesk requires
the **account admin** to authorize your app's Client ID. Without it, `GET /project/v1/hubs`
returns `200` with empty `data` and a `meta.warnings` entry:

```
403 BIM360DM_ERROR — "You don't have permission to access this API"
```

This is by design (the human can browse files in the browser, but a third-party *app* getting
programmatic access to a company's construction data must be approved by the account admin).
The same applies to any ACC integration (oDrive, etc.).

**To authorize the app on an account:**

1. An **account admin** goes to **Account Admin → Settings → Custom Integrations** (via
   <https://admin.b360.autodesk.com/> for the account), **Add Custom Integration**.
2. On *Select Access*, check **BOTH** **"BIM 360 Account Administration"** **and**
   **"Document Management"**. Account-Administration-only is **not** enough — *Document
   Management* is what grants file/Data-Management access.
3. Enter the **APS Client ID** and an app name, finish the wizard.
4. In the app: **Sign out → Sign in** (this clears the FileProvider cache so a fresh
   enumeration runs with the new authorization).

### If "Document Management" is missing from *Select Access*

On some accounts (e.g. newer ACC / Autodesk Build / trial accounts) the *Select Access* step
only offers **"BIM 360 Account Administration"** — **"Document Management" is absent**. This
means the account's **Docs API has not been activated** for custom integrations.

Email Autodesk to activate it (this is the documented fix, ref. ACSAPI-319):

- **To:** `bim360appsactivations@autodesk.com`
- **Subject:** `ACC Docs – API Activation Request` (or `BIM 360 Docs – API Activation Request`)
- **Body:** your **Account / Hub ID**, the **APS Client ID**, and a request to activate
  Document Management / Data Management API access for custom integrations.

Once Autodesk activates it (a few business days), "Document Management" appears in the wizard;
check it, then Sign out → Sign in.

See: [Missing "BIM 360 Docs" option in "Add Custom Integration" dialog](https://fieldofviewblog.wordpress.com/2023/04/13/missing-bim-360-docs-option-in-add-custom-integration-dialog/)
and [Manage API Access to BIM 360 Docs (APS docs)](https://aps.autodesk.com/en/docs/bim360/v1/tutorials/getting-started/manage-access-to-docs/).

> **Which Client ID?** With **Option 1** you authorize AccDrive's shared Client ID
> (`BJi0IecwujUIBNqdh0qKsTKwYhKjpPEwnjZZSqATfZguyZyo`); with **Option 2** you authorize your
> own. Either way the Client ID is a public identifier (safe to distribute — PKCE means there
> is no secret), and **each** ACC account you want to access must authorize *that* Client ID
> following the steps above (including the Autodesk email if "Document Management" isn't offered).

## How it works

- **Auth**: OAuth **Authorization Code grant with PKCE** via `ASWebAuthenticationSession`. No
  client secret — a per-flow `code_verifier`/`code_challenge` (S256) is generated, and the
  `client_id` is sent in the token request body. Access/refresh tokens + expiry live in the
  Keychain and are refreshed silently. Sign-in uses an **ephemeral** web session so you can pick
  which Autodesk account to use.
- **Enumeration**: `FileProviderEnumerator` calls APS for a container's children, caches each
  child's `APSItemRef` in the `IdentifierStore`, and yields `NSFileProviderItem`s.
- **Download**: `fetchContents` resolves the tip version's OSS storage URN, gets a signed S3
  URL via `…/signeds3download`, downloads to a temp file, and hands it to the system.
- **Write**: `createItem` uploads a file (create storage → signed-S3 upload → items POST) or
  creates a folder; `modifyItem` uploads a new version on edit, renames (also a new version for
  files), and moves (reparent); `deleteItem` tombstones a file version / hides a folder. Delete
  is **idempotent** (already-gone on the server counts as success).
- **Change tracking**: the **working-set** enumerator lists every known item (so the system
  honours `didDeleteItems`); `enumerateChanges` diffs each browsed project/folder against its
  last snapshot and reports `didUpdate` / `didDeleteItems` with a **monotonic** sync anchor. The
  menu bar app nudges the working set every 30 s. Account-level changes (a **new project**, a
  **renamed account/hub**) surface only after a **sign out / sign in** (a full re-enumeration).

### Where are the files stored locally?

This is a *replicated* FileProvider, so macOS (not the app) manages on-disk storage:

- **What you see** in Finder: `~/Library/CloudStorage/AccDrive-AutodeskConstructionCloud/`
  — virtual placeholders.
- **Materialized bytes** (after opening a file): managed by `fileproviderd` under
  `~/Library/Application Support/FileProvider/<domain-UUID>/`. macOS may evict them
  automatically to reclaim space (on-demand).

## Configuration (`Config.plist`)

| Key | Description |
| --- | --- |
| `APS_CLIENT_ID` | Your APS app Client ID (public identifier — PKCE, no secret) |
| `APS_REDIRECT_URI` | Must match the app's Callback URL and the `accdrive` URL scheme |
| `MOCK_MODE` | `true` = serve demo data without APS; `false` = real API |

`Config.plist` is **gitignored**; commit only `Config.plist.example`. There is **no client
secret** — auth uses PKCE, so nothing sensitive is shipped in the binary.

## Notes / limitations

- **Distribution**: the released binary is **unsigned** and ships AccDrive's shared (public,
  PKCE) Client ID. Gatekeeper blocks it on first launch, and on Apple Silicon the FileProvider
  extension may not load unsigned — building & signing with your own team (Option 2) is the
  reliable path. See [Using AccDrive](#using-accdrive).
- **Account-level changes** (a new project, a new hub, or an account/hub rename) surface only
  after **sign out / sign in**, not via the live 30 s sync (tracking the hub/root level jams the
  system's create-item queue, so it is deliberately excluded).
- **Chunked downloads** for very large files (multi-part `signeds3download`) are not handled yet
  — only the single-`url` response.

## License

MIT — see [LICENSE](LICENSE).
