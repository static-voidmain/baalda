# Baalda on iPhone and iPad

The Apple mobile target shares the desktop editor, Rust vault storage, and Baalda team sync. It stores the active vault in the app sandbox. Vault settings → Import and export → Cloud vault sync connects a separate cloud copy.

## Download and install

Open the **Apple mobile app** run on the repository's Actions tab and download its artifact. The simulator artifact contains a ZIP preserving the app bundle. Extract it and run `xcrun simctl install booted /path/to/Baalda.app` on an Apple Silicon Mac with a running iPhone or iPad simulator.

The default run also produces a device IPA under **Baalda-iPhone-iPad-unsigned** for local signing. iPhone and iPad require a valid signature and provisioning profile to install it.

For registered devices, configure the repository variable `APPLE_DEVELOPMENT_TEAM` and secrets `IOS_CERTIFICATE` (base64 P12 with private key), `IOS_CERTIFICATE_PASSWORD`, and `IOS_MOBILE_PROVISION` (base64 ad hoc profile for `com.baalda.context` including the devices). Select **Build a signed IPA for registered devices** on manual dispatch. Install the IPA using Apple Configurator on a paired Mac. GitHub offers manual dispatch once the workflow is on the default branch. The workflow uploads artifacts and does not publish to the App Store.

For local builds, install the workspace dependencies in `app/`, enable the iOS platform in Xcode, add the Rust targets `aarch64-apple-ios` and `aarch64-apple-ios-sim`, and run `pnpm exec tauri ios build --target aarch64` from `app/apps/desktop`. An Xcode signing identity and provisioning profile are required for a device build.

## Connect cloud storage

- **iCloud Drive** — choose **iCloud Drive / Files**, choose an iCloud Drive folder, then tap **Sync now**. The app remembers the folder on that device. Reselect it if access is revoked.
- **Google Drive** — enable the Drive API for a Google Cloud project and create an iOS OAuth client for the app's bundle identifier. Set the repository variable `GOOGLE_IOS_CLIENT_ID` before building. For a local build, set the same environment variable and run `python3 scripts/configure-ios-google.py` from the repository root. Select **Google Drive**, connect the account, then tap **Sync now**. The app requests the per-file `drive.file` scope and creates its own folder in My Drive. Reconnect after token expiry or an app restart. If the OAuth consent screen is in testing, add the Google account as a test user.
- **Team vaults** — sign in to the vault as an owner or admin. Each sync requests the caller's current access board and readable blob listing. Private entries are excluded, and view-only entries cannot import cloud edits. A provider folder has independent sharing. Copies already exported can remain accessible after a Baalda membership or grant is revoked.

Each run processes indexed notes and tree files present on this device. Embedded attachments are exported under their content-addressed paths. Local metadata under `.context/` stays in the app. If both copies of a file changed, the run counts a conflict and preserves both. Cloud edits to an existing linked file can flow back to Baalda. Cloud-only new files, external renames, and deletion propagation are not supported. Sync is user-triggered while the app is open.
