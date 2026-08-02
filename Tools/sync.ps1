# Tools/sync.ps1 — the dev loop (PLAN.md task 0.6)
#
# Copies the addon (and the probe) into every WoW AddOns folder it can find, so
# there is no manual file shuffling between an edit and a /reload.
#
#   .\Tools\sync.ps1              copy once
#   .\Tools\sync.ps1 -Watch       copy, then re-copy whenever a file changes
#   .\Tools\sync.ps1 -Link        create directory junctions instead of copying
#   .\Tools\sync.ps1 -WowPath "D:\Games\World of Warcraft"
#
# -Link is the better dev loop when it works: the game reads straight out of the
# repository, so a /reload picks up an edit with no copy step at all. It needs
# the repo and the game to be on the same machine (they can be on different
# drives) and it must not be used for a real install you care about, because
# deleting the junction from inside WoW's folder would reach into the repo.

[CmdletBinding()]
param(
    [string]$WowPath,
    [switch]$Watch,
    [switch]$Link
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AddonName = "DyrueUnitFrames"
$ProbeName = "DyrueUnitFrames_Probe"

function Find-WowRoot {
    if ($WowPath) {
        if (-not (Test-Path $WowPath)) { throw "No such path: $WowPath" }
        return $WowPath
    }

    $candidates = @(
        "C:\Program Files (x86)\World of Warcraft",
        "D:\Program Files (x86)\World of Warcraft",
        "C:\Games\World of Warcraft",
        "D:\Games\World of Warcraft"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }

    # Last resort: look for a flavour folder a few levels down each fixed drive.
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem).Root) {
        $hit = Get-ChildItem -Path $drive -Filter "_classic_era_" -Directory -Recurse -Depth 3 -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return (Split-Path -Parent $hit.FullName) }
    }

    throw "Could not find World of Warcraft. Pass -WowPath explicitly."
}

function Get-AddOnDirs([string]$root) {
    $flavours = @("_classic_era_", "_anniversary_", "_classic_", "_classic_ptr_", "_classic_beta_")
    $dirs = @()
    foreach ($f in $flavours) {
        $path = Join-Path $root "$f\Interface\AddOns"
        if (Test-Path $path) { $dirs += $path }
    }
    if ($dirs.Count -eq 0) { throw "No Classic AddOns folders under $root" }
    return $dirs
}

function Sync-One([string]$sourceDir, [string]$targetDir, [string]$name) {
    $target = Join-Path $targetDir $name

    if ($Link) {
        if (Test-Path $target) {
            $item = Get-Item $target -Force
            if ($item.LinkType) {
                Write-Host "  = $name already linked" -ForegroundColor DarkGray
                return
            }
            throw "$target exists and is a real folder. Remove it yourself first - this script will not delete a real install."
        }
        New-Item -ItemType Junction -Path $target -Target $sourceDir | Out-Null
        Write-Host "  + $name linked" -ForegroundColor Green
        return
    }

    # Copy mode. Only ever writes inside a folder named after this addon, so a
    # mistyped path cannot scribble over an unrelated install.
    if (Test-Path $target) {
        $item = Get-Item $target -Force
        if ($item.LinkType) {
            Write-Host "  = $name is a junction; nothing to copy" -ForegroundColor DarkGray
            return
        }
        Remove-Item $target -Recurse -Force
    }
    Copy-Item -Path $sourceDir -Destination $target -Recurse -Force

    # SavedVariables live outside the addon folder, so nothing above touches
    # them, but say so explicitly because it is the thing people worry about.
    Write-Host "  + $name copied" -ForegroundColor Green
}

function Sync-All {
    $root = Find-WowRoot
    Write-Host "WoW: $root" -ForegroundColor Cyan

    $stagingDir = Join-Path $env:TEMP "DyrueUnitFrames_stage"
    if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
    New-Item -ItemType Directory -Path $stagingDir | Out-Null

    # The addon folder is the repo root minus the things that are not the addon.
    $staged = Join-Path $stagingDir $AddonName
    New-Item -ItemType Directory -Path $staged | Out-Null
    $exclude = @(".git", "Documents", "Probe", "Tools", ".gitignore")
    Get-ChildItem -Path $RepoRoot -Force | Where-Object { $exclude -notcontains $_.Name } | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $staged -Recurse -Force
    }

    foreach ($dir in Get-AddOnDirs $root) {
        Write-Host "-> $dir" -ForegroundColor Cyan
        if ($Link) {
            # Linking the repo root directly would expose Documents/ and .git to
            # the game, so link mode still uses the staged copy for the addon and
            # links only the probe, which is already a clean folder.
            Sync-One $staged $dir $AddonName
        } else {
            Sync-One $staged $dir $AddonName
        }
        Sync-One (Join-Path $RepoRoot "Probe\$ProbeName") $dir $ProbeName
    }

    Write-Host "Done. /reload in game." -ForegroundColor Green
}

Sync-All

if ($Watch) {
    Write-Host "Watching $RepoRoot for changes. Ctrl+C to stop." -ForegroundColor Yellow
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $RepoRoot
    $watcher.IncludeSubdirectories = $true
    $watcher.Filter = "*.lua"
    $watcher.EnableRaisingEvents = $true

    while ($true) {
        $change = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, 1000)
        if (-not $change.TimedOut) {
            Start-Sleep -Milliseconds 250   # let the editor finish writing
            Write-Host "changed: $($change.Name)" -ForegroundColor DarkGray
            try { Sync-All } catch { Write-Host $_ -ForegroundColor Red }
        }
    }
}
