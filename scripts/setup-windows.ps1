#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up the Windows development environment for Char.
.DESCRIPTION
    Installs Visual Studio Build Tools 2022, Rust (MSVC), libclang,
    fnm, Node.js 22, pnpm, and project dependencies.
    Requires administrator privileges for Visual Studio Build Tools.
    Run once after cloning the repository.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\setup-windows.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$REPO_ROOT  = Split-Path $PSScriptRoot -Parent
$RUST_VERSION = "1.94.0"
$NODE_VERSION = "22"
$LOCAL_BIN  = "$HOME\.local\bin"
$LIBCLANG_DIR = "$HOME\.local\libclang"

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

New-Item -ItemType Directory -Force -Path $LOCAL_BIN    | Out-Null
New-Item -ItemType Directory -Force -Path $LIBCLANG_DIR | Out-Null

# -- Admin check ---------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  ERROR: Administrator privileges required." -ForegroundColor Red
    Write-Host "  Right-click PowerShell and choose 'Run as administrator'," -ForegroundColor Yellow
    Write-Host "  then run this script again." -ForegroundColor Yellow
    exit 1
}

# -- WebView2 ------------------------------------------------------------------
Write-Step "WebView2 Runtime"
$wv2 = Get-ItemProperty `
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" `
    -ErrorAction SilentlyContinue
if (-not $wv2) {
    $wv2 = Get-ItemProperty `
        "HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" `
        -ErrorAction SilentlyContinue
}
if ($wv2) {
    Write-Skip "WebView2 Runtime"
} else {
    Write-Host "    WebView2 not found -- usually pre-installed on Windows 10/11." -ForegroundColor Yellow
    Write-Host "    If the app fails to start, download from:" -ForegroundColor Yellow
    Write-Host "    https://developer.microsoft.com/microsoft-edge/webview2/" -ForegroundColor Yellow
}

# -- Visual Studio Build Tools 2022 -------------------------------------------
# Provides: cl.exe (MSVC compiler), Windows SDK, cmake, ninja, MSBuild.
# No MinGW or separate compiler download needed.
Write-Step "Visual Studio Build Tools 2022"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstalled = $false
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -requires Microsoft.VisualStudio.Workload.VCTools `
        -property installationPath 2>$null
    $vsInstalled = ($null -ne $vsPath -and $vsPath -ne "")
}
if ($vsInstalled) {
    Write-Skip "VS Build Tools ($vsPath)"
} else {
    Write-Host "    Downloading VS Build Tools installer (~5 MB bootstrapper)..."
    $btInstaller = Join-Path $env:TEMP "vs_BuildTools.exe"
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_BuildTools.exe" -OutFile $btInstaller
    Write-Host "    Installing (this can take 5-10 minutes)..."
    $proc = Start-Process -FilePath $btInstaller -Wait -PassThru -ArgumentList @(
        "--quiet", "--wait", "--norestart",
        "--add", "Microsoft.VisualStudio.Workload.VCTools",
        "--add", "Microsoft.VisualStudio.Component.VC.CMake.Project",
        "--includeRecommended"
    )
    try { Remove-Item -LiteralPath $btInstaller -Force -ErrorAction SilentlyContinue } catch {}
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Write-Host "  ERROR: VS Build Tools installer exited with code $($proc.ExitCode)." -ForegroundColor Red
        Write-Host "  Check %TEMP%\dd_*.log for details." -ForegroundColor Yellow
        exit 1
    }
    Write-Ok "VS Build Tools 2022 installed"
}

# Refresh vswhere path after install
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -requires Microsoft.VisualStudio.Workload.VCTools `
        -property installationPath 2>$null
}
if (-not $vsPath) {
    Write-Host "  ERROR: VS Build Tools not found after installation." -ForegroundColor Red
    exit 1
}

# -- libclang.dll (from PyPI libclang wheel -- needed by bindgen) --------------
# Bindgen requires libclang.dll at build time.  The PyPI wheel is the easiest
# way to get it without installing the full LLVM suite.
Write-Step "libclang.dll (for bindgen)"
$libclangDll = "$LIBCLANG_DIR\libclang.dll"
if (-not (Test-Path $libclangDll)) {
    Write-Host "    Fetching libclang package info from PyPI..."
    $pypi  = Invoke-RestMethod "https://pypi.org/pypi/libclang/json"
    $wheel = $pypi.urls | Where-Object { $_.filename -match "win_amd64\.whl$" } | Select-Object -First 1
    if (-not $wheel) {
        Write-Host "  ERROR: Could not find libclang win_amd64 wheel on PyPI." -ForegroundColor Red
        exit 1
    }
    Write-Host "    Downloading $($wheel.filename) (~30 MB)..."
    $whlPath  = Join-Path $env:TEMP $wheel.filename
    Invoke-WebRequest -Uri $wheel.url -OutFile $whlPath
    $zipPath  = [System.IO.Path]::ChangeExtension($whlPath, ".zip")
    Copy-Item -LiteralPath $whlPath -Destination $zipPath -Force
    $whlExtract = Join-Path $env:TEMP "libclang-wheel"
    try { if (Test-Path $whlExtract) { Remove-Item $whlExtract -Recurse -Force } } catch {}
    Expand-Archive -LiteralPath $zipPath -DestinationPath $whlExtract -Force
    try { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item $whlPath -Force -ErrorAction SilentlyContinue } catch {}
    $dll = Get-ChildItem -LiteralPath $whlExtract -Filter "libclang.dll" -Recurse | Select-Object -First 1
    if (-not $dll) {
        Write-Host "  ERROR: libclang.dll not found in wheel archive." -ForegroundColor Red
        exit 1
    }
    Copy-Item -LiteralPath $dll.FullName -Destination $LIBCLANG_DIR -Force
    try { Remove-Item $whlExtract -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    Write-Ok "libclang.dll installed at $LIBCLANG_DIR"
} else {
    Write-Skip "libclang.dll"
}

# -- Rust toolchain (MSVC) -----------------------------------------------------
Write-Step "Rust toolchain"
if (-not (Test-Command "rustup")) {
    Write-Host "    Installing Rust via rustup-init..."
    $rustupInit = Join-Path $env:TEMP "rustup-init.exe"
    $rustupUrls = @(
        "https://win.rustup.rs/x86_64",
        "https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe"
    )
    $downloaded = $false
    foreach ($url in $rustupUrls) {
        try {
            Write-Host "    Trying $url ..."
            Invoke-WebRequest -Uri $url -OutFile $rustupInit -ErrorAction Stop
            $downloaded = $true
            break
        } catch {
            Write-Host "    Failed: $_"
        }
    }
    if (-not $downloaded) {
        Write-Host "  ERROR: Could not download rustup-init.exe." -ForegroundColor Red
        exit 1
    }
    & $rustupInit -y --default-toolchain "$RUST_VERSION" `
        --default-host x86_64-pc-windows-msvc `
        --component rust-analyzer,rustfmt,clippy
    try { Remove-Item -LiteralPath $rustupInit -Force -ErrorAction SilentlyContinue } catch {}
    $env:PATH = "$env:USERPROFILE\.cargo\bin;$env:PATH"
    Write-Ok "Rust $RUST_VERSION (MSVC) installed"
} else {
    Write-Skip "rustup"
    Write-Host "    Ensuring toolchain $RUST_VERSION-x86_64-pc-windows-msvc..."
    rustup toolchain install "$RUST_VERSION-x86_64-pc-windows-msvc" --component rust-analyzer,rustfmt,clippy
    rustup set default-host x86_64-pc-windows-msvc
    rustup default "$RUST_VERSION-x86_64-pc-windows-msvc"
    Write-Ok "Rust toolchain up to date"
}

# -- fnm (portable Node version manager) --------------------------------------
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
& $fnmExe env --shell powershell 2>$null | Out-String | Invoke-Expression

# -- Node.js -------------------------------------------------------------------
Write-Step "Node.js $NODE_VERSION"
$nodeOk = $false
if (Test-Command "node") {
    $v = (node --version) -replace "^v","" -split "\." | Select-Object -First 1
    if ([int]$v -ge [int]$NODE_VERSION) { $nodeOk = $true }
}
if (-not $nodeOk) {
    Write-Host "    Installing Node.js $NODE_VERSION via fnm..."
    & $fnmExe install $NODE_VERSION
    & $fnmExe env --shell powershell | Out-String | Invoke-Expression
    Write-Ok "Node.js $(node --version) installed"
} else {
    Write-Skip "Node.js $(node --version)"
}

# -- pnpm ----------------------------------------------------------------------
Write-Step "pnpm"
if (-not (Test-Command "pnpm")) {
    npm install -g pnpm
    Write-Ok "pnpm installed"
} else {
    Write-Skip "pnpm $(pnpm --version)"
}

# -- Project dependencies ------------------------------------------------------
Write-Step "Installing project dependencies"
Push-Location $REPO_ROOT
pnpm install --frozen-lockfile
Pop-Location
Write-Ok "pnpm install done"

# -- Build workspace packages that ship compiled output ------------------------
Write-Step "Building @hypr/ui (CSS)"
Push-Location $REPO_ROOT
pnpm -F "@hypr/ui" build
Pop-Location
Write-Ok "@hypr/ui built"

# -- Summary -------------------------------------------------------------------
Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
Write-Host ""
Write-Host "Optional: add to your PowerShell profile (notepad `$PROFILE):" -ForegroundColor White
Write-Host "  `$env:PATH = `"$LOCAL_BIN;`$env:USERPROFILE\.cargo\bin;`$env:PATH`"" -ForegroundColor Yellow
Write-Host "  fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next step:" -ForegroundColor White
Write-Host "  powershell -ExecutionPolicy Bypass -File .\scripts\dev-windows.ps1" -ForegroundColor Yellow
Write-Host ""
