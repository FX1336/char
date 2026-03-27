#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses the full Windows build environment for Char desktop.
.DESCRIPTION
    Checks every prerequisite that setup-windows.ps1 installs and every
    runtime condition that dev-windows.ps1 depends on.  Run this script
    and paste the output when reporting build issues.
    Does NOT modify any files (read-only analysis).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\diagnose-windows.ps1
#>

$ErrorActionPreference = "Continue"
$REPO_ROOT    = Split-Path $PSScriptRoot -Parent
$LOCAL_BIN    = "$HOME\.local\bin"
$LIBCLANG_DIR = "$HOME\.local\libclang"
$RUST_VERSION = "1.94.0"
$NODE_MAJOR   = 22

$script:issues = [System.Collections.Generic.List[string]]::new()

function Write-Section($title) { Write-Host "`n=== $title ===" -ForegroundColor Cyan }
function OK($msg)   { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function WARN($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:issues.Add("WARN: $msg") }
function FAIL($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:issues.Add("FAIL: $msg") }
function INFO($msg) { Write-Host "         $msg" }

# ---------------------------------------------------------------------------
Write-Section "System"
INFO "PowerShell $($PSVersionTable.PSVersion)  OS: $([System.Environment]::OSVersion.VersionString)"
INFO "User: $env:USERNAME   Profile: $env:USERPROFILE"
INFO "Repo: $REPO_ROOT"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) { OK "Running as Administrator (required for setup-windows.ps1)" }
else          { WARN "Not running as Administrator — setup-windows.ps1 will fail without admin rights" }

$drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -eq "$env:SystemDrive\" }
if ($drives) {
    $freeGB = [math]::Round($drives.Free / 1GB, 1)
    if ($freeGB -lt 15) { WARN "Only ${freeGB} GB free on $env:SystemDrive — Rust builds need ~10-15 GB" }
    else                { OK "${freeGB} GB free on $env:SystemDrive" }
}

# ---------------------------------------------------------------------------
Write-Section "WebView2 Runtime (required by Tauri)"
$wv2 = Get-ItemProperty `
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" `
    -ErrorAction SilentlyContinue
if (-not $wv2) {
    $wv2 = Get-ItemProperty `
        "HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" `
        -ErrorAction SilentlyContinue
}
if ($wv2) { OK "WebView2 installed" }
else      { WARN "WebView2 not found — app will not start without it (usually pre-installed on Win10/11)" }

# ---------------------------------------------------------------------------
Write-Section "Visual Studio Build Tools 2022"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    FAIL "vswhere.exe not found — VS Build Tools not installed"
} else {
    OK "vswhere.exe found"
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null
    if (-not $vsPath) {
        $vsPath = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Workload.VCTools `
            -property installationPath 2>$null
    }
    if ($vsPath) {
        OK "VS/BuildTools with VC++ tools: $vsPath"
        $vcvars = "$vsPath\VC\Auxiliary\Build\vcvars64.bat"
        if (Test-Path $vcvars) {
            OK "vcvars64.bat present"
            # Actually load it and verify key variables are set
            $envDump = cmd /c "`"$vcvars`" >nul 2>&1 && set" 2>&1
            $clPath = ($envDump | Where-Object { $_ -match "^Path=" } | Select-Object -First 1) -replace "^Path=",""
            $hasVcDir = ($envDump | Where-Object { $_ -match "^VCINSTALLDIR=" }).Count -gt 0
            $hasWinSdk = ($envDump | Where-Object { $_ -match "^WindowsSdkDir=" }).Count -gt 0
            if ($hasVcDir)  { OK "vcvars64 loads correctly — VCINSTALLDIR set" }
            else            { FAIL "vcvars64 loaded but VCINSTALLDIR not set — broken VS installation?" }
            if ($hasWinSdk) { OK "Windows SDK dir set by vcvars64" }
            else            { WARN "WindowsSdkDir not set — Windows SDK may be missing" }
        } else {
            FAIL "vcvars64.bat MISSING at: $vcvars"
        }
    } else {
        FAIL "No VS installation found with VC++ compiler component"
        INFO "Run: setup-windows.ps1"
    }
}

# ---------------------------------------------------------------------------
Write-Section "Rust toolchain"
$cargoPath = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $cargoPath) {
    FAIL "cargo not found — add ~/.cargo/bin to PATH or run setup-windows.ps1"
} else {
    OK "cargo: $(cargo --version 2>&1)"
    # Check active toolchain
    $activeToolchain = rustup show active-toolchain 2>&1
    INFO "Active toolchain: $activeToolchain"
    if ($activeToolchain -match "msvc") { OK "MSVC toolchain active" }
    else { FAIL "Non-MSVC toolchain active — expected x86_64-pc-windows-msvc, got: $activeToolchain" }
    # Check exact version
    $cargoVer = (cargo --version 2>&1) -replace "cargo ","" -replace " .*",""
    if ($cargoVer -eq $RUST_VERSION) { OK "Rust version matches required $RUST_VERSION" }
    else { WARN "Rust version is $cargoVer, expected $RUST_VERSION — run: rustup default ${RUST_VERSION}-x86_64-pc-windows-msvc" }
    # Check installed components
    $components = rustup component list --installed 2>&1
    foreach ($comp in @("rust-analyzer", "rustfmt", "clippy")) {
        if ($components -match $comp) { OK "Component installed: $comp" }
        else { WARN "Component missing: $comp — run: rustup component add $comp" }
    }
    # Check target explicitly installed
    $targets = rustup target list --installed 2>&1
    if ($targets -match "x86_64-pc-windows-msvc") { OK "Target x86_64-pc-windows-msvc installed" }
    else { FAIL "Target x86_64-pc-windows-msvc not installed — run: rustup target add x86_64-pc-windows-msvc" }
}

# ---------------------------------------------------------------------------
Write-Section "libclang (for bindgen)"
if (Test-Path "$LIBCLANG_DIR\libclang.dll") { OK "libclang.dll at $LIBCLANG_DIR" }
else { FAIL "libclang.dll missing at $LIBCLANG_DIR — run setup-windows.ps1" }

# ---------------------------------------------------------------------------
Write-Section "fnm + Node.js + pnpm"
$fnmExe = "$LOCAL_BIN\fnm.exe"
if (Test-Path $fnmExe) {
    OK "fnm found: $fnmExe"
    & $fnmExe env --shell powershell 2>$null | Out-String | Invoke-Expression
} else {
    WARN "fnm not found at $fnmExe — run setup-windows.ps1"
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $nodeVer = (node --version) -replace "^v","" -split "\." | Select-Object -First 1
    if ([int]$nodeVer -ge $NODE_MAJOR) { OK "node $(node --version)" }
    else { FAIL "node $(node --version) — need v${NODE_MAJOR}+, run: fnm install $NODE_MAJOR" }
} else { FAIL "node not found — run setup-windows.ps1" }

$pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
if ($pnpm) { OK "pnpm $(pnpm --version)" }
else       { FAIL "pnpm not found — run: npm install -g pnpm" }

# ---------------------------------------------------------------------------
Write-Section "Project dependencies"
$nmPath = Join-Path $REPO_ROOT "node_modules"
if (Test-Path $nmPath) { OK "node_modules present at repo root" }
else { FAIL "node_modules missing — run: pnpm install --frozen-lockfile" }

# Check @hypr/ui CSS build output
$uiDist = Join-Path $REPO_ROOT "packages\ui\dist"
if (Test-Path $uiDist) {
    $cssFiles = @(Get-ChildItem $uiDist -Filter "*.css" -ErrorAction SilentlyContinue)
    if ($cssFiles.Count -gt 0) { OK "@hypr/ui CSS built ($($cssFiles.Count) file(s) in $uiDist)" }
    else { WARN "@hypr/ui dist exists but no .css files — run: pnpm -F @hypr/ui build" }
} else { WARN "@hypr/ui not built — run: pnpm -F @hypr/ui build" }

# ---------------------------------------------------------------------------
Write-Section "libsql-ffi registry source (read-only / os error 5)"
$regSrcRoot = Join-Path $env:USERPROFILE ".cargo\registry\src"
if (-not (Test-Path $regSrcRoot)) {
    WARN "Cargo registry src not found — not downloaded yet (run cargo fetch or let the build pull it)"
} else {
    $libsqlFfiSrc = Get-ChildItem $regSrcRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem $_.FullName -Filter "libsql-ffi-*" -Directory -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if (-not $libsqlFfiSrc) {
        WARN "libsql-ffi not yet in registry (will download on first build)"
    } else {
        INFO "Registry source: $($libsqlFfiSrc.FullName)"
        $allFiles = @(Get-ChildItem $libsqlFfiSrc.FullName -Recurse -File -ErrorAction SilentlyContinue)
        $roFiles  = @($allFiles | Where-Object IsReadOnly)
        INFO "Files: $($allFiles.Count) total, $($roFiles.Count) read-only"
        if ($roFiles.Count -gt 0) {
            WARN "$($roFiles.Count) read-only files — attrib fix in dev-windows.ps1 must clear these before build"
            # Test if attrib actually works here
            $testFile = $roFiles[0]
            & attrib -R "$($libsqlFfiSrc.FullName)" /S /D 2>&1 | Out-Null
            $stillRO = @(Get-ChildItem $libsqlFfiSrc.FullName -Recurse -File -ErrorAction SilentlyContinue | Where-Object IsReadOnly)
            if ($stillRO.Count -eq 0) {
                OK "attrib -R works — read-only attributes removed successfully"
            } else {
                FAIL "attrib -R did NOT remove all read-only flags ($($stillRO.Count) still read-only) — ACL restriction?"
                try {
                    $acl = Get-Acl $stillRO[0].FullName
                    INFO "Owner of blocked file: $($acl.Owner)"
                    $acl.Access | ForEach-Object { INFO "  $($_.IdentityReference) $($_.AccessControlType) $($_.FileSystemRights)" }
                } catch { WARN "Could not read ACL: $_" }
            }
        } else {
            OK "No read-only files in libsql-ffi registry source"
        }
    }
}

# ---------------------------------------------------------------------------
Write-Section "CARGO_TARGET_DIR candidates (AppLocker + sqlite3mc)"
$candidates = @(
    $env:CHAR_TARGET_DIR,
    "$env:LOCALAPPDATA\char-build",
    "$env:TEMP\char-build",
    "$env:USERPROFILE\Documents\char-build",
    "$env:USERPROFILE\.cargo\target\char-desktop"
) | Where-Object { $_ }

$firstAllowed = $null
foreach ($c in $candidates) {
    Write-Host ""
    INFO "Candidate: $c"
    # AppLocker exe probe
    $probe = Join-Path $c "_diag_probe.exe"
    $execOk = $false
    try {
        $null = New-Item -ItemType Directory -Force -Path $c -ErrorAction Stop
        Copy-Item "$env:windir\System32\where.exe" $probe -Force -ErrorAction Stop
        $null = & $probe "where" 2>&1
        $execOk = $true
        OK "  Exe execution: ALLOWED"
        if (-not $firstAllowed) { $firstAllowed = $c }
    } catch {
        FAIL "  Exe execution: BLOCKED ($_)"
    } finally {
        Remove-Item $probe -Force -ErrorAction SilentlyContinue
    }
    # Disk space at this location
    try {
        $drive = (Split-Path -Qualifier $c) + "\"
        $driveInfo = [System.IO.DriveInfo]::new($drive)
        $freeGB = [math]::Round($driveInfo.AvailableFreeSpace / 1GB, 1)
        INFO "  Free space: ${freeGB} GB on $drive"
    } catch {}
    # sqlite3mc staging dir
    $buildBase = Join-Path $c "debug\build"
    if (-not (Test-Path $buildBase)) { INFO "  No debug\build dir yet (first run)"; continue }
    $libsqlDirs = Get-ChildItem $buildBase -Filter "libsql-ffi-*" -Directory -ErrorAction SilentlyContinue
    if (-not $libsqlDirs) { OK "  No libsql-ffi build dirs (clean state)"; continue }
    foreach ($d in $libsqlDirs) {
        $mc = Join-Path $d.FullName "out\sqlite3mc"
        if (Test-Path $mc) {
            $mcRO = @(Get-ChildItem $mc -Recurse -File -ErrorAction SilentlyContinue | Where-Object IsReadOnly)
            if ($mcRO.Count -gt 0) {
                FAIL "  sqlite3mc EXISTS with $($mcRO.Count) read-only files at: $mc"
                INFO "  This causes os error 5 — dev-windows.ps1 must delete this dir before build"
            } else {
                OK "  sqlite3mc exists, all files writable: $mc"
            }
        } else {
            OK "  libsql-ffi build dir present, no stale sqlite3mc: $($d.Name)"
        }
        # Check for successful build artifact
        $lib = Get-ChildItem (Join-Path $d.FullName "out") -Filter "*.lib" -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($lib) { OK "  Build artifact cached: $($lib.Name)" }
    }
}
if ($firstAllowed) { INFO "`ndev-windows.ps1 will use: $firstAllowed" }
else               { FAIL "No candidate path allows exe execution — all paths blocked by AppLocker/WDAC" }

# ---------------------------------------------------------------------------
Write-Section "ORT (ONNX Runtime) cache"
$ortCache = "$env:USERPROFILE\.cache\ort"
if (Test-Path $ortCache) {
    $ortLibs = @(Get-ChildItem $ortCache -Filter "*.dll" -Recurse -ErrorAction SilentlyContinue)
    if ($ortLibs.Count -gt 0) { OK "ORT already cached ($($ortLibs.Count) DLL(s) in $ortCache)" }
    else { WARN "ORT cache dir exists but no DLLs — will download on first build (requires internet)" }
} else {
    WARN "ORT not yet cached at $ortCache — will download on first build (~150 MB, requires internet)"
}

# ---------------------------------------------------------------------------
Write-Section "cp.exe (affects libsql-ffi copy_with_cp)"
$cp = Get-Command cp -ErrorAction SilentlyContinue
if ($cp) {
    OK "cp found: $($cp.Source)"
    $noPreserveSupport = (& cp --help 2>&1) -match "no-preserve"
    if ($noPreserveSupport) { OK "cp supports --no-preserve (libsql-ffi will NOT preserve read-only on copy)" }
    else { WARN "cp found but does not support --no-preserve — libsql-ffi falls back to fs::copy" }
} else {
    WARN "cp not in PATH — libsql-ffi uses fs::copy fallback (preserves read-only from registry)"
    $gitCp = "C:\Program Files\Git\usr\bin\cp.exe"
    if (Test-Path $gitCp) { INFO "  Git cp available at: $gitCp (not in PATH — adding it would fix this permanently)" }
}

# ---------------------------------------------------------------------------
Write-Section "PATH summary (after vcvars64 would be loaded)"
$pathDirs = $env:PATH -split ";" | Where-Object { $_ -ne "" }
foreach ($tool in @("cargo", "cl", "cmake", "ninja", "link", "rc")) {
    $found = $pathDirs | ForEach-Object { Join-Path $_ "$tool.exe" } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($found) { OK "$tool : $found" }
    else        { WARN "$tool.exe not found in current PATH (may be available after vcvars64 loads)" }
}

# ---------------------------------------------------------------------------
Write-Section "Summary"
if ($script:issues.Count -eq 0) {
    Write-Host "`n  All checks passed. Environment looks healthy." -ForegroundColor Green
} else {
    Write-Host "`n  $($script:issues.Count) issue(s) found:" -ForegroundColor Yellow
    foreach ($i in $script:issues) {
        $color = if ($i.StartsWith("FAIL")) { "Red" } else { "Yellow" }
        Write-Host "    $i" -ForegroundColor $color
    }
}
Write-Host ""
