#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up the Windows development environment for Char (no admin rights required).
.DESCRIPTION
    Installs MinGW-w64, Rust (GNU), fnm, Node.js 22, pnpm, and project dependencies.
    All tools install into the user profile; no administrator privileges needed.
    Run once after cloning the repository.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\setup-windows.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path $PSScriptRoot -Parent
$RUST_VERSION = "1.94.0"
$NODE_VERSION = "22"
$LOCAL_BIN = "$HOME\.local\bin"
$MINGW_DIR = "$HOME\.local\mingw64"

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    OK  $Message" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Message)
    Write-Host "    --  $Message (already installed, skipping)" -ForegroundColor DarkGray
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

New-Item -ItemType Directory -Force -Path $LOCAL_BIN | Out-Null

# ── WebView2 ─────────────────────────────────────────────────────────────────
Write-Step "WebView2 Runtime"
$webview2 = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -ErrorAction SilentlyContinue
if ($null -eq $webview2) {
    $webview2 = Get-ItemProperty -Path "HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -ErrorAction SilentlyContinue
}
if ($null -eq $webview2) {
    Write-Host "    WebView2 not found. On Windows 10/11 it is usually pre-installed." -ForegroundColor Yellow
    Write-Host "    If the app fails to start, download the Evergreen Runtime from:" -ForegroundColor Yellow
    Write-Host "    https://developer.microsoft.com/microsoft-edge/webview2/" -ForegroundColor Yellow
} else {
    Write-Skip "WebView2 Runtime"
}

# ── MinGW-w64 (portable C++ toolchain, no admin needed) ──────────────────────
Write-Step "MinGW-w64 (C++ toolchain)"
$gccExe = "$MINGW_DIR\bin\gcc.exe"
$crt2 = "$MINGW_DIR\x86_64-w64-mingw32\lib\crt2.o"
if (-not (Test-Path $gccExe) -or -not (Test-Path $crt2)) {
    Write-Host "    Fetching latest WinLibs release info..."
    $release = Invoke-RestMethod "https://api.github.com/repos/brechtsanders/winlibs_mingw/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -match "^winlibs-x86_64-posix-seh-gcc-.*ucrt.*\.zip$" } | Select-Object -First 1
    if ($null -eq $asset) {
        Write-Error "Could not find MinGW-w64 zip in latest WinLibs release."
        exit 1
    }
    Write-Host "    Downloading $($asset.name)..."
    $zipPath = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
    Write-Host "    Extracting to $HOME\.local\ ..."
    Expand-Archive -LiteralPath $zipPath -DestinationPath "$HOME\.local" -Force
    try { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue } catch {}
    Write-Ok "MinGW-w64 installed at $MINGW_DIR"
} else {
    Write-Skip "MinGW-w64"
}
$env:PATH = "$MINGW_DIR\bin;$env:PATH"

# ── Rust toolchain (GNU, no MSVC needed) ─────────────────────────────────────
Write-Step "Rust toolchain"
if (-not (Test-Command "rustup")) {
    Write-Host "    Installing Rust via rustup-init..."
    $rustupInit = Join-Path $env:TEMP "rustup-init.exe"
    Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile $rustupInit
    & $rustupInit -y --default-toolchain "$RUST_VERSION" --default-host x86_64-pc-windows-gnu --component rust-analyzer,rustfmt,clippy
    try { Remove-Item -LiteralPath $rustupInit -Force -ErrorAction SilentlyContinue } catch {}
    $env:PATH = "$env:USERPROFILE\.cargo\bin;$env:PATH"
    Write-Ok "Rust $RUST_VERSION installed"
} else {
    Write-Skip "rustup"
    Write-Host "    Ensuring toolchain $RUST_VERSION-x86_64-pc-windows-gnu..."
    rustup toolchain install "$RUST_VERSION-x86_64-pc-windows-gnu" --component rust-analyzer,rustfmt,clippy
    # Set default-host so rust-toolchain.toml (channel only) resolves to GNU, not MSVC
    rustup set default-host x86_64-pc-windows-gnu
    rustup default "$RUST_VERSION-x86_64-pc-windows-gnu"
    Write-Ok "Rust toolchain up to date"
}

$targets = rustup target list --installed
if ($targets -notcontains "x86_64-pc-windows-gnu") {
    rustup target add x86_64-pc-windows-gnu
    Write-Ok "Target x86_64-pc-windows-gnu added"
} else {
    Write-Skip "Target x86_64-pc-windows-gnu"
}

# ── ONNX Runtime 1.22.0 (MinGW import library) ───────────────────────────────
# ort-sys 2.0.0-rc.10 requires ORT 1.22.0.  The pyke CDN prebuilt for Windows
# is a static MSVC .lib (no DLL) — MinGW cannot use it.  The official Microsoft
# release ships onnxruntime.dll; we convert that to a MinGW import library
# (.dll.a) with gendef + dlltool from the MinGW-w64 installed above.
Write-Step "ONNX Runtime 1.22.0 (MinGW import library)"
$ORT_VERSION = "1.22.0"
$ORT_DIR = "$HOME\.local\onnxruntime"
$ORT_IMPORT_LIB = "$ORT_DIR\lib\libonnxruntime.dll.a"

if (-not (Test-Path $ORT_IMPORT_LIB)) {
    Write-Host "    Downloading ONNX Runtime $ORT_VERSION (official Microsoft release)..."
    $ortZip = Join-Path $env:TEMP "onnxruntime-win-x64.zip"
    Invoke-WebRequest -Uri "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/onnxruntime-win-x64-$ORT_VERSION.zip" -OutFile $ortZip

    Write-Host "    Extracting..."
    $tempExtract = Join-Path $env:TEMP "ort-extract"
    if (Test-Path $tempExtract) { Remove-Item -Recurse -Force $tempExtract }
    Expand-Archive -LiteralPath $ortZip -DestinationPath $tempExtract -Force
    try { Remove-Item -LiteralPath $ortZip -Force -ErrorAction SilentlyContinue } catch {}

    # The zip contains a single top-level versioned directory; strip it.
    $innerDir = Get-ChildItem -Path $tempExtract -Directory | Select-Object -First 1
    if (-not $innerDir) {
        Write-Error "Unexpected archive structure in ORT zip (no top-level directory found)."
        exit 1
    }
    New-Item -ItemType Directory -Force -Path $ORT_DIR | Out-Null
    Get-ChildItem -Path $innerDir.FullName | ForEach-Object {
        Move-Item -Path $_.FullName -Destination $ORT_DIR -Force
    }
    try { Remove-Item -Recurse -Force $tempExtract -ErrorAction SilentlyContinue } catch {}

    if (-not (Test-Path "$ORT_DIR\lib\onnxruntime.dll")) {
        Write-Error "onnxruntime.dll not found at $ORT_DIR\lib\ after extraction."
        exit 1
    }

    Write-Host "    Creating MinGW import library (gendef + dlltool)..."
    Push-Location "$ORT_DIR\lib"
    gendef onnxruntime.dll
    if ($LASTEXITCODE -ne 0) {
        Pop-Location
        Write-Error "gendef failed (exit $LASTEXITCODE). Is MinGW-w64 installed and on PATH?"
        exit 1
    }
    dlltool -D onnxruntime.dll -d onnxruntime.def -l libonnxruntime.dll.a
    if ($LASTEXITCODE -ne 0) {
        Pop-Location
        Write-Error "dlltool failed (exit $LASTEXITCODE)."
        exit 1
    }
    try { Remove-Item -Force onnxruntime.def -ErrorAction SilentlyContinue } catch {}
    Pop-Location
    Write-Ok "ONNX Runtime import library created at $ORT_IMPORT_LIB"
} else {
    Write-Skip "ONNX Runtime MinGW import library"
}

# ── fnm (portable Node version manager) ──────────────────────────────────────
Write-Step "fnm (Node version manager)"
$fnmExe = "$LOCAL_BIN\fnm.exe"
if (-not (Test-Path $fnmExe)) {
    Write-Host "    Downloading fnm..."
    $fnmZip = Join-Path $env:TEMP "fnm-windows.zip"
    Invoke-WebRequest -Uri "https://github.com/Schniz/fnm/releases/latest/download/fnm-windows.zip" -OutFile $fnmZip
    Expand-Archive -LiteralPath $fnmZip -DestinationPath $LOCAL_BIN -Force
    try { Remove-Item -LiteralPath $fnmZip -Force -ErrorAction SilentlyContinue } catch {}
    Write-Ok "fnm installed"
} else {
    Write-Skip "fnm"
}
$env:PATH = "$LOCAL_BIN;$env:PATH"
# Activate any already-installed fnm Node so the version check below works
& $fnmExe env --shell powershell 2>$null | Out-String | Invoke-Expression

# ── Node.js ───────────────────────────────────────────────────────────────────
Write-Step "Node.js $NODE_VERSION"
$nodeOk = $false
if (Test-Command "node") {
    $currentNode = (node --version) -replace "^v", "" -split "\." | Select-Object -First 1
    if ([int]$currentNode -ge [int]$NODE_VERSION) { $nodeOk = $true }
}
if (-not $nodeOk) {
    Write-Host "    Installing Node.js $NODE_VERSION via fnm..."
    & $fnmExe install $NODE_VERSION
    & $fnmExe env --shell powershell | Out-String | Invoke-Expression
    Write-Ok "Node.js $(node --version) installed"
} else {
    Write-Skip "Node.js $(node --version)"
}

# ── pnpm ─────────────────────────────────────────────────────────────────────
Write-Step "pnpm"
if (-not (Test-Command "pnpm")) {
    Write-Host "    Installing pnpm..."
    npm install -g pnpm
    Write-Ok "pnpm installed"
} else {
    Write-Skip "pnpm $(pnpm --version)"
}

# ── Project dependencies ──────────────────────────────────────────────────────
Write-Step "Installing project dependencies"
Push-Location $REPO_ROOT
pnpm install --frozen-lockfile
Pop-Location
Write-Ok "pnpm install done"

# ── Build workspace packages that ship compiled output ────────────────────────
Write-Step "Building @hypr/ui (CSS)"
Push-Location $REPO_ROOT
pnpm -F "@hypr/ui" build
Pop-Location
Write-Ok "@hypr/ui built"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
Write-Host ""
Write-Host "To make tools available in every new terminal, add this to your" -ForegroundColor White
Write-Host "PowerShell profile (run: notepad `$PROFILE):" -ForegroundColor White
Write-Host ""
Write-Host "  `$env:PATH = `"$MINGW_DIR\bin;$LOCAL_BIN;`$env:USERPROFILE\.cargo\bin;`$env:PATH`"" -ForegroundColor Yellow
Write-Host "  fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next step: open a new terminal and run:" -ForegroundColor White
Write-Host "  .\scripts\dev-windows.ps1" -ForegroundColor Yellow
Write-Host ""
