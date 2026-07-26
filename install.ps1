<#
.SYNOPSIS
    Fixes iCloud Bookmarks sync on unbranded Chromium builds (e.g. ungoogled-chromium)
    and makes iCloud for Windows detect the browser as installed.

.DESCRIPTION
    Apple's "iCloud Bookmarks" extension and the iCloud for Windows app both perform
    a browser identity check before they will sync anything:

    1. The extension's background service worker reports the browser's brand list
       (navigator.userAgentData.brands) to the native iCloudChrome.exe host. Builds
       that don't ship Google's official branding (Chromium, ungoogled-chromium, most
       forks) report only "Chromium", which the host does not recognize, so it logs
       "Unknown browser. Not initializing syncing." and refuses to sync.

    2. Independently, the iCloud app's settings UI checks whether a supported browser
       is installed by reading a hardcoded path:
       %LOCALAPPDATA%\Google\Chrome\User Data\Local State
       Non-Google-branded Chromium builds live elsewhere, so this check fails and the
       app shows the browser/extension as "not detected" - even once sync is working.

    This script fixes both, without shipping or modifying any of Apple's own files
    in this repository:

    - Fix 1 (brand spoof): patches the extension's background.js *in place*, on your
      own machine, replacing the real brand list with one that includes a
      "Google Chrome" entry. Only a small, literal string replacement is applied;
      the rest of Apple's file is left untouched.

    - Fix 2 (detection shim): creates NTFS junctions (not symlinks - no admin/Developer
      Mode required) so the hardcoded Google Chrome path resolves to your real
      Chromium profile and, if the extension is loaded unpacked, to its real folder.

.PARAMETER ChromiumUserData
    Path to your Chromium-based browser's "User Data" folder, e.g.
    "$env:LOCALAPPDATA\Chromium\User Data" or "$env:LOCALAPPDATA\Chromium-browser\User Data".
    Defaults to "$env:LOCALAPPDATA\Chromium\User Data".

.PARAMETER ExtensionId
    Extension ID of "iCloud Bookmarks". Defaults to the real Chrome Web Store ID
    (fkepacicchenbjecpbpbclokcabebhah). Do not confuse it with "iCloud Passwords"
    (pejdijmoenmkgeppbflobdenhhabjlaj), which is a different extension.

.PARAMETER UnpackedExtensionPath
    Only needed if you loaded "iCloud Bookmarks" via chrome://extensions > Load
    unpacked (for example because you keep a patched copy outside the Extensions
    folder). Point this at that folder so the script can patch it directly and
    create the junction that makes it visible at the hardcoded Google Chrome path.

.PARAMETER Undo
    Reverts the changes: restores background.js from its backup and removes any
    junctions this script created.

.EXAMPLE
    .\install.ps1 -ChromiumUserData "$env:LOCALAPPDATA\Chromium\User Data"

.EXAMPLE
    .\install.ps1 -ChromiumUserData "$env:LOCALAPPDATA\Chromium\User Data" `
                  -UnpackedExtensionPath "$env:USERPROFILE\OneDrive\Backup\iCloud Bookmarks"

.EXAMPLE
    .\install.ps1 -Undo

.NOTES
    Unofficial, community-made fix. Not affiliated with or endorsed by Apple Inc.
    You must already have "iCloud Bookmarks" installed and enabled in your browser -
    this script only patches an existing installation, it does not install the
    extension for you.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ChromiumUserData = "$env:LOCALAPPDATA\Chromium\User Data",

    [string]$ExtensionId = "fkepacicchenbjecpbpbclokcabebhah",

    [string]$UnpackedExtensionPath,

    [switch]$Undo
)

$ErrorActionPreference = "Stop"

# Marker that proves the patch is already applied, used both to make the script
# idempotent and to detect a stale/incompatible extension version on Undo.
$PatchMarker = "spoofedBrands"

$RealBrandsSnippet = 'brands:navigator.userAgentData?.brands'
$PatchedBrandsSnippet = 'brands:spoofedBrands()'

$SpoofFunctionSnippet =
    'function spoofedBrands(){var m=navigator.userAgent.match(/Chrome\/(\d+)/),v=m?m[1]:"150";' +
    'return[{brand:"Not)A;Brand",version:"8"},{brand:"Chromium",version:v},{brand:"Google Chrome",version:v}]}' +
    'function sendInitCommand('

$OriginalSendInitCommandSnippet = 'function sendInitCommand('

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "    OK: $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    WARNING: $Message" -ForegroundColor Yellow
}

function Find-BackgroundScript {
    <#
        Locates background.js for the extension, either under the explicit
        -UnpackedExtensionPath (unpacked/dev-mode install) or under the real
        Chromium profile's Extensions folder (Chrome Web Store install).
    #>
    if ($UnpackedExtensionPath) {
        $candidate = Join-Path $UnpackedExtensionPath "background.js"
        if (-not (Test-Path $candidate)) {
            throw "No background.js found at '$UnpackedExtensionPath'. Check -UnpackedExtensionPath."
        }
        return $candidate
    }

    $extRoot = Join-Path $ChromiumUserData "Default\Extensions\$ExtensionId"
    if (-not (Test-Path $extRoot)) {
        throw "Extension '$ExtensionId' is not installed under '$extRoot'. " +
              "Install 'iCloud Bookmarks' in your browser first, or pass -UnpackedExtensionPath " +
              "if you load it manually."
    }

    $versionDir = Get-ChildItem $extRoot -Directory | Select-Object -First 1
    if (-not $versionDir) {
        throw "Extension folder '$extRoot' exists but has no version subfolder."
    }

    $script = Join-Path $versionDir.FullName "background.js"
    if (-not (Test-Path $script)) {
        throw "No background.js found under '$($versionDir.FullName)'."
    }
    return $script
}

function Backup-BackgroundScript {
    param([string]$ScriptPath)

    $backupPath = "$ScriptPath.bak"
    if (-not (Test-Path $backupPath)) {
        Copy-Item $ScriptPath $backupPath
        Write-Success "Backed up original file to '$backupPath'"
    }
    else {
        Write-Success "Backup already exists at '$backupPath'"
    }
    return $backupPath
}

function Set-BrandSpoof {
    param([string]$ScriptPath)

    $content = Get-Content $ScriptPath -Raw

    if ($content.Contains($PatchMarker)) {
        Write-Success "Already patched, nothing to do"
        return
    }

    if (-not $content.Contains($RealBrandsSnippet) -or -not $content.Contains($OriginalSendInitCommandSnippet)) {
        Write-Warn "Expected code pattern not found - Apple may have shipped a new " +
                   "extension version with different minification. Manual patching required."
        return
    }

    Backup-BackgroundScript -ScriptPath $ScriptPath | Out-Null

    $patched = $content.Replace($OriginalSendInitCommandSnippet, $SpoofFunctionSnippet)
    $patched = $patched.Replace($RealBrandsSnippet, $PatchedBrandsSnippet)

    Set-Content -Path $ScriptPath -Value $patched -NoNewline
    Write-Success "Patched '$ScriptPath'"
}

function Restore-BackgroundScript {
    param([string]$ScriptPath)

    $backupPath = "$ScriptPath.bak"
    if (Test-Path $backupPath) {
        Copy-Item $backupPath $ScriptPath -Force
        Remove-Item $backupPath -Force
        Write-Success "Restored original '$ScriptPath' from backup"
    }
    else {
        Write-Warn "No backup found for '$ScriptPath', leaving it as-is"
    }
}

function Test-IsJunction {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    return (Get-Item $Path -Force).Attributes.ToString().Contains("ReparsePoint")
}

function New-JunctionIfMissing {
    param(
        [string]$LinkPath,
        [string]$TargetPath
    )

    if (Test-Path $LinkPath) {
        Write-Success "'$LinkPath' already exists, leaving it untouched"
        return
    }

    $parent = Split-Path $LinkPath -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    # Junctions don't require admin rights or Developer Mode, unlike symlinks.
    cmd /c mklink /J "$LinkPath" "$TargetPath" | Out-Null
    Write-Success "Created junction '$LinkPath' -> '$TargetPath'"
}

function Remove-JunctionIfPresent {
    param([string]$LinkPath)

    if (-not (Test-Path $LinkPath)) { return }

    if (-not (Test-IsJunction $LinkPath)) {
        Write-Warn "'$LinkPath' is a real folder, not a junction created by this script - leaving it alone"
        return
    }

    # Plain rmdir on a junction removes only the link, never the target's contents.
    cmd /c rmdir "$LinkPath" | Out-Null
    Write-Success "Removed junction '$LinkPath'"
}

function Get-ExtensionVersionFolderName {
    <#
        Chromium's Extensions folder names each version's directory after the
        "version" field in manifest.json (with a "_0" suffix). This must match
        exactly, or Chromium-reading tools (including iCloud's detection check)
        will not find it - it is NOT related to the name of the folder the
        unpacked extension happens to live in.
    #>
    param([string]$UnpackedPath)

    $manifestPath = Join-Path $UnpackedPath "manifest.json"
    if (-not (Test-Path $manifestPath)) {
        throw "No manifest.json found at '$UnpackedPath'."
    }

    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    return "$($manifest.version)_0"
}

function New-ChromeDetectionShim {
    $chromeUserData = "$env:LOCALAPPDATA\Google\Chrome\User Data"

    New-JunctionIfMissing -LinkPath $chromeUserData -TargetPath $ChromiumUserData

    if ($UnpackedExtensionPath) {
        $versionFolderName = Get-ExtensionVersionFolderName -UnpackedPath $UnpackedExtensionPath
        $shimVersionPath = Join-Path $ChromiumUserData "Default\Extensions\$ExtensionId\$versionFolderName"
        New-JunctionIfMissing -LinkPath $shimVersionPath -TargetPath $UnpackedExtensionPath
    }
}

function Remove-ChromeDetectionShim {
    $chromeUserData = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    Remove-JunctionIfPresent -LinkPath $chromeUserData

    if ($UnpackedExtensionPath) {
        $versionFolderName = Get-ExtensionVersionFolderName -UnpackedPath $UnpackedExtensionPath
        $shimVersionPath = Join-Path $ChromiumUserData "Default\Extensions\$ExtensionId\$versionFolderName"
        Remove-JunctionIfPresent -LinkPath $shimVersionPath
    }
}

# --- Main -------------------------------------------------------------------

if ($Undo) {
    Write-Step "Reverting brand spoof patch"
    $script = Find-BackgroundScript
    Restore-BackgroundScript -ScriptPath $script

    Write-Step "Removing Chrome detection shim"
    Remove-ChromeDetectionShim

    Write-Host "`nDone. Reload the extension in chrome://extensions to pick up the restored file." -ForegroundColor Cyan
    return
}

Write-Step "Locating iCloud Bookmarks background.js"
$script = Find-BackgroundScript
Write-Success "Found '$script'"

Write-Step "Applying brand spoof patch"
Set-BrandSpoof -ScriptPath $script

Write-Step "Setting up Chrome detection shim"
New-ChromeDetectionShim

Write-Host ""
Write-Host "Done. Two manual steps remain:" -ForegroundColor Cyan
Write-Host "  1. Go to chrome://extensions, REMOVE 'iCloud Bookmarks', then Load unpacked it again"
Write-Host "     (a plain reload does not reliably pick up a patched service worker)."
Write-Host "  2. Restart the iCloud app (or just Bookmarks sync) so it re-checks browser detection."
Write-Host ""
Write-Host "See README.md 'Verifying it worked' for how to confirm it from the logs."
