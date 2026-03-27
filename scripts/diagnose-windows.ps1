#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses the Windows build environment for Char desktop.
.DESCRIPTION
    Reports the exact state of every component that dev-windows.ps1 relies on.
    Run this script and paste the output when reporting build issues.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\diagnose-windows.ps1
#>

$ErrorActionPreference = "Continue"

function Write-Section($title) { Write-Host "`n=== $title ===" -ForegroundColor Cyan }
function OK($msg)   { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function WARN($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function FAIL($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function INFO($msg) { Write-Host "  [    ] $msg" }

# ---------------------------------------------------------------------------
Write-Section "System"
INFO "PowerShell $($PSVersionTable.PSVersion)  OS: $([System.Environment]::OSVersion.VersionString)"
INFO "User: $env:USERNAME  Profile: $env:USERPROFILE"

# ---------------------------------------------------------------------------
Write-Section "Visual Studio / Build Tools"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    OK "vswhere.exe found"
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null
    if ($vsPath) {
        OK "VS/BuildTools with VC++ found: $vsPath"
        $vcvars = "$vsPath\VC\Auxiliary\Build\vcvars64.bat"
        if (Test-Path $vcvars) { OK "vcvars64.bat present" }
        else { FAIL "vcvars64.bat MISSING at $vcvars" }
    } else {
        FAIL "No VS/BuildTools installation found that has VC++ tools"
    }
} else {
    FAIL "vswhere.exe not found — VS/BuildTools not installed"
}

# ---------------------------------------------------------------------------
Write-Section "Rust toolchain"
$rustup = Get-Command rustup -ErrorAction SilentlyContinue
if ($rustup) {
    OK "rustup: $(rustup --version 2>&1)"
    $active = rustup show active-toolchain 2>&1
    INFO "Active toolchain: $active"
    if ($active -match "msvc") { OK "MSVC toolchain active" }
    else { WARN "Non-MSVC toolchain active — expected x86_64-pc-windows-msvc" }
} else { FAIL "rustup not found" }

$cargo = Get-Command cargo -ErrorAction SilentlyContinue
if ($cargo) { OK "cargo: $(cargo --version 2>&1)" }
else { FAIL "cargo not found" }

# ---------------------------------------------------------------------------
Write-Section "libsql-ffi registry source (read-only check)"
$regSrcRoot = Join-Path $env:USERPROFILE ".cargo\registry\src"
INFO "Registry src root: $regSrcRoot"
if (-not (Test-Path $regSrcRoot)) {
    FAIL "Registry src root does not exist — cargo registry not downloaded yet"
} else {
    OK "Registry src root exists"
    $libsqlFfiSrc = Get-ChildItem $regSrcRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem $_.FullName -Filter "libsql-ffi-*" -Directory -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if (-not $libsqlFfiSrc) {
        WARN "libsql-ffi not yet in registry (first run, or cargo fetch not done)"
    } else {
        INFO "Found: $($libsqlFfiSrc.FullName)"
        $allFiles  = @(Get-ChildItem $libsqlFfiSrc.FullName -Recurse -File -ErrorAction SilentlyContinue)
        $readOnly  = @($allFiles | Where-Object IsReadOnly)
        INFO "Total files in registry source: $($allFiles.Count)"
        if ($readOnly.Count -gt 0) {
            WARN "$($readOnly.Count) read-only files present (attrib fix needed)"
            INFO "Sample read-only files:"
            $readOnly | Select-Object -First 5 | ForEach-Object { INFO "  $($_.FullName)" }
        } else {
            OK "No read-only files — attrib fix already applied or not needed"
        }

        # Test whether attrib -R actually works on this directory
        INFO "Testing attrib -R on registry source..."
        & attrib -R "$($libsqlFfiSrc.FullName)" /S /D 2>&1 | Out-Null
        $afterAttrib = @(Get-ChildItem $libsqlFfiSrc.FullName -Recurse -File -ErrorAction SilentlyContinue | Where-Object IsReadOnly)
        if ($afterAttrib.Count -eq 0) {
            OK "attrib -R worked — registry source is now fully writable"
        } else {
            FAIL "attrib -R did NOT remove all read-only flags ($($afterAttrib.Count) files still read-only)"
            INFO "First still-read-only file: $($afterAttrib[0].FullName)"
            INFO "Checking ACL of first file..."
            try {
                $acl = Get-Acl $afterAttrib[0].FullName
                INFO "Owner: $($acl.Owner)"
                $acl.Access | ForEach-Object { INFO "  $($_.IdentityReference) $($_.AccessControlType) $($_.FileSystemRights)" }
            } catch { WARN "Could not read ACL: $_" }
        }
    }
}

# ---------------------------------------------------------------------------
Write-Section "CARGO_TARGET_DIR / sqlite3mc staging dirs"
$candidates = @(
    $env:CHAR_TARGET_DIR,
    "$env:LOCALAPPDATA\char-build",
    "$env:TEMP\char-build",
    "$env:USERPROFILE\Documents\char-build",
    "$env:USERPROFILE\.cargo\target\char-desktop"
) | Where-Object { $_ }

foreach ($c in $candidates) {
    if (-not (Test-Path $c)) { continue }
    INFO "Checking target dir: $c"
    $buildBase = Join-Path $c "debug\build"
    if (-not (Test-Path $buildBase)) { INFO "  No debug\build yet"; continue }
    $libsqlDirs = Get-ChildItem $buildBase -Filter "libsql-ffi-*" -Directory -ErrorAction SilentlyContinue
    if (-not $libsqlDirs) { INFO "  No libsql-ffi-* build dirs"; continue }
    foreach ($d in $libsqlDirs) {
        INFO "  Build dir: $($d.Name)"
        $mc = Join-Path $d.FullName "out\sqlite3mc"
        if (Test-Path $mc) {
            $mcFiles  = @(Get-ChildItem $mc -Recurse -File -ErrorAction SilentlyContinue)
            $mcRO     = @($mcFiles | Where-Object IsReadOnly)
            if ($mcRO.Count -gt 0) {
                FAIL "  sqlite3mc EXISTS and has $($mcRO.Count) read-only files — THIS CAUSES THE BUILD ERROR"
                INFO "  Path: $mc"
                INFO "  Sample: $($mcRO[0].FullName)"
            } else {
                WARN "  sqlite3mc EXISTS but files are writable (prior successful build or already fixed)"
                INFO "  Path: $mc"
            }
        } else {
            OK "  No sqlite3mc staging dir (clean state)"
        }
        # Check if the main libsql artifact exists (indicates successful prior build)
        $lib = Get-ChildItem (Join-Path $d.FullName "out") -Filter "*.lib" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($lib) { OK "  Built artifact present: $($lib.Name)" }
    }
}

# ---------------------------------------------------------------------------
Write-Section "AppLocker / WDAC (exe execution test)"
foreach ($c in $candidates) {
    $probe = Join-Path $c "_diag_probe.exe"
    try {
        $null = New-Item -ItemType Directory -Force -Path $c -ErrorAction Stop
        Copy-Item "$env:windir\System32\where.exe" $probe -Force -ErrorAction Stop
        $r = & $probe "where" 2>&1
        OK "Exe execution allowed in: $c"
    } catch {
        FAIL "Exe execution BLOCKED in: $c  ($_)"
    } finally {
        Remove-Item $probe -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
Write-Section "cp.exe (affects libsql-ffi copy_with_cp fallback)"
$cp = Get-Command cp -ErrorAction SilentlyContinue
if ($cp) {
    OK "cp found: $($cp.Source)"
    $cpHelp = & cp --help 2>&1 | Select-String "no-preserve" | Select-Object -First 1
    if ($cpHelp) { OK "cp supports --no-preserve (libsql-ffi will use it correctly)" }
    else { WARN "cp found but may not support --no-preserve=mode,ownership" }
} else {
    WARN "cp NOT in PATH — libsql-ffi falls back to Rust fs::copy (preserves read-only)"
    INFO "Add C:\Program Files\Git\usr\bin to PATH to fix this permanently"
}

# ---------------------------------------------------------------------------
Write-Section "Other tools"
foreach ($tool in @("cmake", "ninja", "node", "pnpm", "cl")) {
    $t = Get-Command $tool -ErrorAction SilentlyContinue
    if ($t) { OK "$tool : $($t.Source)" }
    else     { WARN "$tool not found" }
}

$libclang = "$env:USERPROFILE\.local\libclang\libclang.dll"
if (Test-Path $libclang) { OK "libclang.dll: $libclang" }
else { FAIL "libclang.dll not found at $libclang" }

Write-Host "`nDiagnosis complete." -ForegroundColor Cyan
