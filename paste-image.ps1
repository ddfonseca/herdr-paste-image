# herdr-paste-image (windows) - save the clipboard image and type its path into the pane
#
# Invoked by a herdr keybind as a plugin action (no arguments). herdr injects
# HERDR_PANE_ID (the focused pane) and HERDR_BIN_PATH into the environment.
# Runs under -STA (set in herdr-plugin.toml): System.Windows.Forms.Clipboard
# requires a single-threaded apartment, which PowerShell isn't by default.

$ErrorActionPreference = "Stop"

$herdrBin = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { "herdr" }
$pane = $env:HERDR_PANE_ID

$saveDir = "$env:LOCALAPPDATA\herdr-paste-image"
$keepDays = 14
$quiet = $false

$configDir = if ($env:HERDR_PLUGIN_CONFIG_DIR) { $env:HERDR_PLUGIN_CONFIG_DIR } else { "$env:APPDATA\herdr\plugins\config\herdr-paste-image" }
$configFile = Join-Path $configDir "config.ps1"
if (Test-Path $configFile) { . $configFile }

if ($env:HERDR_PASTE_IMAGE_DIR) { $saveDir = $env:HERDR_PASTE_IMAGE_DIR }
if ($env:HERDR_PASTE_IMAGE_KEEP_DAYS) { $keepDays = [int]$env:HERDR_PASTE_IMAGE_KEEP_DAYS }
if ($env:HERDR_PASTE_IMAGE_QUIET) { $quiet = $env:HERDR_PASTE_IMAGE_QUIET -eq "1" }

function Notify($title, $body) {
    if ($quiet) { return }
    try { & $herdrBin notification show $title --body $body 2>$null | Out-Null } catch {}
}

function Fail($msg) {
    Notify "Paste image" $msg
    [Console]::Error.WriteLine("herdr-paste-image-windows: $msg")
    exit 1
}

if (-not $pane) { Fail "No focused pane to paste into." }

New-Item -ItemType Directory -Force -Path $saveDir | Out-Null

if ($keepDays -gt 0) {
    $cutoff = (Get-Date).AddDays(-$keepDays)
    Get-ChildItem -Path $saveDir -Filter "image_*" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

$stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$filePath = Join-Path $saveDir "image_$stamp.png"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$imageExtensions = ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg", ".avif", ".tiff", ".tif", ".ico", ".heic"

$img = [System.Windows.Forms.Clipboard]::GetImage()
if ($img) {
    $img.Save($filePath, [System.Drawing.Imaging.ImageFormat]::Png)
    $img.Dispose()
} else {
    $files = [System.Windows.Forms.Clipboard]::GetFileDropList()
    if ($files -and $files.Count -ge 1) {
        $src = $files[0]
        if (-not (Test-Path $src)) { Fail "Clipboard file is not reachable: $src" }
        $ext = [System.IO.Path]::GetExtension($src).ToLowerInvariant()
        if ($imageExtensions -notcontains $ext) { Fail "Clipboard holds a file, but not an image: $(Split-Path $src -Leaf)" }
        $filePath = $src
    } else {
        Fail "No image in the clipboard."
    }
}

if (-not (Test-Path $filePath) -or (Get-Item $filePath).Length -eq 0) {
    Remove-Item $filePath -Force -ErrorAction SilentlyContinue
    Fail "No image in the clipboard."
}

$text = $filePath
if ($filePath -match '\s') { $text = "'$filePath'" }

& $herdrBin pane send-text $pane "$text " | Out-Null

Notify "Image pasted" (Split-Path $filePath -Leaf)
