#Requires -Version 5.1
<#
.SYNOPSIS
    Live User-Space Optimizer & Native Win32 RAM Trimmer (OptiJuegos / AtlasOS / Chris Titus style)
    Applies safe HKCU registry optimizations, stops safe user-space bloatware, cleans stale $env:TEMP,
    and trims process working sets via psapi.dll EmptyWorkingSet.
#>

$ErrorActionPreference = 'Continue'

Write-Host "[1/5] Waiting 3 seconds before capturing BEFORE snapshot..." -ForegroundColor Cyan
Start-Sleep -Seconds 3

function Get-SystemMemorySnapshot {
    $os = Get-CimInstance Win32_OperatingSystem
    $procs = Get-Process
    $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 2)
    $freeMB  = [math]::Round($os.FreePhysicalMemory / 1024, 2)
    $usedMB  = [math]::Round($totalMB - $freeMB, 2)
    $usedPct = [math]::Round(($usedMB / $totalMB) * 100, 2)
    return [PSCustomObject]@{
        Timestamp    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        ProcessCount = $procs.Count
        TotalRAM_MB  = $totalMB
        FreeRAM_MB   = $freeMB
        UsedRAM_MB   = $usedMB
        UsedRAM_Pct  = $usedPct
    }
}

$before = Get-SystemMemorySnapshot
Write-Host ("BEFORE -> Processes: {0} | Used RAM: {1} MB ({2}%) | Free RAM: {3} MB / {4} MB" -f `
    $before.ProcessCount, $before.UsedRAM_MB, $before.UsedRAM_Pct, $before.FreeRAM_MB, $before.TotalRAM_MB) -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# 2. Apply Safe User-Space Registry Optimizations (HKCU)
# ---------------------------------------------------------------------------
Write-Host "[2/5] Applying Safe User-Space Registry Optimizations (HKCU)..." -ForegroundColor Cyan

$regResults = New-Object System.Collections.Generic.List[Object]

function Set-SafeHKCUValue {
    param(
        [string]$Category,
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [string]$Type = 'DWord'
    )
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        $prevObj = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
        $prevVal = if ($null -ne $prevObj) { $prevObj.$Name } else { "<not set>" }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        $regResults.Add([PSCustomObject]@{
            Category = $Category
            Path     = $Path
            Name     = $Name
            Type     = $Type
            Before   = "$prevVal"
            After    = "$Value"
            Status   = "OK"
        })
    } catch {
        $regResults.Add([PSCustomObject]@{
            Category = $Category
            Path     = $Path
            Name     = $Name
            Type     = $Type
            Before   = "N/A"
            After    = "$Value"
            Status   = "ERROR: $($_.Exception.Message)"
        })
    }
}

# A. Disable GameDVR Background Recording (FPS & GPU boost)
Set-SafeHKCUValue "GameDVR / Gaming" "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0 "DWord"
Set-SafeHKCUValue "GameDVR / Gaming" "HKCU:\System\GameConfigStore" "GameDVR_FSEBehaviorMode" 2 "DWord"
Set-SafeHKCUValue "GameDVR / Gaming" "HKCU:\System\GameConfigStore" "GameDVR_HonorUserFSEBehaviorMode" 1 "DWord"
Set-SafeHKCUValue "GameDVR / Gaming" "HKCU:\System\GameConfigStore" "GameDVR_DXGIHonorFSEWindowsCompatible" 1 "DWord"
Set-SafeHKCUValue "GameDVR / Gaming" "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" 0 "DWord"

# B. Disable Microsoft Edge & WebView Background Bloat
Set-SafeHKCUValue "Edge Background" "HKCU:\SOFTWARE\Policies\Microsoft\Edge" "StartupBoostEnabled" 0 "DWord"
Set-SafeHKCUValue "Edge Background" "HKCU:\SOFTWARE\Policies\Microsoft\Edge" "BackgroundModeEnabled" 0 "DWord"

# C. Disable Windows 11 Telemetry, Advertising ID, Tailored Experiences & Start Menu Bing Web Search
Set-SafeHKCUValue "Privacy & Telemetry" "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 0 "DWord"
Set-SafeHKCUValue "Privacy & Telemetry" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" 0 "DWord"
Set-SafeHKCUValue "Search & Cortana" "HKCU:\Software\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 1 "DWord"
Set-SafeHKCUValue "Search & Cortana" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled" 0 "DWord"
Set-SafeHKCUValue "Search & Cortana" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "CortanaConsent" 0 "DWord"

$cdmPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
Set-SafeHKCUValue "ContentDeliveryManager" $cdmPath "SubscribedContent-338388Enabled" 0 "DWord"
Set-SafeHKCUValue "ContentDeliveryManager" $cdmPath "SubscribedContent-338389Enabled" 0 "DWord"
Set-SafeHKCUValue "ContentDeliveryManager" $cdmPath "SubscribedContent-353698Enabled" 0 "DWord"
Set-SafeHKCUValue "ContentDeliveryManager" $cdmPath "SystemPaneSuggestionsEnabled" 0 "DWord"
Set-SafeHKCUValue "ContentDeliveryManager" $cdmPath "SoftLandingEnabled" 0 "DWord"
Set-SafeHKCUValue "ContentDeliveryManager" $cdmPath "RotatingLockScreenOverlayEnabled" 0 "DWord"
Set-SafeHKCUValue "ContentDeliveryManager" $cdmPath "SilentInstalledAppsEnabled" 0 "DWord"

# D. Disable Background UWP Apps & Taskbar Widgets
Set-SafeHKCUValue "Background UWP Apps" "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" "GlobalUserDisabled" 1 "DWord"
Set-SafeHKCUValue "Explorer & Widgets" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa" 0 "DWord"
Set-SafeHKCUValue "Explorer & Widgets" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowSyncProviderNotifications" 0 "DWord"

# E. Zero UI & Startup Delays (OptiJuegos / AtlasOS responsiveness tweak)
Set-SafeHKCUValue "UI & Responsiveness" "HKCU:\Control Panel\Desktop" "MenuShowDelay" "0" "String"
Set-SafeHKCUValue "UI & Responsiveness" "HKCU:\Control Panel\Desktop" "AutoEndTasks" "1" "String"
Set-SafeHKCUValue "UI & Responsiveness" "HKCU:\Control Panel\Desktop" "HungAppTimeout" "1000" "String"
Set-SafeHKCUValue "UI & Responsiveness" "HKCU:\Control Panel\Desktop" "WaitToKillAppTimeout" "2000" "String"
Set-SafeHKCUValue "UI & Responsiveness" "HKCU:\Control Panel\Desktop" "LowLevelHooksTimeout" "1000" "String"
Set-SafeHKCUValue "UI & Responsiveness" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" "StartupDelayInMSec" 0 "DWord"

$okRegCount = ($regResults | Where-Object { $_.Status -eq 'OK' }).Count
Write-Host ("Applied {0}/{1} HKCU Registry Optimizations successfully." -f $okRegCount, $regResults.Count) -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Terminate Unneeded User-Space Bloat Processes (SAFE LIST ONLY)
# ---------------------------------------------------------------------------
Write-Host "[3/5] Checking & Terminating Unneeded User-Space Bloat Processes (Safe List Only)..." -ForegroundColor Cyan

$safeKillList = @(
    'Widgets',
    'WidgetService',
    'GameBarPresenceWriter',
    'GameBar',
    'GameBarFTServer',
    'CompatTelRunner',
    'HxTsr',
    'MapsBroker',
    'YourPhone',
    'PhoneExperienceHost',
    'SearchApp',
    'HP.MyHP',
    'HPSystemEventUtilityHost',
    'OmenCommandCenterBackground',
    'Overwolf'
)

$killedProcesses = New-Object System.Collections.Generic.List[Object]
foreach ($procName in $safeKillList) {
    $running = Get-Process -Name $procName -ErrorAction SilentlyContinue
    if ($null -ne $running) {
        foreach ($p in $running) {
            $wsMB = [math]::Round($p.WorkingSet64 / 1MB, 2)
            $pidVal = $p.Id
            try {
                Stop-Process -Id $pidVal -Force -ErrorAction Stop
                $killedProcesses.Add([PSCustomObject]@{
                    Name         = $procName
                    PID          = $pidVal
                    WorkingSetMB = $wsMB
                    Action       = "Terminated"
                })
                Write-Host ("  -> Terminated {0} (PID {1}, {2} MB)" -f $procName, $pidVal, $wsMB) -ForegroundColor Green
            } catch {
                $killedProcesses.Add([PSCustomObject]@{
                    Name         = $procName
                    PID          = $pidVal
                    WorkingSetMB = $wsMB
                    Action       = "Failed: $($_.Exception.Message)"
                })
            }
        }
    }
}
if ($killedProcesses.Count -eq 0) {
    Write-Host "  -> None of the target bloat processes were running." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# 4. Clean User Temp Folder & Run Native Win32 EmptyWorkingSet RAM Trimmer
# ---------------------------------------------------------------------------
Write-Host "[4/5] Cleaning stale Temp files (>1 day) & Running Native Win32 EmptyWorkingSet RAM Trimmer..." -ForegroundColor Cyan

$cutoff = (Get-Date).AddDays(-1)
$tempDeletedCount = 0
$tempDeletedBytes = 0

if (Test-Path -LiteralPath $env:TEMP) {
    $staleItems = Get-ChildItem -LiteralPath $env:TEMP -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff }
    foreach ($item in $staleItems) {
        try {
            $len = if (-not $item.PSIsContainer) { $item.Length } else { 0 }
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $tempDeletedCount++
            $tempDeletedBytes += $len
        } catch {
            # In-use temp file; skip safely
        }
    }
}
$tempDeletedMB = [math]::Round($tempDeletedBytes / 1MB, 2)
Write-Host ("  -> Cleaned {0} stale items from `$env:TEMP ({1} MB freed)" -f $tempDeletedCount, $tempDeletedMB) -ForegroundColor Green

# Native Win32 EmptyWorkingSet
$signature = @"
using System;
using System.Runtime.InteropServices;

public static class Win32MemTrimmer {
    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
}
"@

Add-Type -TypeDefinition $signature -ErrorAction SilentlyContinue

[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
[System.GC]::Collect()

$trimmedCount = 0
$skippedCount = 0
$topTrimmed = New-Object System.Collections.Generic.List[Object]

$allProcs = Get-Process -ErrorAction SilentlyContinue
foreach ($proc in $allProcs) {
    try {
        $handle = $proc.Handle
        if ($handle -ne [IntPtr]::Zero) {
            $wsBeforeMB = [math]::Round($proc.WorkingSet64 / 1MB, 2)
            $ok = [Win32MemTrimmer]::EmptyWorkingSet($handle)
            if ($ok) {
                $trimmedCount++
                $topTrimmed.Add([PSCustomObject]@{
                    Name       = $proc.ProcessName
                    PID        = $proc.Id
                    WSBeforeMB = $wsBeforeMB
                })
            } else {
                $skippedCount++
            }
        }
    } catch {
        $skippedCount++
    }
}

Write-Host ("  -> EmptyWorkingSet trimmed {0} accessible processes ({1} protected/system processes skipped)." -f $trimmedCount, $skippedCount) -ForegroundColor Green

# Brief pause for OS memory manager to update counters
Start-Sleep -Seconds 1

# ---------------------------------------------------------------------------
# 5. Capture AFTER Metrics
# ---------------------------------------------------------------------------
Write-Host "[5/5] Capturing AFTER snapshot..." -ForegroundColor Cyan
$after = Get-SystemMemorySnapshot

$deltaProcs   = $after.ProcessCount - $before.ProcessCount
$deltaFreeMB  = [math]::Round($after.FreeRAM_MB - $before.FreeRAM_MB, 2)
$deltaUsedMB  = [math]::Round($after.UsedRAM_MB - $before.UsedRAM_MB, 2)
$deltaUsedPct = [math]::Round($after.UsedRAM_Pct - $before.UsedRAM_Pct, 2)

Write-Host ("AFTER  -> Processes: {0} | Used RAM: {1} MB ({2}%) | Free RAM: {3} MB / {4} MB" -f `
    $after.ProcessCount, $after.UsedRAM_MB, $after.UsedRAM_Pct, $after.FreeRAM_MB, $after.TotalRAM_MB) -ForegroundColor Yellow
Write-Host ("DELTA  -> Processes: {0} | Used RAM: {1} MB ({2}%) | Free RAM Gained: +{3} MB" -f `
    $deltaProcs, $deltaUsedMB, $deltaUsedPct, $deltaFreeMB) -ForegroundColor Green

$summaryObj = [PSCustomObject]@{
    Before            = $before
    After             = $after
    DeltaProcesses    = $deltaProcs
    DeltaFreeRAM_MB   = $deltaFreeMB
    DeltaUsedRAM_MB   = $deltaUsedMB
    DeltaUsedRAM_Pct  = $deltaUsedPct
    RegistryApplied   = $okRegCount
    RegistryTotal     = $regResults.Count
    RegistryDetails   = $regResults
    KilledProcesses   = $killedProcesses
    TempDeletedItems  = $tempDeletedCount
    TempDeletedMB     = $tempDeletedMB
    TrimmedProcesses  = $trimmedCount
    SkippedProcesses  = $skippedCount
}

$summaryObj | ConvertTo-Json -Depth 5 | Write-Output
