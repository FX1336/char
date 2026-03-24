#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up the Windows development environment for Char.
.DESCRIPTION
    Installs Rust (MSVC), Node.js 22, pnpm, and project dependencies.
    Run once after cloning the repository.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\setup-windows.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path $PSScriptRoot -Parent
$RUST_VERSION = "1.94.0"
$NODE_VERSION = "22"

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

# ── Winget ──────────────────────────────────────────────────────────────────
Write-Step "Checking winget"
if (-not (Test-Command "winget")) {
    Write-Error "winget not found. Install App Installer from the Microsoft Store, then re-run this script."
    exit 1
}
Write-Ok "winget available"

# ── WebView2 ─────────────────────────────────────────────────────────────────
Write-Step "WebView2 Runtime"
$webview2 = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -ErrorAction SilentlyContinue
if ($null -eq $webview2) {
    Write-Host "    Installing WebView2 Runtime..."
    $installer = Join-Path $env:TEMP "MicrosoftEdgeWebview2Setup.exe"
    Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/p/?LinkId=2124703" -OutFile $installer
    Start-Process -FilePath $installer -ArgumentList "/silent /install" -Wait
    Remove-Item $installer -Force
    Write-Ok "WebView2 Runtime installed"
} else {
    Write-Skip "WebView2 Runtime"
}

# ── Visual C++ Build Tools ────────────────────────────────────────────────────
Write-Step "Visual C++ Build Tools"
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasMSVC = $false
if (Test-Path $vsWhere) {
    $vsInstall = & $vsWhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    $hasMSVC = ($vsInstall -ne $null) -and ($vsInstall.Trim() -ne "")
}
if (-not $hasMSVC) {
    Write-Host "    Installing Visual C++ Build Tools (this may take a few minutes)..."
    winget install --id Microsoft.VisualStudio.2022.BuildTools --silent --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    $exitCode = $LASTEXITCODE
    # 1602 = already installing / user interaction issue; 0 and 3010 = success (3010 = reboot needed)
    if ($exitCode -ne 0 -and $exitCode -ne 3010 -and $exitCode -ne 1602) {
        Write-Host "    WARN: winget exited with code $exitCode — check manually if MSVC is installed" -ForegroundColor Yellow
    } else {
        Write-Ok "Visual C++ Build Tools installed"
    }
} else {
    Write-Skip "Visual C++ Build Tools"
}

# ── Rust ─────────────────────────────────────────────────────────────────────
Write-Step "Rust toolchain"
if (-not (Test-Command "rustup")) {
    Write-Host "    Installing Rust via rustup-init..."
    $rustupInit = Join-Path $env:TEMP "rustup-init.exe"
    Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile $rustupInit
    & $rustupInit -y --default-toolchain "$RUST_VERSION" --default-host x86_64-pc-windows-msvc --component rust-analyzer,rustfmt,clippy
    try { Remove-Item -LiteralPath $rustupInit -Force -ErrorAction SilentlyContinue } catch {}
    $env:PATH = "$env:USERPROFILE\.cargo\bin;$env:PATH"
    Write-Ok "Rust $RUST_VERSION installed"
} else {
    Write-Skip "rustup"
    Write-Host "    Ensuring toolchain $RUST_VERSION with MSVC target..."
    rustup toolchain install "$RUST_VERSION" --target x86_64-pc-windows-msvc --component rust-analyzer,rustfmt,clippy
    rustup default "$RUST_VERSION"
    Write-Ok "Rust toolchain up to date"
}

# verify MSVC target
$targets = rustup target list --installed
if ($targets -notcontains "x86_64-pc-windows-msvc") {
    rustup target add x86_64-pc-windows-msvc
    Write-Ok "Target x86_64-pc-windows-msvc added"
} else {
    Write-Skip "Target x86_64-pc-windows-msvc"
}

# ── Node.js ───────────────────────────────────────────────────────────────────
Write-Step "Node.js $NODE_VERSION"
$nodeOk = $false
if (Test-Command "node") {
    $currentNode = (node --version) -replace "^v", "" -split "\." | Select-Object -First 1
    if ([int]$currentNode -ge [int]$NODE_VERSION) { $nodeOk = $true }
}
if (-not $nodeOk) {
    Write-Host "    Installing Node.js $NODE_VERSION via winget..."
    winget install --id OpenJS.NodeJS.LTS --silent
    $env:PATH = "$env:ProgramFiles\nodejs;$env:PATH"
    Write-Ok "Node.js installed"
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

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
Write-Host ""
Write-Host "Next step: open a new terminal and run:" -ForegroundColor White
Write-Host "  .\scripts\dev-windows.ps1" -ForegroundColor Yellow
Write-Host ""
Write-Host "NOTE: If this is your first run, close and reopen your terminal" -ForegroundColor DarkYellow
Write-Host "      so that PATH changes (Rust, Node) take effect." -ForegroundColor DarkYellow
