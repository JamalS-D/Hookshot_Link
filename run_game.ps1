param(
    [string]$Nup  = "C:\Users\jamal\Downloads\The Legend of Zelda Ocarina of Time [0400486024DEC000][v131072].nup",
    [string]$Out  = "",
    [int]$Jobs    = 8
)

$ErrorActionPreference = "Stop"
$Repo = $PSScriptRoot
if (-not $Out) {
    $Out = Join-Path $Repo "game"
}

if (-not (Test-Path -LiteralPath $Nup)) {
    throw "ROM (.nup) file not found at: $Nup"
}

# 1. Locate or install the Hookshot Builder toolchain in %LOCALAPPDATA%\HookshotBuilder
$Base      = Join-Path $env:LOCALAPPDATA "HookshotBuilder"
$Downloads = Join-Path $Base "downloads"
$Versions  = Join-Path $Base "versions"
New-Item -ItemType Directory -Force -Path $Downloads, $Versions | Out-Null

$Tools = Get-ChildItem -Path $Versions -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object { (Join-Path $_.FullName "HookshotBuilder\tools"), (Join-Path $_.FullName "tools") } |
    Where-Object {
        (Test-Path (Join-Path $_ "llvm-mingw\bin\clang.exe")) -and
        (Test-Path (Join-Path $_ "cpm"))
    } |
    Select-Object -First 1

if (-not $Tools) {
    Write-Host "==> Downloading Hookshot Builder toolchain into $Base ..." -ForegroundColor Cyan
    $ManifestPath = Join-Path $Downloads "hookshot-setup.txt"
    & curl.exe -fL --retry 3 -o $ManifestPath "https://github.com/NotRexed/Hookshot/releases/latest/download/hookshot-setup.txt"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $ManifestPath)) {
        throw "Failed to download hookshot-setup.txt from GitHub."
    }

    $Lines = Get-Content -Path $ManifestPath -Encoding UTF8
    $TagLine = $Lines | Where-Object { $_ -match "^tag\s+" } | Select-Object -First 1
    if (-not $TagLine) {
        throw "Invalid hookshot-setup.txt manifest (missing 'tag' line)."
    }
    $Tag = ($TagLine -split "\s+")[1].Trim()
    $Install = Join-Path $Versions $Tag
    New-Item -ItemType Directory -Force -Path $Install | Out-Null

    $PartLines = $Lines | Where-Object { $_ -match "^part\s+" }
    $Idx = 0
    foreach ($Line in $PartLines) {
        $Idx++
        $p = ($Line.Trim() -split "\s+")
        $sha     = $p[1]
        $sizeMB  = [math]::Round(([int64]$p[2]) / 1MB, 1)
        $destRel = $p[3]
        $from    = $p[4]
        $to      = $p[5]
        $url     = $p[6]
        $leaf    = Split-Path $url -Leaf

        # Skip dotnet and emsdk archives if llvm-mingw is used (saves ~186 MB download)
        if ($leaf -like "*dotnet*" -or $leaf -like "*emsdk*") {
            continue
        }

        $zip = Join-Path $Downloads "$sha.zip"
        $needDownload = $true
        if (Test-Path $zip) {
            $actualHash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualHash -eq $sha.ToLowerInvariant()) {
                $needDownload = $false
            }
        }
        if ($needDownload) {
            Write-Host "  [$Idx/$($PartLines.Count)] Downloading $leaf ($sizeMB MB) ..." -ForegroundColor Yellow
            & curl.exe -fL --retry 3 -o $zip $url
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to download $url"
            }
        } else {
            Write-Host "  [$Idx/$($PartLines.Count)] Using cached $leaf" -ForegroundColor DarkGray
        }

        $dest = if ($destRel -eq ".") { $Install } else { Join-Path $Install ($destRel -replace "/", "\") }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Write-Host "  [$Idx/$($PartLines.Count)] Extracting $leaf ..." -ForegroundColor Gray
        & "$env:SystemRoot\System32\tar.exe" -xf $zip -C $dest
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract $zip into $dest"
        }

        if ($from -ne "-" -and $to -ne "-") {
            $srcDir = Join-Path $dest $from
            $dstDir = Join-Path $dest $to
            if ((Test-Path $srcDir) -and -not (Test-Path $dstDir)) {
                Move-Item -Path $srcDir -Destination $dstDir
            }
        }
    }

    $Tools = Join-Path $Install "HookshotBuilder\tools"
    if (-not (Test-Path (Join-Path $Tools "llvm-mingw\bin\clang.exe"))) {
        throw "Toolchain installation incomplete: clang.exe not found under $Tools\llvm-mingw\bin"
    }
}

Write-Host "==> Using toolchain at: $Tools" -ForegroundColor Green

# 2. Overlay updated Vulkan & SM86 shader recompiler sources from this repo onto $Tools
Write-Host "==> Syncing updated Hookshot_Link sources (gpu/, nx2/, host/) into toolchain ..." -ForegroundColor Cyan
Copy-Item -Path (Join-Path $Repo "gpu\*")  -Destination (Join-Path $Tools "gpu")  -Recurse -Force
Copy-Item -Path (Join-Path $Repo "nx2\*")  -Destination (Join-Path $Tools "nx2")  -Recurse -Force
Copy-Item -Path (Join-Path $Repo "host\*") -Destination (Join-Path $Tools "host") -Recurse -Force

# 3. Configure environment and build the game
$env:HOOKSHOT_MINGW = Join-Path $Tools "llvm-mingw"
$env:RX_CPM         = Join-Path $Tools "cpm"
$env:WGPU_NATIVE    = Join-Path $Tools "wgpu-native"

$Py = Join-Path $Tools "python\python.exe"
if (-not (Test-Path $Py)) {
    $Py = "python"
}

Write-Host "==> Building game from '$Nup' into '$Out' (jobs=$Jobs) ..." -ForegroundColor Cyan
Push-Location $Tools
try {
    & $Py -I (Join-Path $Tools "nx2\make_game.py") --nup $Nup --out $Out --jobs $Jobs
    $BuildExit = $LASTEXITCODE
} finally {
    Pop-Location
}

$ExePath = Join-Path $Out "hookshot.exe"
if ($BuildExit -ne 0 -or -not (Test-Path $ExePath)) {
    throw "Build did not finish successfully (exit code $BuildExit)."
}

# 4. Launch hookshot.exe with full Vulkan diagnostics and stream hookshot_log.txt live
$FailedShadersDir = Join-Path $Out "failed_shaders"
New-Item -ItemType Directory -Force -Path $FailedShadersDir | Out-Null
$env:RX_VK_CHECKPOINTS = "1"
$env:RX_VK_DUMP_FAILED = $FailedShadersDir

$LogPath = Join-Path $Out "hookshot_log.txt"
Remove-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue

Write-Host "==> Launching $ExePath with Vulkan diagnostics enabled ..." -ForegroundColor Green
$proc = Start-Process -FilePath $ExePath -WorkingDirectory $Out -PassThru
while (-not (Test-Path -LiteralPath $LogPath) -and -not $proc.HasExited) {
    Start-Sleep -Milliseconds 200
}
if (Test-Path -LiteralPath $LogPath) {
    Write-Host "==> Streaming $LogPath (Press Ctrl+C to stop log stream) ..." -ForegroundColor Cyan
    Get-Content -LiteralPath $LogPath -Wait
} else {
    Write-Warning "hookshot.exe exited (code $($proc.ExitCode)) before creating hookshot_log.txt."
}
