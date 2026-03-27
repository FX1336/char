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
$LLVM_DIR = "$HOME\.local\llvm"

# Ensure tools installed by setup-windows.ps1 are on PATH.
# MinGW bin must be here for the Rust GNU linker (x86_64-w64-mingw32-gcc, ld, etc.)
# and as the C/C++ compiler for cc-rs and cmake (whisper-rs-sys, libsql-ffi, etc.).
$env:PATH = "$MINGW_DIR\bin;$LOCAL_BIN;$env:USERPROFILE\.cargo\bin;$env:PATH"

# Use MinGW GCC/G++ as the C/C++ compiler for cc-rs and cmake.
# MinGW g++ compiles with libstdc++ (std:: namespace); whisper-rs-sys hard-codes
# cargo:rustc-link-lib=dylib=stdc++ so the toolchain is consistent end-to-end.
# llvm-mingw clang++ uses LLVM libc++ (std::__1:: namespace) which is incompatible
# with MinGW's libstdc++ at link time — hence we avoid clang++ for C++ compilation.
$env:LIBCLANG_PATH = "$LLVM_DIR\bin"   # libclang.dll lives here (for bindgen)
$env:CC  = "$MINGW_DIR\bin\x86_64-w64-mingw32-gcc.exe"
$env:CXX = "$MINGW_DIR\bin\x86_64-w64-mingw32-g++.exe"
# cmake toolchain file: cmake-rs reads CMAKE_TOOLCHAIN_FILE and passes it as
# -DCMAKE_TOOLCHAIN_FILE to every cmake invocation (whisper-rs-sys, libsql-ffi, etc.).
# The file (apps/desktop/src-tauri/cmake/windows-gnu.cmake):
#   1. Sets CMAKE_C/CXX_COMPILER from env — cmake-rs intentionally skips this on
#      non-MSVC Windows, so cmake would otherwise auto-detect gcc.exe from PATH.
#   2. Strips /utf-8 from cmake flags — whisper-rs-sys adds it unconditionally on
#      Windows but GCC treats it as a filename, not a flag.
#   3. Strips --target=... from cmake flags — whisper-rs-sys injects this
#      clang-specific flag unconditionally; GCC does not accept it.
$env:CMAKE_C_COMPILER   = "$MINGW_DIR\bin\x86_64-w64-mingw32-gcc.exe"
$env:CMAKE_CXX_COMPILER = "$MINGW_DIR\bin\x86_64-w64-mingw32-g++.exe"
$toolchainFile = ($REPO_ROOT -replace '\\', '/') + "/apps/desktop/src-tauri/cmake/windows-gnu.cmake"
$env:CMAKE_TOOLCHAIN_FILE = $toolchainFile

# cmake_project_include_before: loaded before every project() call in the build
# tree.  Our script defers a fix that sets PREFIX "lib" on ggml targets after all
# targets are defined (overriding ggml/CMakeLists.txt's WIN32 set(CMAKE_STATIC_LIBRARY_PREFIX "")).
# Without this, cmake generates ggml.a instead of libggml.a and GNU ld can't find it.
$prefixFix = ($REPO_ROOT -replace '\\', '/') + "/apps/desktop/src-tauri/cmake/whisper-gnu-ggml-prefix.cmake"
$env:CMAKE_PROJECT_INCLUDE_BEFORE = $prefixFix

# Bindgen (libclang.dll from PyPI libclang 18.x) needs to find clang built-in
# headers (stdbool.h, stdint.h) and MinGW system headers.  The PyPI libclang is a
# different LLVM version from llvm-mingw, so its default resource-dir lookup fails.
# Point it explicitly at llvm-mingw's resource dir and MinGW include path.
$clangResourceDir = Get-ChildItem -Path "$LLVM_DIR\lib\clang" -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name | Select-Object -Last 1
$llvmSlash = $LLVM_DIR -replace '\\', '/'
if ($clangResourceDir) {
    $resDir = ($clangResourceDir.FullName -replace '\\', '/')
    $env:BINDGEN_EXTRA_CLANG_ARGS_x86_64_pc_windows_gnu = `
        "--target=x86_64-w64-mingw32 -resource-dir $resDir -isystem $llvmSlash/x86_64-w64-mingw32/include"
} else {
    $env:BINDGEN_EXTRA_CLANG_ARGS_x86_64_pc_windows_gnu = `
        "--target=x86_64-w64-mingw32 --sysroot=$llvmSlash/x86_64-w64-mingw32"
}

# ONNX Runtime: point ort-sys to our pre-converted MinGW import library.
# ORT_PREFER_DYNAMIC_LINK prevents ort-sys from looking for a static .lib.
# Adding the lib dir to PATH makes onnxruntime.dll findable at runtime.
$ORT_DIR = "$HOME\.local\onnxruntime"
$env:ORT_LIB_LOCATION = $ORT_DIR
$env:ORT_PREFER_DYNAMIC_LINK = "1"
$env:PATH = "$ORT_DIR\lib;$env:PATH"

# CARGO_TARGET_DIR: AppLocker/WDAC policies (os error 4551) block execution of
# unsigned build-script binaries from certain paths.  Try candidate paths in
# order; use the first one that is not on a blocked volume/path.
# Precedence: env override > AppData\Local > TEMP > default (.cargo\target).
if ($env:CHAR_TARGET_DIR) {
    $env:CARGO_TARGET_DIR = $env:CHAR_TARGET_DIR
    Write-Host "  CARGO_TARGET_DIR (override): $env:CARGO_TARGET_DIR"
} else {
    # AppData\Local is often whitelisted by path-based AppLocker EXE rules.
    $env:CARGO_TARGET_DIR = "$env:LOCALAPPDATA\char-build"
    Write-Host "  CARGO_TARGET_DIR: $env:CARGO_TARGET_DIR"
    Write-Host "  (set CHAR_TARGET_DIR env var to override if still blocked)"
}

# cmake verbose makefile: causes make to print every compiler invocation.
# When a cmake build FAILS, cargo captures and displays the full build script
# output including these lines, making it easier to diagnose compile errors.
# (Has no effect when the build succeeds.)
$env:CMAKE_VERBOSE_MAKEFILE = "ON"

# Clear stale cmake caches that would cause build failures:
#   - C compiler cached as gcc  (toolchain file couldn't override the old cache)
#   - CXX compiler marked broken (happened when /utf-8 caused clang test to fail)
# Deleting the cmake build sub-directory forces a fresh configure on next cargo build.
# Also invalidates cargo's fingerprint so cargo re-runs the build script and regenerates
# the rustc-link-search metadata pointing into the new cmake build tree.
$expectedCCompiler = ($MINGW_DIR -replace '\\', '/') + "/bin/x86_64-w64-mingw32-gcc.exe"
$cargoBuildDir = Join-Path $REPO_ROOT "apps\desktop\src-tauri\target\debug\build"
$fingerprintBaseDir = Join-Path (Split-Path $cargoBuildDir) ".fingerprint"
if (Test-Path -LiteralPath $cargoBuildDir) {
    Get-ChildItem -LiteralPath $cargoBuildDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $cmakeCache = Join-Path $_.FullName "out\build\CMakeCache.txt"
        if (Test-Path -LiteralPath $cmakeCache) {
            $cacheText = Get-Content -LiteralPath $cmakeCache -Raw -ErrorAction SilentlyContinue
            $gccCached     = $false   # we now expect MinGW gcc; no longer a problem
            $cxxBroken     = $cacheText -match "CMAKE_CXX_COMPILER_WORKS:INTERNAL=(0|FALSE)"
            $wrongCompiler = ($cacheText -notmatch [regex]::Escape($expectedCCompiler)) -and
                             ($cacheText -match "CMAKE_C_COMPILER:FILEPATH=")
            if ($gccCached -or $cxxBroken -or $wrongCompiler) {
                $label = $_.Name.Substring(0, [Math]::Min(40, $_.Name.Length))
                Write-Host "    Clearing stale cmake cache: $label..."
                # Delete cmake build dir so cmake-rs reconfigures from scratch.
                Remove-Item -LiteralPath (Join-Path $_.FullName "out\build") -Recurse -Force -ErrorAction SilentlyContinue
                # Also delete cargo's fingerprint for this crate.  Without this,
                # cargo reuses cached rustc-link-search paths that pointed into
                # the now-deleted cmake build tree, causing a link-time "library
                # not found" error even though cmake will rebuild successfully.
                $cratePrefix = $_.Name -replace '-[0-9a-fA-F]+$', ''
                if (Test-Path -LiteralPath $fingerprintBaseDir) {
                    Get-ChildItem -LiteralPath $fingerprintBaseDir -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like "$cratePrefix-*" } |
                        ForEach-Object {
                            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        }
                }
            }
        }
    }
}

# Safety net for whisper-rs-sys.
# whisper-rs-sys build.rs doesn't declare rerun-if-env-changed for
# CMAKE_TOOLCHAIN_FILE / CMAKE_C_COMPILER, so cargo caches the build
# script output (rustc-link-search paths) indefinitely even when the
# cmake configuration changes.  We unconditionally clear the fingerprint
# so cargo always re-runs the build script, cmake re-configures
# (always_configure=true), and fresh link-search paths are emitted.
# cmake build itself is still incremental: if nothing changed, it only
# takes a few seconds.
#
# In addition, if cmake ran but libggml.a is absent (Scenario A) or the
# cmake build dir was wiped while a fingerprint survived (Scenario B),
# also delete the cmake build tree so cmake starts from scratch.
if (Test-Path -LiteralPath $cargoBuildDir) {
    Get-ChildItem -LiteralPath $cargoBuildDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^whisper-rs-sys-" } |
        ForEach-Object {
            $cmakeOut    = Join-Path $_.FullName "out\build"
            $cacheFile   = Join-Path $cmakeOut "CMakeCache.txt"
            $cratePrefix = $_.Name -replace '-[0-9a-fA-F]+$', ''

            $cacheExists = Test-Path -LiteralPath $cacheFile
            # Search the full crate out/ tree (not just out/build/) so we find
            # libggml.a whether cmake put it in out/ (CMAKE_ARCHIVE_OUTPUT_DIRECTORY)
            # or in out/build/ggml/src/ (default cmake layout).
            $hasGgml = $cacheExists -and [bool](
                Get-ChildItem -LiteralPath $_.FullName -Filter "libggml.a" -Recurse -ErrorAction SilentlyContinue |
                    Select-Object -First 1)

            # Scenario C: cmake cache has stale -stdlib=libstdc++ or a clang compiler
            # path (from a previous failed attempt with llvm-mingw clang++).
            # Clear so it reconfigures with the current MinGW g++ toolchain.
            $scenarioC = $false
            if ($cacheExists) {
                $ct = Get-Content -LiteralPath $cacheFile -Raw -ErrorAction SilentlyContinue
                if ($ct -and (
                    ($ct -match "-stdlib=libstdc\+\+") -or
                    ($ct -match "clang(?:\+\+)?\.exe") -or
                    ($ct -notmatch [regex]::Escape($expectedCCompiler) -and
                     $ct -match "CMAKE_C_COMPILER:FILEPATH=")
                )) { $scenarioC = $true }
            }

            # Scenario A: cmake ran but the compiled library is absent anywhere
            # Scenario B: cmake dir was wiped but a fingerprint survived
            $scenarioA = $cacheExists -and (-not $hasGgml)
            $scenarioB = (-not $cacheExists)

            if ($scenarioA -or $scenarioB -or $scenarioC) {
                $reason = if ($scenarioA) { "cmake built but libggml.a missing" } `
                     elseif ($scenarioC) { "cmake cache has stale clang path or flags -- reconfiguring with MinGW g++" } `
                          else            { "cmake dir absent -- will build from scratch" }
                Write-Host "    whisper-rs-sys: $reason" -ForegroundColor Yellow
                if (Test-Path -LiteralPath $cmakeOut) {
                    Remove-Item -LiteralPath $cmakeOut -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            # Always clear fingerprint so cargo re-runs the build script and emits
            # fresh rustc-link-search paths that reflect the current cmake output.
            if (Test-Path -LiteralPath $fingerprintBaseDir) {
                Get-ChildItem -LiteralPath $fingerprintBaseDir -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "$cratePrefix-*" } |
                    ForEach-Object {
                        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
            }
        }
}

# Diagnostic: always report whisper-rs-sys build state so failures are visible.
Write-Host "`n==> whisper-rs-sys build state" -ForegroundColor Cyan
if (Test-Path -LiteralPath $cargoBuildDir) {
    $wrsAll = @(Get-ChildItem -LiteralPath $cargoBuildDir -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match "^whisper-rs-sys-" })
    if ($wrsAll.Count -eq 0) {
        Write-Host "    (no build dir yet -- will be created on first cargo build)"
    }
    foreach ($d in $wrsAll) {
        $cmakeOut  = Join-Path $d.FullName "out\build"
        $hasCache  = Test-Path -LiteralPath (Join-Path $cmakeOut "CMakeCache.txt")
        $ggmls     = @(Get-ChildItem -LiteralPath $d.FullName -Filter "libggml.a" -Recurse -ErrorAction SilentlyContinue)
        $fpCount   = 0
        if (Test-Path -LiteralPath $fingerprintBaseDir) {
            $pfx     = $d.Name -replace '-[0-9a-fA-F]+$', ''
            $fpCount = @(Get-ChildItem -LiteralPath $fingerprintBaseDir -Directory -ErrorAction SilentlyContinue |
                             Where-Object { $_.Name -like "$pfx-*" }).Count
        }
        $short = $d.Name.Substring(0, [Math]::Min(44, $d.Name.Length))
        Write-Host "    $short"
        Write-Host "      cmake cache : $(if ($hasCache) { 'present' } else { 'absent' })"
        Write-Host "      libggml.a   : $(if ($ggmls.Count -gt 0) { $ggmls[0].FullName } else { 'NOT FOUND' })"
        Write-Host "      fingerprints: $fpCount"
    }
} else {
    Write-Host "    target/debug/build/ not yet created"
}


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

if (-not (Test-Path "$ORT_DIR\lib\libonnxruntime.dll.a")) {
    Write-Fail "ONNX Runtime MinGW import library missing. Run .\scripts\setup-windows.ps1 first."
}
Write-Host "    ort     $ORT_DIR\lib\libonnxruntime.dll.a"

if (-not (Test-Path "$LLVM_DIR\bin\x86_64-w64-mingw32-clang.exe")) {
    Write-Fail "llvm-mingw not found at $LLVM_DIR. Run .\scripts\setup-windows.ps1 first."
}
Write-Host "    llvm-mingw  $LLVM_DIR\bin\x86_64-w64-mingw32-clang.exe"

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
$devExitCode = $LASTEXITCODE
Pop-Location

if ($devExitCode -ne 0) {
    Write-Host "`n==> Build failed -- whisper-rs-sys artifact locations" -ForegroundColor Yellow
    $innerBuildDir = Join-Path $REPO_ROOT "apps\desktop\src-tauri\target\debug\build"
    if (Test-Path -LiteralPath $innerBuildDir) {
        $wrsDirs = @(Get-ChildItem -LiteralPath $innerBuildDir -Directory -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -match "^whisper-rs-sys-" })
        foreach ($d in $wrsDirs) {
            $aFiles = @(Get-ChildItem -LiteralPath $d.FullName -Filter "*.a" -Recurse -ErrorAction SilentlyContinue)
            Write-Host "  $($d.Name):"
            if ($aFiles.Count -eq 0) {
                Write-Host "    (no .a files found -- cmake did not produce libraries)"
            } else {
                foreach ($f in $aFiles) { Write-Host "    $($f.FullName)" }
            }
        }
    } else {
        Write-Host "  target/debug/build/ does not exist"
    }
    exit $devExitCode
}
