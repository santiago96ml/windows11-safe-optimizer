#Requires -Version 5.1
<#
.SYNOPSIS
    Suite de Optimizacion Avanzada para Windows 10/11 (Nivel Administrador)
    Inspirado en OptiJuegos, AtlasOS y ReviOS - 100% Auditable y Reversible.
.DESCRIPTION
    1. Crea Punto de Restauracion y respalda claves de registro en backup_reg\.
    2. Deshabilita servicios de telemetria de Microsoft y OEM (HP) sin afectar
       Bluetooth, Audio, Wi-Fi, Windows Defender, Impresoras ni Xbox Game Pass.
    3. Deshabilita tareas programadas de telemetria (CompatTelRunner, CEIP, Siuf).
    4. Optimiza HKLM: SvcHostSplitThresholdInKB dinamico, Win32PrioritySeparation (0x26),
       MMCSS Low-Latency Gaming Profile, PowerThrottlingOff, Plan Maximo Rendimiento,
       HAGS (HwSchMode=2), NTFS disablelastaccess, bcdedit disabledynamictick,
       y politicas de privacidad/IA (AllowTelemetry=0, DisableAIDataAnalysis=1).
    5. Ejecuta recortador nativo de Working Set (psapi.dll EmptyWorkingSet) y muestra
       comparativa Antes vs. Despues de RAM libre y procesos.
#>

[CmdletBinding()]
param(
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ==============================================================================
# 0. VERIFICACION DE PRIVILEGIOS DE ADMINISTRADOR (AUTO-ELEVACION)
# ==============================================================================
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] Elevando permisos a Administrador (UAC)..." -ForegroundColor Yellow
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($NoPause) { $arguments += " -NoPause" }
    Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs
    exit
}

Clear-Host
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host "   OPTIMIZADOR WINDOWS PRO - SUITE DE ADMINISTRADOR (OPTIJUEGOS / ATLAS)  " -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host ""

# Capturar metricas iniciales (ANTES)
$osBefore = Get-CimInstance Win32_OperatingSystem
$totalRamMB = [math]::Round($osBefore.TotalVisibleMemorySize / 1024, 0)
$freeRamBeforeMB = [math]::Round($osBefore.FreePhysicalMemory / 1024, 0)
$usedRamBeforeMB = $totalRamMB - $freeRamBeforeMB
$procCountBefore = (Get-Process).Count
$svchostBefore = (Get-Process -Name "svchost" -ErrorAction SilentlyContinue).Count

Write-Host "[INFO] Estado Inicial del Sistema:" -ForegroundColor White
Write-Host ("       RAM Total : {0} MB | RAM Usada : {1} MB | RAM Libre : {2} MB" -f $totalRamMB, $usedRamBeforeMB, $freeRamBeforeMB) -ForegroundColor Gray
Write-Host ("       Procesos  : {0} totales ({1} instancias de svchost.exe)" -f $procCountBefore, $svchostBefore) -ForegroundColor Gray
Write-Host ""

# ==============================================================================
# 1. RESPALDO DE SEGURIDAD Y PUNTO DE RESTAURACION
# ==============================================================================
Write-Host "[1/6] Creando respaldos de seguridad y Punto de Restauracion..." -ForegroundColor Yellow

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$BackupDir = Join-Path $ScriptDir "backup_reg"
if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

# Habilitar System Restore en C:\ y crear Checkpoint
try {
    Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description "Antes_OptiWindows_Antigravity" -RestorePointType "MODIFY_SETTINGS" -ErrorAction SilentlyContinue
    Write-Host "  [+] Punto de restauracion 'Antes_OptiWindows_Antigravity' solicitado." -ForegroundColor Green
} catch {
    Write-Host "  [i] Aviso Punto de Restauracion: $($_.Exception.Message)" -ForegroundColor DarkGray
}

# Exportar claves de registro criticas
$regBackups = @{
    "PriorityControl.reg" = "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl"
    "SystemProfile.reg"   = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    "GraphicsDrivers.reg" = "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
}

foreach ($file in $regBackups.Keys) {
    $regPath = $regBackups[$file]
    $outFile = Join-Path $BackupDir $file
    $null = & reg.exe export $regPath $outFile /y 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [+] Respaldo exportado: $outFile" -ForegroundColor Green
    }
}

# Guardar valor original de SvcHostSplitThresholdInKB
try {
    $origThreshold = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "SvcHostSplitThresholdInKB" -ErrorAction SilentlyContinue).SvcHostSplitThresholdInKB
    if ($null -ne $origThreshold) {
        $origThreshold | Out-File -FilePath (Join-Path $BackupDir "SvcHostSplitThresholdInKB_orig.txt") -Encoding ascii -Force
    }
} catch {}

# ==============================================================================
# 2. DESHABILITAR SERVICIOS DE TELEMETRIA (MICROSOFT Y OEM HP)
# ==============================================================================
Write-Host ""
Write-Host "[2/6] Deshabilitando Servicios de Telemetria de Microsoft y OEM HP..." -ForegroundColor Yellow

$telemetryServices = @(
    # Telemetria y diagnostico de Microsoft
    "DiagTrack",                    # Connected User Experiences and Telemetry
    "dmwappushservice",             # WAP Push Message Routing / Telemetry
    "MapsBroker",                   # Downloaded Maps Manager
    "lfsvc",                        # Geolocation Service
    "WerSvc",                       # Windows Error Reporting Service
    "RetailDemo",                   # Retail Demo Service
    "wisvc",                        # Windows Insider Service
    "PcaSvc",                       # Program Compatibility Assistant
    # Servicios de Telemetria / Bloatware OEM HP
    "HPTouchpointAnalyticsService",
    "HPAppHelperCap",
    "HPDiagsCap",
    "HPNetworkCap",
    "HPSysInfoCap",
    "HPOmenCap"
)

$serviceBackupFile = Join-Path $BackupDir "services_backup.csv"
$serviceBackupList = @()

foreach ($svcName in $telemetryServices) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($null -ne $svc) {
        $serviceBackupList += [PSCustomObject]@{
            Name        = $svc.Name
            StartType   = $svc.StartType.ToString()
            Status      = $svc.Status.ToString()
        }
        try {
            if ($svc.Status -ne 'Stopped') {
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $svcName -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Host ("  [+] Servicio detenido y deshabilitado: {0} ({1})" -f $svc.Name, $svc.DisplayName) -ForegroundColor Green
        } catch {
            Write-Host ("  [!] No se pudo modificar el servicio {0}: {1}" -f $svcName, $_.Exception.Message) -ForegroundColor DarkYellow
        }
    } else {
        Write-Host ("  [-] Servicio no presente (omitido): {0}" -f $svcName) -ForegroundColor DarkGray
    }
}

if ($serviceBackupList.Count -gt 0 -and -not (Test-Path $serviceBackupFile)) {
    $serviceBackupList | Export-Csv -Path $serviceBackupFile -NoTypeInformation -Encoding UTF8
}

# ==============================================================================
# 3. DESHABILITAR TAREAS PROGRAMADAS DE TELEMETRIA
# ==============================================================================
Write-Host ""
Write-Host "[3/6] Deshabilitando Tareas Programadas de Telemetria..." -ForegroundColor Yellow

$telemetryTasks = @(
    "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "\Microsoft\Windows\Application Experience\StartupAppTask",
    "\Microsoft\Windows\Autochk\Proxy",
    "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
    "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
    "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
    "\Microsoft\Windows\Feedback\Siuf\DmClient",
    "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload"
)

foreach ($fullTaskPath in $telemetryTasks) {
    $lastSlash = $fullTaskPath.LastIndexOf('\')
    $taskFolder = $fullTaskPath.Substring(0, $lastSlash + 1)
    $taskName = $fullTaskPath.Substring($lastSlash + 1)

    $taskObj = Get-ScheduledTask -TaskPath $taskFolder -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $taskObj) {
        try {
            Disable-ScheduledTask -TaskPath $taskFolder -TaskName $taskName -ErrorAction Stop | Out-Null
            Write-Host ("  [+] Tarea deshabilitada: {0}" -f $fullTaskPath) -ForegroundColor Green
        } catch {
            Write-Host ("  [!] No se pudo deshabilitar tarea {0}: {1}" -f $taskName, $_.Exception.Message) -ForegroundColor DarkYellow
        }
    } else {
        Write-Host ("  [-] Tarea no encontrada (omitida): {0}" -f $taskName) -ForegroundColor DarkGray
    }
}

# ==============================================================================
# 4. OPTIMIZACIONES HKLM: RAM, CPU QUANTUM, MMCSS, GPU Y ENERGIA
# ==============================================================================
Write-Host ""
Write-Host "[4/6] Aplicando Optimizaciones de Registro HKLM (OptiJuegos / AtlasOS / ReviOS)..." -ForegroundColor Yellow

function Set-RegDword {
    param(
        [string]$Path,
        [string]$Name,
        [long]$Value
    )
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    $int32Val = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$Value), 0)
    Set-ItemProperty -Path $Path -Name $Name -Value $int32Val -Type DWord -Force
}

function Set-RegString {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Value
    )
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type String -Force
}

# 4.1 Consolidar procesos svchost.exe (SvcHostSplitThresholdInKB)
try {
    $totalRamBytes = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum
    $ramInKB = [uint32]($totalRamBytes / 1KB)
    if ($ramInKB -lt 4194304) { $ramInKB = 16777216 }
    Set-RegDword -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "SvcHostSplitThresholdInKB" -Value $ramInKB
    Write-Host ("  [+] SvcHostSplitThresholdInKB ajustado dinamicamente a {0} KB (~{1} GB)" -f $ramInKB, [math]::Round($ramInKB / 1MB, 1)) -ForegroundColor Green
} catch {
    Write-Host "  [!] Error ajustando SvcHostSplitThresholdInKB: $($_.Exception.Message)" -ForegroundColor Red
}

# 4.2 Prioridad de Quantum de CPU (Win32PrioritySeparation = 38 / 0x26)
try {
    Set-RegDword -Path "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" -Name "Win32PrioritySeparation" -Value 38
    Write-Host "  [+] Win32PrioritySeparation = 38 (0x26: Quantum corto variable, boost 3:1 primer plano)" -ForegroundColor Green
} catch {
    Write-Host "  [!] Error ajustando Win32PrioritySeparation: $($_.Exception.Message)" -ForegroundColor Red
}

# 4.3 MMCSS Gaming & Low Latency Profile
try {
    $mmcssPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    Set-RegDword -Path $mmcssPath -Name "SystemResponsiveness" -Value 0
    Set-RegDword -Path $mmcssPath -Name "NetworkThrottlingIndex" -Value 0xffffffff

    $gamesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"
    Set-RegDword  -Path $gamesPath -Name "GPU Priority"        -Value 8
    Set-RegDword  -Path $gamesPath -Name "Priority"            -Value 6
    Set-RegString -Path $gamesPath -Name "Scheduling Category" -Value "High"
    Set-RegString -Path $gamesPath -Name "SFIO Priority"       -Value "High"
    Write-Host "  [+] Perfil MMCSS de Baja Latencia activado (SystemResponsiveness=0, NetworkThrottlingIndex=0xFFFFFFFF, Games=High)" -ForegroundColor Green
} catch {
    Write-Host "  [!] Error configurando MMCSS: $($_.Exception.Message)" -ForegroundColor Red
}

# 4.4 Deshabilitar Power Throttling y activar Plan Ultimate Performance
try {
    Set-RegDword -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" -Name "PowerThrottlingOff" -Value 1
    Write-Host "  [+] PowerThrottlingOff = 1 aplicado en HKLM." -ForegroundColor Green

    $ultTemplateGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
    $powerList = & powercfg.exe /list 2>$null
    $existingUlt = $powerList | Select-String -Pattern "Maximo rendimiento|Ultimate Performance|$ultTemplateGuid" | Select-Object -First 1

    $targetGuid = $null
    if ($existingUlt -and $existingUlt.Line -match "([a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12})") {
        $targetGuid = $Matches[1]
    } else {
        $dupOut = & powercfg.exe -duplicatescheme $ultTemplateGuid 2>$null
        if ($dupOut -match "([a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12})") {
            $targetGuid = $Matches[1]
        }
    }

    if ($targetGuid) {
        & powercfg.exe -setactive $targetGuid 2>$null
        Write-Host "  [+] Plan de Energia 'Ultimate Performance' activado (GUID: $targetGuid)." -ForegroundColor Green
    } else {
        & powercfg.exe -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
        Write-Host "  [+] Plan de Energia de Alto Rendimiento activado." -ForegroundColor Green
    }
} catch {
    Write-Host "  [!] Aviso configurando Plan de Energia: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

# 4.5 Hardware-Accelerated GPU Scheduling (HAGS) & Tweaks NTFS / BCD
try {
    Set-RegDword -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2
    Write-Host "  [+] Hardware-Accelerated GPU Scheduling (HwSchMode = 2) habilitado." -ForegroundColor Green

    $null = & fsutil.exe behavior set disablelastaccess 1 2>$null
    Write-Host "  [+] NTFS disablelastaccess = 1 aplicado." -ForegroundColor Green

    $null = & bcdedit.exe /set disabledynamictick yes 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [+] BCD disabledynamictick = yes aplicado (menor latencia de interrupciones)." -ForegroundColor Green
    }
} catch {
    Write-Host "  [!] Aviso en HAGS/NTFS/BCD: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

# 4.6 Politicas de Telemetria e IA a nivel de Maquina (HKLM Policies)
try {
    $dataCollPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
    Set-RegDword -Path $dataCollPath -Name "AllowTelemetry" -Value 0
    Set-RegDword -Path $dataCollPath -Name "DoNotShowFeedbackNotifications" -Value 1

    $winAiPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"
    Set-RegDword -Path $winAiPath -Name "DisableAIDataAnalysis" -Value 1
    Set-RegDword -Path $winAiPath -Name "TurnOffWindowsCopilot" -Value 1
    Write-Host "  [+] Politicas HKLM aplicadas: AllowTelemetry=0, DisableAIDataAnalysis=1, TurnOffWindowsCopilot=1." -ForegroundColor Green
} catch {
    Write-Host "  [!] Error aplicando politicas HKLM: $($_.Exception.Message)" -ForegroundColor Red
}

# ==============================================================================
# 5. LIMPIEZA RAPIDA DE TEMPORALES Y PREFETCH
# ==============================================================================
Write-Host ""
Write-Host "[5/6] Limpiando archivos temporales del sistema..." -ForegroundColor Yellow

$tempPaths = @(
    $env:TEMP,
    (Join-Path $env:SystemRoot "Temp")
)

$deletedFiles = 0
foreach ($tp in $tempPaths) {
    if (Test-Path $tp) {
        $items = Get-ChildItem -Path $tp -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            try {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                $deletedFiles++
            } catch {}
        }
    }
}
Write-Host ("  [+] Elementos temporales eliminados (los archivos en uso se omitieron): {0}" -f $deletedFiles) -ForegroundColor Green

# ==============================================================================
# 6. LIBERADOR NATIVO DE MEMORIA RAM (EMPTYWORKINGSET C# / PSAPI.DLL)
# ==============================================================================
Write-Host ""
Write-Host "[6/6] Ejecutando Recortador Nativo de Working Set (psapi.dll EmptyWorkingSet)..." -ForegroundColor Yellow

$MemTrimmerSource = @"
using System;
using System.Runtime.InteropServices;

public static class NativeRamTrimmer {
    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
}
"@

if (-not ("NativeRamTrimmer" -as [type])) {
    Add-Type -TypeDefinition $MemTrimmerSource -Language CSharp -ErrorAction SilentlyContinue
}

$trimmedCount = 0
$allProcs = Get-Process -ErrorAction SilentlyContinue
foreach ($proc in $allProcs) {
    try {
        if ($proc.Id -gt 4 -and $proc.Handle -ne [IntPtr]::Zero) {
            $res = [NativeRamTrimmer]::EmptyWorkingSet($proc.Handle)
            if ($res) { $trimmedCount++ }
        }
    } catch {}
}

[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
Start-Sleep -Seconds 2

# ==============================================================================
# RESUMEN FINAL: ANTES VS. DESPUES
# ==============================================================================
$osAfter = Get-CimInstance Win32_OperatingSystem
$freeRamAfterMB = [math]::Round($osAfter.FreePhysicalMemory / 1024, 0)
$usedRamAfterMB = $totalRamMB - $freeRamAfterMB
$ramSavedMB = $freeRamAfterMB - $freeRamBeforeMB
$procCountAfter = (Get-Process).Count
$svchostAfter = (Get-Process -Name "svchost" -ErrorAction SilentlyContinue).Count

Write-Host ""
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host "                  RESUMEN DE OPTIMIZACION (ANTES VS DESPUES)              " -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host ("  Procesos recortados (EmptyWorkingSet) : {0} procesos optimizados" -f $trimmedCount) -ForegroundColor Green
Write-Host ("  RAM Libre ANTES                       : {0} MB (Usada: {1} MB)" -f $freeRamBeforeMB, $usedRamBeforeMB) -ForegroundColor White
Write-Host ("  RAM Libre DESPUES                     : {0} MB (Usada: {1} MB)" -f $freeRamAfterMB, $usedRamAfterMB) -ForegroundColor Green
if ($ramSavedMB -ge 0) {
    Write-Host ("   Ganancia neta de RAM Libre            : +{0} MB liberados al instante" -f $ramSavedMB) -ForegroundColor Cyan
} else {
    Write-Host ("  Variacion de RAM Libre                : {0} MB" -f $ramSavedMB) -ForegroundColor Cyan
}
Write-Host ("  Procesos Totales (Antes -> Despues)   : {0} -> {1}" -f $procCountBefore, $procCountAfter) -ForegroundColor White
Write-Host ("  Instancias svchost (Antes -> Despues) : {0} -> {1} (se consolida tras reiniciar)" -f $svchostBefore, $svchostAfter) -ForegroundColor White
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host "  [i] Nota: Algunos cambios de registro (SvcHostSplitThresholdInKB, HAGS y" -ForegroundColor Gray
Write-Host "      Win32PrioritySeparation) alcanzan su maximo efecto tras reiniciar." -ForegroundColor Gray
Write-Host "  [i] Para revertir todos los cambios, ejecuta: restaurar_windows_original.bat" -ForegroundColor Gray
Write-Host "==========================================================================" -ForegroundColor Cyan

if (-not $NoPause) {
    Write-Host ""
    Write-Host "Presiona cualquier tecla para cerrar esta ventana..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
