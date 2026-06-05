# AccDrive

A native **macOS** app that mounts **Autodesk Construction Cloud (ACC) / BIM 360** files
directly in Finder using Apple's FileProvider framework — like *Google Drive for Desktop*,
but for Autodesk. Files appear as on-demand placeholders in a Finder sidebar location and
are downloaded only when opened.

> There is no official Autodesk Desktop Connector for macOS — this fills that gap.

## Features

- Browse your ACC/BIM 360 **Hubs → Projects → Folders → Files** natively in Finder
- **On-demand download**: files are placeholders until opened (real bytes fetched from S3)
- Menu bar app (no Dock icon) for sign in / sign out / open in Finder
- 3-legged OAuth (APS), tokens stored in the Keychain with silent refresh
- Read-only (safe): no accidental edits/deletes pushed back to ACC
- **Mock mode** to try the whole experience with zero Autodesk setup

## Architecture

Two targets in one Xcode project (generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

| Target | Type | Role |
| --- | --- | --- |
| `AccDrive` | Menu bar app (`LSUIElement`) | Authentication + status, registers the FileProvider domain |
| `AccDriveFileProvider` | `NSFileProviderReplicatedExtension` | All Finder integration (enumeration + downloads) |

Shared code (`Shared/`) is compiled into both targets:

- `APSClient` — APS Data Management + OSS API wrapper (async/await, 401 refresh, 429/5xx backoff)
- `APSAuth` / `TokenManager` / `OAuthToken` / `TokenStore` — OAuth + silent refresh, tokens in Keychain
- `KeychainHelper` — generic-password storage, shared via the keychain access group
- `IdentifierStore` — `[NSFileProviderItemIdentifier: APSItemRef]` map in App Group `UserDefaults`
- `APSItemRef` / `APSModels` — domain model + JSON:API decoding
- `MockAPS` — canned data used when `MOCK_MODE` is enabled

No third-party runtime dependencies — only Foundation, FileProvider, AuthenticationServices,
Security, OSLog and SwiftUI.

## Prerequisites

- **macOS 13+** and **full Xcode** (Command Line Tools alone cannot build/sign an app extension)
- **XcodeGen**: `brew install xcodegen`
- An **Apple Developer Team** (required for App Group + Keychain sharing + FileProvider signing).
  A free *Personal Team* does **not** work — it rejects the `fileprovider.testing-mode` and
  App Group capabilities. A paid Apple Developer Program membership is required.
- An **APS app** (see below) — unless you only want to try **mock mode**.

## Setup

```sh
git clone git@github.com:rtrompier/acc-drive.git
cd acc-drive
cp Config.plist.example Config.plist     # then fill in your APS credentials
xcodegen generate
open AccDrive.xcodeproj
```

1. **APS app** — create one at <https://aps.autodesk.com/myapps> (you need a developer hub;
   the free APS plan is enough):
   - Type: **Traditional Web App** (confidential client with secret)
   - Callback URL: **`accdrive://oauth/callback`**
   - APIs: **Data Management API** (+ OSS)
   - Copy the **Client ID** and **Client Secret** into `Config.plist`
2. **Team ID** — set `DEVELOPMENT_TEAM` in `project.yml`, or just pick your team in Xcode
   (target → Signing & Capabilities → *Automatically manage signing*) for **both** targets.
3. Build & run the **AccDrive** scheme. A cloud icon appears in the menu bar.
4. **Enable the extension**: System Settings → *General → Login Items & Extensions →
   File Providers* → turn **AccDrive** on. (macOS disables third-party file providers by
   default — same as Google Drive / OneDrive on first run.)
5. Menu bar ☁️ → **Sign in to Autodesk**. The *Autodesk Construction Cloud* location appears
   in Finder's sidebar.

### Trying it without an Autodesk account (mock mode)

Set `MOCK_MODE` to `true` in `Config.plist`, build & run. The app auto-mounts a demo tree
(hubs → projects → folders → files) with on-demand download, no sign-in or APS app needed.
Great for seeing the Finder integration work end-to-end.

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

> **Using your own Client ID:** this repo ships only placeholders in `Config.plist.example` —
> everyone uses **their own** APS app. Each ACC account you want to access must authorize
> *that* Client ID following the steps above (including the Autodesk email if "Document
> Management" isn't offered).

## How it works

- **Auth**: 3-legged OAuth via `ASWebAuthenticationSession`. The confidential client uses
  HTTP Basic (`client_id:client_secret`) on the token endpoint. Access/refresh tokens + expiry
  live in the Keychain (shared with the extension via the keychain access group) and are
  refreshed silently ~60s before expiry.
- **Enumeration**: `FileProviderEnumerator` calls APS for a container's children, caches each
  child's `APSItemRef` in the shared `IdentifierStore`, and yields `NSFileProviderItem`s.
- **Download**: `fetchContents` resolves the tip version's OSS storage URN, gets a signed S3
  URL via `…/signeds3download`, downloads to a temp file, and hands it to the system.
- **Read-only**: `createItem`/`modifyItem`/`deleteItem` return an unsupported error.

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
| `APS_CLIENT_ID` | Your APS app Client ID |
| `APS_CLIENT_SECRET` | Your APS app Client Secret |
| `APS_REDIRECT_URI` | Must match the app's Callback URL and the `accdrive` URL scheme |
| `MOCK_MODE` | `true` = serve demo data without APS; `false` = real API |

`Config.plist` is **gitignored** (it holds secrets). Commit only `Config.plist.example`.

## Notes / limitations

- **Read-only** drive (no upload/rename/delete back to ACC).
- **Chunked downloads** for very large files (multi-part `signeds3download`) are not handled
  yet — only the single-`url` response.
- **Change tracking**: `enumerateChanges` reports no incremental changes; new content shows up
  on the next full enumeration (sign out/in, or Finder refresh). A real sync-anchor diff is a
  future improvement.
- **Distribution**: a confidential client (with secret) is fine for personal/dev use, but
  embedding one shared secret in a distributed binary is insecure. For real distribution,
  switch the APS app to **Desktop/Mobile (PKCE, no secret)** and adapt `APSAuth`.
- **`topFolders`** uses the correct route `GET /project/v1/hubs/{hubId}/projects/{projectId}/topFolders`.

## License

MIT — see [LICENSE](LICENSE).
