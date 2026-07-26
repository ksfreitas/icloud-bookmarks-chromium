# iCloud Bookmarks sync fix for unbranded Chromium

Makes Apple's **iCloud Bookmarks** extension sync correctly on Chromium builds that
don't carry Google's official branding - most notably [ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium),
but this applies to any unbranded/self-built Chromium.

Unofficial, community-made fix. Not affiliated with or endorsed by Apple Inc.

## The problem

iCloud for Windows only "sees" a handful of specific Chromium-based browsers
(Google Chrome, Microsoft Edge, Brave, ...). It identifies them in two independent
places, and both checks fail on an unbranded build:

1. **Sync itself is refused.** The extension's background service worker reports
   the browser's brand list (`navigator.userAgentData.brands`) to the native
   `iCloudChrome.exe` host over Native Messaging. On an unbranded build this list
   only contains `"Chromium"` - there is no `"Google Chrome"` entry - so the host
   logs:

   ```
   ERROR  ZhromeMainWindow::InitializeSyncingFromBrands  Unknown browser. Not initializing syncing.
   ```

   and refuses to sync anything, even though the extension is installed correctly
   and Native Messaging is wired up fine.

2. **The iCloud app shows the browser as "not detected".** Independently of sync,
   the iCloud app's settings UI checks whether a supported browser is installed by
   reading a hardcoded path:

   ```
   %LOCALAPPDATA%\Google\Chrome\User Data\Local State
   ```

   Unbranded builds live somewhere else entirely (e.g.
   `%LOCALAPPDATA%\Chromium\User Data`), so this file is never found:

   ```
   ERROR  GetChromiumBrowserLastUsedProfileDir  Failed to read Local State file '...\Google\Chrome\User Data\Local State'
   ERROR  GetChromiumBrowserExtensionPath  Last used profile dir is empty
   ```

   The UI then shows the browser/extension as not detected, regardless of whether
   sync (fix #1) is actually working.

## What this fixes

- **Brand spoof** - patches the extension's `background.js`, *on your own already-installed
  copy*, so it reports a brand list that includes `"Google Chrome"`. Only a small,
  literal substitution is applied; the rest of Apple's file is untouched.
- **Detection shim** - creates NTFS junctions (not symlinks, so no admin rights or
  Developer Mode needed) so the hardcoded Google Chrome path resolves to your real
  Chromium profile.

This repository does **not** ship, copy, or modify any of Apple's extension files.
`install.ps1` is our own code; it patches files that already exist on your machine
because you installed "iCloud Bookmarks" yourself.

## Requirements

- Windows, with [iCloud for Windows](https://apps.microsoft.com/detail/9pkjcfhrfd85) installed
  and signed in.
- A Chromium-based browser with **iCloud Bookmarks** already installed and enabled
  (from the Chrome Web Store, or loaded unpacked via `chrome://extensions` > Load
  unpacked).
- PowerShell 5.1+ (ships with Windows).

## Usage

Extension installed normally, from the Chrome Web Store:

```powershell
.\install.ps1 -ChromiumUserData "$env:LOCALAPPDATA\Chromium\User Data"
```

Extension loaded unpacked from a custom folder:

```powershell
.\install.ps1 -ChromiumUserData "$env:LOCALAPPDATA\Chromium\User Data" `
              -UnpackedExtensionPath "C:\path\to\your\iCloud Bookmarks"
```

After it runs:

1. Go to `chrome://extensions`, **remove** "iCloud Bookmarks", then **Load unpacked**
   it again (a plain reload does not reliably pick up a patched service worker -
   Chromium's cached copy of the old script can stick around otherwise).
2. Restart the iCloud app so it re-checks browser detection.

To revert everything:

```powershell
.\install.ps1 -Undo
```

## Verifying it worked

iCloud's logs live under (the random suffix differs per install - use a wildcard):

```
%LOCALAPPDATA%\Packages\AppleInc.iCloud_*\LocalCache\Local\Logs\
```

- `iCloudChrome.*.log` should show `CKBMDaemon::Startup` with **no** "Unknown
  browser" error, and should not loop on `ZMSyncThreadBase::HardResetServerState`.
- `iCloudHome.*.log` should no longer show `GetChromiumBrowserLastUsedProfileDir`
  failures after a restart.
- Your browser's `Bookmarks` file (under
  `<ChromiumUserData>\Default\Bookmarks`) should update shortly after you add or
  remove a bookmark on another Apple device.

## How the detection shim works

A Windows junction makes a folder path transparently resolve to another folder,
without copying anything and without needing admin rights (unlike a symlink).

```powershell
mklink /J "%LOCALAPPDATA%\Google\Chrome\User Data" "%LOCALAPPDATA%\Chromium\User Data"
```

Any program that reads `...\Google\Chrome\User Data\...` - including iCloud's
hardcoded check - transparently ends up reading your real Chromium profile
instead. If the extension is loaded unpacked, a second junction makes its version
folder visible at the path iCloud expects to find it under that profile's
`Extensions` folder.

## Caveats

- Apple may change the extension's minified code in a future update, which could
  break the literal string match `install.ps1` looks for. The script detects this
  case and warns instead of silently doing nothing; re-run it after checking the
  new `background.js` if that happens.
- Any other software on your machine that checks for Google Chrome by reading
  `%LOCALAPPDATA%\Google\Chrome\User Data` will now also see your Chromium profile
  there. This is unlikely to cause problems in practice, but it's a real side
  effect worth knowing about before you run this.

## License

MIT - see [LICENSE](LICENSE). Applies only to the scripts in this repository, not
to any Apple software they operate on.
