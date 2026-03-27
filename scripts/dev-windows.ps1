#Requires -Version 5.1
<#
.SYNOPSIS
    Starts the Char desktop app in development mode on Windows (MSVC).
.DESCRIPTION
    Loads the Visual Studio 2022 build environment, then runs:
    pnpm -F @hypr/desktop tauri:dev
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\dev-windows.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO_ROOT    = Split-Path $PSScriptRoot -Parent
$LOCAL_BIN    = "$HOME\.local\bin"
$LIBCLANG_DIR = "$HOME\.local\libclang"

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

# -- Load Visual Studio MSVC environment ---------------------------------------
# Runs vcvars64.bat and imports all environment variables it sets
# (PATH, INCLUDE, LIB, LIBPATH, cl.exe location, cmake, ninja, etc.).
Write-Step "Loading VS 2022 build environment"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Fail "vswhere.exe not found. Run .\scripts\setup-windows.ps1 first."
}
# -products * includes Build Tools; use component ID which is more reliable
# than the workload ID for standalone Build Tools installations.
$vsPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath 2>$null
if (-not $vsPath) {
    # Fallback: workload-based query
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Workload.VCTools `
        -property installationPath 2>$null
}
if (-not $vsPath) {
    Write-Fail "VS Build Tools not found. Run .\scripts\setup-windows.ps1 first."
}
$vcvars = "$vsPath\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) {
    Write-Fail "vcvars64.bat not found at: $vcvars"
}

# Import all env vars set by vcvars64.bat into the current PowerShell session.
$envDump = cmd /c "`"$vcvars`" >nul 2>&1 && set"
foreach ($line in $envDump) {
    if ($line -match "^([^=]+)=(.*)$") {
        $k = $Matches[1]; $v = $Matches[2]
        [System.Environment]::SetEnvironmentVariable($k, $v)
        if ($k -eq "PATH") { $env:PATH = $v }
    }
}
Write-Host "    VS path: $vsPath"

# -- Additional PATH entries ----------------------------------------------------
$env:PATH = "$LOCAL_BIN;$env:USERPROFILE\.cargo\bin;$env:PATH"

# -- cp.exe (required by libsql-ffi build script) ------------------------------
# libsql-ffi build.rs copies SQLite3MultipleCiphers via `cp -R --no-preserve=...`.
# Without a real cp.exe, Command::new("cp") fails and the code falls back to
# fs::copy(directory), which on Windows returns ERROR_ACCESS_DENIED (os error 5)
# because CopyFileExW does not accept a directory as source.  The match arm
# `Err(err) if err.kind() == io::ErrorKind::InvalidInput` does NOT match
# PermissionDenied, so copy_dir_all is never called and .unwrap() panics.
# Git for Windows ships a real cp.exe in usr\bin that handles -R correctly.
$gitCpCandidates = @(
    "$env:ProgramFiles\Git\usr\bin",
    "${env:ProgramFiles(x86)}\Git\usr\bin",
    "$env:LOCALAPPDATA\Programs\Git\usr\bin"
)
$gitUsrBin = $gitCpCandidates | Where-Object { Test-Path (Join-Path $_ "cp.exe") } | Select-Object -First 1
if ($gitUsrBin) {
    # IMPORTANT: do NOT add all of usr\bin to PATH — it contains link.exe (GNU
    # linker) which would shadow MSVC's link.exe and break every crate that
    # links against Windows SDK libs.  Copy only cp.exe to an isolated dir.
    $gitCpIsolated = Join-Path $env:TEMP "char-git-cp"
    $null = New-Item -ItemType Directory -Force -Path $gitCpIsolated
    Copy-Item -LiteralPath (Join-Path $gitUsrBin "cp.exe") -Destination $gitCpIsolated -Force
    $env:PATH = "$gitCpIsolated;$env:PATH"
    Write-Host "  cp.exe: $gitCpIsolated\cp.exe (isolated from $gitUsrBin)"
} else {
    Write-Host ""
    Write-Host "  ERROR: cp.exe not found (Git for Windows not installed?)." -ForegroundColor Red
    Write-Host "  libsql-ffi needs cp.exe to copy its bundled SQLite source." -ForegroundColor Yellow
    Write-Host "  Install Git for Windows: https://git-scm.com/download/win" -ForegroundColor Yellow
    Write-Host "  Then re-run this script." -ForegroundColor Yellow
    exit 1
}

# -- libclang for bindgen -------------------------------------------------------
$env:LIBCLANG_PATH = $LIBCLANG_DIR

# -- ONNX Runtime (auto-download via ort-sys) ----------------------------------
# ort-sys downloads the correct ORT package from pyke's CDN automatically.
# ORT_STRATEGY=download is the default; set it explicitly for clarity.
$env:ORT_STRATEGY = "download"

# -- CARGO_TARGET_DIR (AppLocker probe) ----------------------------------------
# Corporate AppLocker/WDAC policies can block unsigned build-script executables
# from certain paths (os error 4551). Probe candidate paths and use the first
# one that allows execution. Set CHAR_TARGET_DIR to force a specific path.
#
# IMPORTANT: probe with a real .exe, not a .bat.  AppLocker EXE rules do NOT
# apply to .bat files, so a .bat probe always passes even when compiled Rust
# build-script .exe files are blocked.  We copy a known system binary to the
# candidate directory; if AppLocker uses path-based rules the copy will be
# blocked just like any other .exe placed there.
function Test-ExecAllowed($dir) {
    $probe = Join-Path $dir "_exec_probe.exe"
    try {
        $null = New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop
        Copy-Item -LiteralPath "$env:windir\System32\where.exe" `
            -Destination $probe -Force -ErrorAction Stop
        $null = & $probe "where" 2>&1
        return $true
    } catch {
        return $false
    } finally {
        try { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue } catch {}
    }
}

if ($env:CHAR_TARGET_DIR) {
    $env:CARGO_TARGET_DIR = $env:CHAR_TARGET_DIR
    Write-Host "  CARGO_TARGET_DIR (override): $env:CARGO_TARGET_DIR"
} else {
    $candidates = @(
        "$env:LOCALAPPDATA\char-build",
        "$env:TEMP\char-build",
        "$env:USERPROFILE\Documents\char-build",
        "$env:USERPROFILE\.cargo\target\char-desktop"
    )
    $chosen = $null
    foreach ($c in $candidates) {
        if (Test-ExecAllowed $c) { $chosen = $c; break }
        Write-Host "  [blocked] $c"
    }
    if ($chosen) {
        $env:CARGO_TARGET_DIR = $chosen
        Write-Host "  CARGO_TARGET_DIR: $env:CARGO_TARGET_DIR"
    } else {
        Write-Host ""
        Write-Host "  ERROR: All build paths blocked by AppLocker/WDAC." -ForegroundColor Red
        Write-Host "  Ask IT to whitelist one of these paths for EXE execution:" -ForegroundColor Yellow
        foreach ($c in $candidates) { Write-Host "    $c\*" -ForegroundColor Yellow }
        Write-Host "  Or set CHAR_TARGET_DIR to an already-whitelisted path." -ForegroundColor Yellow
        exit 1
    }
}

# -- Windows Defender exclusions (best-effort) ---------------------------------
# AV real-time scanning locks .cargo/registry/src files mid-copy and causes
# os error 5 in build scripts.  Add exclusions if running as admin; skip if
# not (setup-windows.ps1 handles the authoritative add as admin).
$isAdminDev = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdminDev -and $env:CARGO_TARGET_DIR) {
    foreach ($p in @("$env:USERPROFILE\.cargo", $env:CARGO_TARGET_DIR)) {
        try { Add-MpPreference -ExclusionPath $p -ErrorAction Stop } catch {}
    }
}

# -- Fix libsql-ffi Windows leftover state -------------------------------------
# Now that cp.exe is in PATH, libsql-ffi will use the Unix path correctly.
# Belt-and-suspenders: also strip read-only from the registry source and delete
# any stale sqlite3mc staging dir from earlier failed builds, so the build
# script always starts from a clean writable state.
#
# NOTE: PS5.1 does NOT expand wildcards in the middle of a path, so
#       Get-ChildItem "dir\glob-*\sub\dir" silently returns nothing.
#       We enumerate in two steps to avoid this.

$regSrcRoot = Join-Path $env:USERPROFILE ".cargo\registry\src"
if (Test-Path $regSrcRoot) {
    $libsqlFfiSrc = Get-ChildItem $regSrcRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem $_.FullName -Filter "libsql-ffi-*" -Directory -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if ($libsqlFfiSrc) {
        & attrib -R "$($libsqlFfiSrc.FullName)" /S /D
        Write-Host "  Stripped read-only from libsql-ffi registry source: $($libsqlFfiSrc.Name)"
    }
}

if ($env:CARGO_TARGET_DIR) {
    $buildBase = Join-Path $env:CARGO_TARGET_DIR "debug\build"
    if (Test-Path $buildBase) {
        Get-ChildItem $buildBase -Filter "libsql-ffi-*" -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $mc = Join-Path $_.FullName "out\sqlite3mc"
                if (Test-Path $mc) {
                    Remove-Item -Recurse -Force -LiteralPath $mc
                    Write-Host "  Removed stale sqlite3mc: $mc"
                }
            }
    }
}

# -- Activate fnm Node version -------------------------------------------------
$fnmExe = "$LOCAL_BIN\fnm.exe"
if (Test-Path $fnmExe) {
    & $fnmExe env --shell powershell | Out-String | Invoke-Expression
}

# -- Preflight checks ----------------------------------------------------------
Write-Step "Preflight checks"

if (-not (Test-Command "cargo"))  { Write-Fail "cargo not found. Run .\scripts\setup-windows.ps1 first." }
Write-Host "    cargo   $(cargo --version)"

if (-not (Test-Command "cl"))     { Write-Fail "cl.exe not found. VS environment not loaded correctly." }
Write-Host "    cl.exe  present"

if (-not (Test-Command "cmake"))  { Write-Fail "cmake not found. Run .\scripts\setup-windows.ps1 first." }
Write-Host "    cmake   $(cmake --version | Select-Object -First 1)"

if (-not (Test-Command "node"))   { Write-Fail "node not found. Run .\scripts\setup-windows.ps1 first." }
Write-Host "    node    $(node --version)"

if (-not (Test-Command "pnpm"))   { Write-Fail "pnpm not found. Run .\scripts\setup-windows.ps1 first." }
Write-Host "    pnpm    $(pnpm --version)"

if (-not (Test-Path "$LIBCLANG_DIR\libclang.dll")) {
    Write-Fail "libclang.dll missing at $LIBCLANG_DIR. Run .\scripts\setup-windows.ps1 first."
}
Write-Host "    libclang  $LIBCLANG_DIR\libclang.dll"

if (-not (Test-Path (Join-Path $REPO_ROOT "node_modules"))) {
    Write-Fail "node_modules missing. Run .\scripts\setup-windows.ps1 first."
}
Write-Host "    deps    node_modules present"

# -- Start dev server ----------------------------------------------------------
Write-Step "Starting Char (dev mode)"
Write-Host "    Target:    x86_64-pc-windows-msvc"
Write-Host "    Frontend:  http://localhost:1422"
Write-Host "    Features:  dev"
Write-Host ""
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

Push-Location $REPO_ROOT
pnpm -F "@hypr/desktop" tauri:dev
$exitCode = $LASTEXITCODE
Pop-Location
exit $exitCode
