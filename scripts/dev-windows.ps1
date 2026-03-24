#Requires -Version 5.1
<#
.SYNOPSIS
    Starts the Char desktop app in development mode on Windows.
.DESCRIPTION
    Verifies prerequisites, then runs: pnpm -F @hypr/desktop tauri:dev
    Cargo target is x86_64-pc-windows-msvc.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\dev-windows.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path $PSScriptRoot -Parent

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

if (-not (Test-Command "node")) {
    Write-Fail "node not found. Run .\scripts\setup-windows.ps1 first."
}
Write-Host "    node    $(node --version)"

if (-not (Test-Command "pnpm")) {
    Write-Fail "pnpm not found. Run .\scripts\setup-windows.ps1 first."
}
Write-Host "    pnpm    $(pnpm --version)"

$targets = rustup target list --installed 2>$null
if ($targets -notcontains "x86_64-pc-windows-msvc") {
    Write-Fail "Rust target x86_64-pc-windows-msvc not installed. Run .\scripts\setup-windows.ps1 first."
}
Write-Host "    target  x86_64-pc-windows-msvc OK"

if (-not (Test-Path (Join-Path $REPO_ROOT "node_modules"))) {
    Write-Fail "node_modules missing. Run .\scripts\setup-windows.ps1 first (or: pnpm install --frozen-lockfile)."
}
Write-Host "    deps    node_modules present"

# ── Start dev server ─────────────────────────────────────────────────────────
Write-Step "Starting Char (dev mode)"
Write-Host "    Frontend:  http://localhost:1422"
Write-Host "    Backend:   x86_64-pc-windows-msvc"
Write-Host "    Features:  dev"
Write-Host ""
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

Push-Location $REPO_ROOT
pnpm -F "@hypr/desktop" tauri:dev
Pop-Location
