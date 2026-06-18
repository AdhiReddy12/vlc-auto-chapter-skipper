# Auto Chapter Skipper - VLC Extension Installer
# Run this script to install the extension to your VLC extensions directory.

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Auto Chapter Skipper - VLC Extension" -ForegroundColor Cyan
Write-Host "  Installer for Windows" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceExt = Join-Path $scriptDir "autoskip_chapters.lua"
$sourceBg = Join-Path $scriptDir "autoskip_bg.lua"

if (-not (Test-Path $sourceExt)) {
    Write-Host "ERROR: Cannot find 'autoskip_chapters.lua' in $scriptDir" -ForegroundColor Red
    Write-Host "Please extract the entire ZIP file before running this installer." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}
if (-not (Test-Path $sourceBg)) {
    Write-Host "ERROR: Cannot find 'autoskip_bg.lua' in $scriptDir" -ForegroundColor Red
    Write-Host "Please extract the entire ZIP file before running this installer." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

$vlcExtDir = Join-Path $env:APPDATA "vlc\lua\extensions"
$vlcIntfDir = Join-Path $env:APPDATA "vlc\lua\intf"

if (-not (Test-Path $vlcExtDir)) {
    Write-Host "Creating extension directory..." -ForegroundColor DarkGray
    New-Item -ItemType Directory -Path $vlcExtDir -Force | Out-Null
}
if (-not (Test-Path $vlcIntfDir)) {
    Write-Host "Creating intf directory..." -ForegroundColor DarkGray
    New-Item -ItemType Directory -Path $vlcIntfDir -Force | Out-Null
}

Write-Host "Installing GUI Extension..." -ForegroundColor Yellow
Copy-Item -Path $sourceExt -Destination $vlcExtDir -Force

Write-Host "Installing Background Watcher..." -ForegroundColor Yellow
Copy-Item -Path $sourceBg -Destination $vlcIntfDir -Force

$vlcrcPath = Join-Path $env:APPDATA "vlc\vlcrc"
if (Test-Path $vlcrcPath) {
    Write-Host "Updating VLC configuration (vlcrc)..." -ForegroundColor Yellow
    $vlcrc = Get-Content $vlcrcPath -Raw
    
    # Update extraintf to include luaintf
    if ($vlcrc -match '(?m)^#?extraintf=(.*)$') {
        $val = $matches[1]
        if ($val -notmatch 'luaintf') {
            if ($val -eq "") { $newVal = "luaintf" }
            else { $newVal = "$val,luaintf" }
            $vlcrc = $vlcrc -replace '(?m)^#?extraintf=.*$', "extraintf=$newVal"
        } else {
            $vlcrc = $vlcrc -replace '(?m)^#?extraintf=.*$', "extraintf=$val" # uncomment if it was commented
        }
    } else {
        $vlcrc += "`nextraintf=luaintf`n"
    }

    # Update lua-intf to autoskip_bg
    if ($vlcrc -match '(?m)^#?lua-intf=.*$') {
        $vlcrc = $vlcrc -replace '(?m)^#?lua-intf=.*$', "lua-intf=autoskip_bg"
    } else {
        $vlcrc += "`nlua-intf=autoskip_bg`n"
    }

    Set-Content -Path $vlcrcPath -Value $vlcrc
    Write-Host "  Updated: $vlcrcPath" -ForegroundColor Green
} else {
    Write-Host "Warning: vlcrc not found, background polling may not start automatically." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  SUCCESS! Extension and Background Watcher installed." -ForegroundColor Green
Write-Host ""
Write-Host "--------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "  1. Restart VLC (close and reopen completely)" -ForegroundColor White
Write-Host "  2. The background watcher is now active!" -ForegroundColor White
Write-Host "  3. Go to View -> 'Auto Chapter Skipper' for settings." -ForegroundColor White
Write-Host "--------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Read-Host "Press Enter to exit"
