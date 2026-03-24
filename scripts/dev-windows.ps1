#Requires -Version 5.1
<#
.SYNOPSIS
    Starts the Char desktop app in development mode on Windows.
.DESCRIPTION
    Verifies prerequisites, then runs: pnpm -F @hypr/desktop tauri:dev
    Cargo target is x86_64-pc-windows-gnu (MinGW-w64, no admin required).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\dev-windows.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path $PSScriptRoot -Parent
$LOCAL_BIN = "$HOME\.local\bin"
$MINGW_DIR = "$HOME\.local\mingw64"

# Ensure tools installed by setup-windows.ps1 are on PATH
$env:PATH = "$MINGW_DIR\bin;$LOCAL_BIN;$env:USERPROFILE\.cargo\bin;$env:PATH"

# libsql-ffi build script calls `cp --no-preserve=mode,ownership -R`.
# Git for Windows ships a GNU cp.exe in usr\bin, but only adds cmd\ to PATH by
# default.  Find the usr\bin directory and prepend it so Cargo sees a real cp.
$gitCpDir = $null
$gitExe = Get-Command git -ErrorAction SilentlyContinue
if ($gitExe) {
    # git.exe lives in ..\cmd\git.exe or ..\bin\git.exe relative to usr\bin
    $gitRoot = $gitExe.Source
    foreach ($rel in @("..\..\usr\bin", "..\usr\bin")) {
        $candidate = [IO.Path]::GetFullPath((Join-Path (Split-Path $gitRoot) $rel))
        if (Test-Path "$candidate\cp.exe") { $gitCpDir = $candidate; break }
    }
}
if ($gitCpDir) {
    $env:PATH = "$gitCpDir;$env:PATH"
} else {
    Write-Host "Warning: GNU cp not found via Git for Windows." -ForegroundColor Yellow
    Write-Host "         If the build fails on libsql-ffi, install Git for Windows" -ForegroundColor Yellow
    Write-Host "         or run: winget install Git.Git" -ForegroundColor Yellow
}

# Activate the fnm-managed Node version if fnm is available
$fnmExe = "$LOCAL_BIN\fnm.exe"
if (Test-Path $fnmExe) {
    & $fnmExe env --shell powershell | Out-String | Invoke-Expression
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Fail {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# ── Preflight checks ──────────────────────────────────────────────────────────
Write-Step "Preflight checks"

if (-not (Test-Command "cargo")) {
    Write-Fail "cargo not found. Run .\scripts\setup-windows.ps1 first."
}
Write-Host "    cargo   $(cargo --version)"

if (-not (Test-Command "gcc")) {
    Write-Fail "gcc not found at $MINGW_DIR\bin. Run .\scripts\setup-windows.ps1 first."
}
Write-Host "    gcc     $(gcc --version | Select-Object -First 1)"

if (-not (Test-Command "node")) {
    Write-Fail "node not found. Run .\scripts\setup-windows.ps1 first."
}
Write-Host "    node    $(node --version)"

if (-not (Test-Command "pnpm")) {
    Write-Fail "pnpm not found. Run .\scripts\setup-windows.ps1 first."
}
Write-Host "    pnpm    $(pnpm --version)"

$targets = rustup target list --installed 2>$null
if ($targets -notcontains "x86_64-pc-windows-gnu") {
    Write-Fail "Rust target x86_64-pc-windows-gnu not installed. Run .\scripts\setup-windows.ps1 first."
}
Write-Host "    target  x86_64-pc-windows-gnu OK"

if (-not (Test-Path (Join-Path $REPO_ROOT "node_modules"))) {
    Write-Fail "node_modules missing. Run .\scripts\setup-windows.ps1 first (or: pnpm install --frozen-lockfile)."
}
Write-Host "    deps    node_modules present"

# ── Start dev server ─────────────────────────────────────────────────────────
Write-Step "Starting Char (dev mode)"
Write-Host "    Frontend:  http://localhost:1422"
Write-Host "    Backend:   x86_64-pc-windows-gnu"
Write-Host "    Features:  dev"
Write-Host ""
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Note: Windows may show a Firewall prompt for the Tauri binary." -ForegroundColor DarkGray
Write-Host "      You can safely dismiss it -- localhost traffic is never blocked." -ForegroundColor DarkGray
Write-Host ""

Push-Location $REPO_ROOT
pnpm -F "@hypr/desktop" tauri:dev
Pop-Location
