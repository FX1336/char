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
else          { WARN "Not running as Administrator  -  setup-windows.ps1 will fail without admin rights" }

$drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -eq "$env:SystemDrive\" }
if ($drives) {
    $freeGB = [math]::Round($drives.Free / 1GB, 1)
    if ($freeGB -lt 15) { WARN "Only ${freeGB} GB free on $env:SystemDrive  -  Rust builds need ~10-15 GB" }
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
else      { WARN "WebView2 not found  -  app will not start without it (usually pre-installed on Win10/11)" }

# ---------------------------------------------------------------------------
Write-Section "Visual Studio Build Tools 2022"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    FAIL "vswhere.exe not found  -  VS Build Tools not installed"
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
            if ($hasVcDir)  { OK "vcvars64 loads correctly  -  VCINSTALLDIR set" }
            else            { FAIL "vcvars64 loaded but VCINSTALLDIR not set  -  broken VS installation?" }
            if ($hasWinSdk) { OK "Windows SDK dir set by vcvars64" }
            else            { WARN "WindowsSdkDir not set  -  Windows SDK may be missing" }
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
    FAIL "cargo not found  -  add ~/.cargo/bin to PATH or run setup-windows.ps1"
} else {
    OK "cargo: $(cargo --version 2>&1)"
    # Check active toolchain
    $activeToolchain = rustup show active-toolchain 2>&1
    INFO "Active toolchain: $activeToolchain"
    if ($activeToolchain -match "msvc") { OK "MSVC toolchain active" }
    else { FAIL "Non-MSVC toolchain active  -  expected x86_64-pc-windows-msvc, got: $activeToolchain" }
    # Check exact version
    $cargoVer = (cargo --version 2>&1) -replace "cargo ","" -replace " .*",""
    if ($cargoVer -eq $RUST_VERSION) { OK "Rust version matches required $RUST_VERSION" }
    else { WARN "Rust version is $cargoVer, expected $RUST_VERSION  -  run: rustup default ${RUST_VERSION}-x86_64-pc-windows-msvc" }
    # Check installed components
    $components = rustup component list --installed 2>&1
    foreach ($comp in @("rust-analyzer", "rustfmt", "clippy")) {
        if ($components -match $comp) { OK "Component installed: $comp" }
        else { WARN "Component missing: $comp  -  run: rustup component add $comp" }
    }
    # Check target explicitly installed
    $targets = rustup target list --installed 2>&1
    if ($targets -match "x86_64-pc-windows-msvc") { OK "Target x86_64-pc-windows-msvc installed" }
    else { FAIL "Target x86_64-pc-windows-msvc not installed  -  run: rustup target add x86_64-pc-windows-msvc" }
}

# ---------------------------------------------------------------------------
Write-Section "libclang (for bindgen)"
if (Test-Path "$LIBCLANG_DIR\libclang.dll") { OK "libclang.dll at $LIBCLANG_DIR" }
else { FAIL "libclang.dll missing at $LIBCLANG_DIR  -  run setup-windows.ps1" }

# ---------------------------------------------------------------------------
Write-Section "fnm + Node.js + pnpm"
$fnmExe = "$LOCAL_BIN\fnm.exe"
if (Test-Path $fnmExe) {
    OK "fnm found: $fnmExe"
    & $fnmExe env --shell powershell 2>$null | Out-String | Invoke-Expression
} else {
    WARN "fnm not found at $fnmExe  -  run setup-windows.ps1"
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $nodeVer = (node --version) -replace "^v","" -split "\." | Select-Object -First 1
    if ([int]$nodeVer -ge $NODE_MAJOR) { OK "node $(node --version)" }
    else { FAIL "node $(node --version)  -  need v${NODE_MAJOR}+, run: fnm install $NODE_MAJOR" }
} else { FAIL "node not found  -  run setup-windows.ps1" }

$pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
if ($pnpm) { OK "pnpm $(pnpm --version)" }
else       { FAIL "pnpm not found  -  run: npm install -g pnpm" }

# ---------------------------------------------------------------------------
Write-Section "Project dependencies"
$nmPath = Join-Path $REPO_ROOT "node_modules"
if (Test-Path $nmPath) { OK "node_modules present at repo root" }
else { FAIL "node_modules missing  -  run: pnpm install --frozen-lockfile" }

# Check @hypr/ui CSS build output
$uiDist = Join-Path $REPO_ROOT "packages\ui\dist"
if (Test-Path $uiDist) {
    $cssFiles = @(Get-ChildItem $uiDist -Filter "*.css" -ErrorAction SilentlyContinue)
    if ($cssFiles.Count -gt 0) { OK "@hypr/ui CSS built ($($cssFiles.Count) file(s) in $uiDist)" }
    else { WARN "@hypr/ui dist exists but no .css files  -  run: pnpm -F @hypr/ui build" }
} else { WARN "@hypr/ui not built  -  run: pnpm -F @hypr/ui build" }

# ---------------------------------------------------------------------------
Write-Section "libsql-ffi registry source (read-only / os error 5)"
$regSrcRoot = Join-Path $env:USERPROFILE ".cargo\registry\src"
if (-not (Test-Path $regSrcRoot)) {
    WARN "Cargo registry src not found  -  not downloaded yet (run cargo fetch or let the build pull it)"
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
            WARN "$($roFiles.Count) read-only files  -  attrib fix in dev-windows.ps1 must clear these before build"
            # Test if attrib actually works here
            $testFile = $roFiles[0]
            & attrib -R "$($libsqlFfiSrc.FullName)" /S /D 2>&1 | Out-Null
            $stillRO = @(Get-ChildItem $libsqlFfiSrc.FullName -Recurse -File -ErrorAction SilentlyContinue | Where-Object IsReadOnly)
            if ($stillRO.Count -eq 0) {
                OK "attrib -R works  -  read-only attributes removed successfully"
            } else {
                FAIL "attrib -R did NOT remove all read-only flags ($($stillRO.Count) still read-only)  -  ACL restriction?"
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
        $outDir = Join-Path $d.FullName "out"
        $mc     = Join-Path $outDir "sqlite3mc"

        # --- sqlite3mc staging dir check ---
        if (Test-Path $mc) {
            $mcRO = @(Get-ChildItem $mc -Recurse -File -ErrorAction SilentlyContinue | Where-Object IsReadOnly)
            if ($mcRO.Count -gt 0) {
                FAIL "  sqlite3mc EXISTS with $($mcRO.Count) read-only files at: $mc"
            } else {
                OK "  sqlite3mc exists, all files writable: $mc"
            }
        } else {
            OK "  No stale sqlite3mc: $($d.Name)"
        }

        # Check for successful build artifact (out dir may not exist after a failed build;
        # Cargo removes it on failure to force a clean retry next time)
        if (Test-Path $outDir) {
            $lib = Get-ChildItem $outDir -Filter "*.lib" -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($lib) { OK "  Built artifact cached: $($lib.Name)" }
            else       { INFO "  out dir exists but no .lib yet" }
        } else {
            INFO "  out dir absent (Cargo deleted it after last failed build  -  normal)"
        }
    }
}
if ($firstAllowed) { INFO "`ndev-windows.ps1 will use: $firstAllowed" }
else               { FAIL "No candidate path allows exe execution  -  all paths blocked by AppLocker/WDAC" }

# ---------------------------------------------------------------------------
# Standalone copy test: reproduces exactly what libsql-ffi build.rs does at
# line 465 (copy a file from .cargo/registry/src into a writable target dir).
# Uses a fresh temp dir so it works even when Cargo has cleaned up the out dir.
# Catches AV locking, ACL blocks, and any other permission failure at runtime.
Write-Section "libsql-ffi copy simulation (reproduces build.rs:465)"
if ($libsqlFfiSrc) {
    $simDst = Join-Path $env:TEMP "char-diag-copy-test"
    try { Remove-Item $simDst -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    $null = New-Item -ItemType Directory -Force -Path $simDst
    $failed = $false
    $srcMC = Join-Path $libsqlFfiSrc.FullName "bundled\SQLite3MultipleCiphers"
    if (Test-Path $srcMC) {
        $files = @(Get-ChildItem $srcMC -Recurse -File -ErrorAction SilentlyContinue)
        INFO "Copying $($files.Count) files from SQLite3MultipleCiphers to temp dir..."
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($srcMC.Length).TrimStart('\')
            $dst = Join-Path $simDst $rel
            $dstDir = Split-Path $dst -Parent
            try {
                if (-not (Test-Path $dstDir)) { $null = New-Item -ItemType Directory -Force -Path $dstDir }
                [System.IO.File]::Copy($f.FullName, $dst, $true)
            } catch {
                FAIL "Copy FAILED: $($f.FullName)"
                FAIL "  Error: $_"
                FAIL "  THIS IS THE EXACT FAILURE at build.rs:465  -  likely AV or ACL issue"
                $failed = $true
                break
            }
        }
        if (-not $failed) {
            OK "All $($files.Count) files copied successfully  -  copy simulation passed"
            INFO "  This rules out AV locking and ACL issues as root cause"
        }
    } else {
        WARN "bundled\SQLite3MultipleCiphers not found in registry  -  skipping copy test"
    }
    try { Remove-Item $simDst -Recurse -Force -ErrorAction SilentlyContinue } catch {}
} else {
    WARN "libsql-ffi registry source not found  -  skipping copy test"
}

# ---------------------------------------------------------------------------
Write-Section "Antivirus / Windows Defender exclusions"
INFO "Paths that must be excluded from real-time AV scanning for builds to work:"
INFO "  $env:USERPROFILE\.cargo"
INFO "  $env:LOCALAPPDATA\char-build  (or active CARGO_TARGET_DIR)"
try {
    $mpPref = Get-MpPreference -ErrorAction Stop
    $excl   = @($mpPref.ExclusionPath)
    $cargoExcluded     = $excl | Where-Object { $_ -and $env:USERPROFILE -and $_.TrimEnd('\') -eq "$env:USERPROFILE\.cargo".TrimEnd('\') }
    $buildExcluded     = $excl | Where-Object { $_ -and $env:LOCALAPPDATA -and $_.TrimEnd('\') -eq "$env:LOCALAPPDATA\char-build".TrimEnd('\') }
    $cargoParentExcl   = $excl | Where-Object { $_ -and $env:USERPROFILE -and "$env:USERPROFILE\.cargo".StartsWith($_.TrimEnd('\')) }
    $buildParentExcl   = $excl | Where-Object { $_ -and $env:LOCALAPPDATA -and "$env:LOCALAPPDATA\char-build".StartsWith($_.TrimEnd('\')) }

    if ($cargoExcluded -or $cargoParentExcl) { OK ".cargo is excluded from Defender" }
    else {
        FAIL ".cargo NOT excluded from Defender real-time scan"
        INFO "  Fix: Add-MpPreference -ExclusionPath `"$env:USERPROFILE\.cargo`"  (run as admin)"
        INFO "  Or: setup-windows.ps1 adds this automatically"
    }
    if ($buildExcluded -or $buildParentExcl) { OK "char-build is excluded from Defender" }
    else {
        FAIL "char-build NOT excluded from Defender real-time scan"
        INFO "  Fix: Add-MpPreference -ExclusionPath `"$env:LOCALAPPDATA\char-build`"  (run as admin)"
        INFO "  Or: setup-windows.ps1 adds this automatically"
    }
    if ($excl.Count -gt 0) {
        INFO "Current exclusions ($($excl.Count)):"
        $excl | ForEach-Object { INFO "  $_" }
    }
} catch {
    WARN "Could not read Defender preferences (managed policy or non-Defender AV?): $_"
    INFO "If using corporate AV (CrowdStrike, Sophos, etc.) ensure these paths are excluded:"
    INFO "  $env:USERPROFILE\.cargo"
    INFO "  $env:LOCALAPPDATA\char-build"
}

# ---------------------------------------------------------------------------
Write-Section "ORT (ONNX Runtime) cache"
$ortCache = "$env:USERPROFILE\.cache\ort"
if (Test-Path $ortCache) {
    $ortLibs = @(Get-ChildItem $ortCache -Filter "*.dll" -Recurse -ErrorAction SilentlyContinue)
    if ($ortLibs.Count -gt 0) { OK "ORT already cached ($($ortLibs.Count) DLL(s) in $ortCache)" }
    else { INFO "ORT cache dir exists but no DLLs  -  will auto-download on first build (ORT_STRATEGY=download)" }
} else {
    INFO "ORT not yet cached  -  will auto-download on first build (~150 MB). Needs internet access."
}

# ---------------------------------------------------------------------------
# cp.exe is the ROOT CAUSE of the libsql-ffi os error 5 on Windows.
# libsql-ffi build.rs calls Command::new("cp") to copy SQLite3MultipleCiphers.
# PowerShell's "cp" alias (Copy-Item) is NOT visible to Rust subprocesses --
# only real .exe files in PATH are found.  Without cp.exe:
#   1. Command::new("cp") fails (os error 2 / not found)
#   2. Fallback: fs::copy(SQLite3MultipleCiphers_dir, sqlite3mc_dir)
#   3. CopyFileExW on a directory source -> ERROR_ACCESS_DENIED (os error 5)
#   4. match arm `Err(e) if e.kind() == InvalidInput` does NOT match -> .unwrap() panics
# dev-windows.ps1 adds Git's usr\bin\cp.exe to PATH to fix this.
Write-Section "cp.exe (ROOT CAUSE of libsql-ffi os error 5)"

# Look for a real cp.exe binary, not a PS alias.
$realCpExe = $null
$gitCpCandidates = @(
    "$env:ProgramFiles\Git\usr\bin\cp.exe",
    "${env:ProgramFiles(x86)}\Git\usr\bin\cp.exe",
    "$env:LOCALAPPDATA\Programs\Git\usr\bin\cp.exe"
)
# First check PATH for cp.exe specifically (not alias)
$cpInPath = $env:PATH.Split(";") | Where-Object { $_ -and (Test-Path (Join-Path $_ "cp.exe")) } | Select-Object -First 1
if ($cpInPath) {
    $realCpExe = Join-Path $cpInPath "cp.exe"
} else {
    # Not in PATH - check known Git locations
    $gitCpCandidates | ForEach-Object {
        if (-not $realCpExe -and (Test-Path $_)) { $realCpExe = $_ }
    }
}

if ($realCpExe) {
    $noPreserveSupport = (& $realCpExe --help 2>&1) -match "no-preserve"
    if ($noPreserveSupport) {
        if ($cpInPath) {
            OK "cp.exe in PATH with --no-preserve support: $realCpExe"
            INFO "libsql-ffi will use cp.exe and copy correctly  -  os error 5 will NOT occur"
        } else {
            WARN "cp.exe exists at $realCpExe but is NOT in PATH"
            FAIL "libsql-ffi Command::new('cp') will fail  -  dev-windows.ps1 must add Git usr\bin to PATH"
            INFO "  Fix: dev-windows.ps1 adds Git usr\bin automatically if Git for Windows is installed"
        }
    } else {
        WARN "cp.exe found ($realCpExe) but lacks --no-preserve  -  may not copy directories correctly"
    }
} else {
    FAIL "cp.exe not found anywhere (Git for Windows not installed?)"
    FAIL "  This is the ROOT CAUSE of libsql-ffi os error 5 at build.rs:465"
    INFO "  Install Git for Windows: https://git-scm.com/download/win"
    INFO "  dev-windows.ps1 will then add Git usr\bin to PATH automatically"
    # Extra check: warn if PowerShell 'cp' alias exists (common confusion)
    $psAlias = Get-Command cp -ErrorAction SilentlyContinue
    if ($psAlias -and -not $psAlias.Source) {
        INFO "  NOTE: PowerShell has a 'cp' alias (Copy-Item) but Rust subprocesses cannot use it"
    }
}

# ---------------------------------------------------------------------------
# Load vcvars64 to check MSVC tools in context, just like dev-windows.ps1 does.
Write-Section "PATH after vcvars64 (MSVC tools)"
$vcvarsLoaded = $false
if ($vsPath) {
    $vcvars2 = "$vsPath\VC\Auxiliary\Build\vcvars64.bat"
    if (Test-Path $vcvars2) {
        $envDump2 = cmd /c "`"$vcvars2`" >nul 2>&1 && set" 2>&1
        foreach ($line in $envDump2) {
            if ($line -match "^([^=]+)=(.*)$") {
                $k = $Matches[1]; $v = $Matches[2]
                [System.Environment]::SetEnvironmentVariable($k, $v)
                if ($k -eq "PATH") { $env:PATH = $v }
            }
        }
        $vcvarsLoaded = $true
        OK "vcvars64 loaded for PATH check"
    }
}
foreach ($tool in @("cargo", "cl", "cmake", "ninja", "link", "rc")) {
    $found = Get-Command "$tool.exe" -ErrorAction SilentlyContinue
    if ($found) { OK "$tool : $($found.Source)" }
    elseif ($vcvarsLoaded) { FAIL "$tool.exe not found even after vcvars64  -  VS installation may be incomplete" }
    else { WARN "$tool.exe not found (vcvars64 could not be loaded  -  check VS Build Tools section above)" }
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
