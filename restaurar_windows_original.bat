@echo off
chcp 65001 >nul 2>&1
title RESTAURAR WINDOWS ORIGINAL - Rollback Suite (Antigravity)
color 0E

:: ==============================================================================
:: 0. AUTO-ELEVACION UAC A ADMINISTRADOR
:: ==============================================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ==========================================================================
    echo   Solicitando permisos de Administrador ^(UAC^) para Restaurar Windows...
    echo ==========================================================================
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b 0
)

cls
echo ==========================================================================
echo      RESTAURADOR DE CONFIGURACION ORIGINAL DE WINDOWS 10/11 (ROLLBACK)
echo ==========================================================================
echo.

set "SCRIPT_DIR=%~dp0"
set "BACKUP_DIR=%SCRIPT_DIR%backup_reg"

:: ==============================================================================
:: 1. RESTAURAR VALORES DE REGISTRO (SVCHOST, CPU QUANTUM, MMCSS, ENERGIA)
:: ==============================================================================
echo [1/5] Restaurando valores originales del Registro (HKLM)...

:: Importar respaldos .reg si existen
if exist "%BACKUP_DIR%\PriorityControl.reg" (
    reg import "%BACKUP_DIR%\PriorityControl.reg" >nul 2>&1
    echo   [+] Respaldo importado: PriorityControl.reg
)
if exist "%BACKUP_DIR%\SystemProfile.reg" (
    reg import "%BACKUP_DIR%\SystemProfile.reg" >nul 2>&1
    echo   [+] Respaldo importado: SystemProfile.reg
)
if exist "%BACKUP_DIR%\GraphicsDrivers.reg" (
    reg import "%BACKUP_DIR%\GraphicsDrivers.reg" >nul 2>&1
    echo   [+] Respaldo importado: GraphicsDrivers.reg
)

:: Asegurar valores por defecto de fabrica de Windows:
:: Win32PrioritySeparation = 2 (0x2 - Valor por defecto de Windows)
reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v "Win32PrioritySeparation" /t REG_DWORD /d 2 /f >nul 2>&1
echo   [+] Win32PrioritySeparation restaurado a 2 (valor por defecto de Windows).

:: SvcHostSplitThresholdInKB = 3670016 (0x380000 = 3.5 GB por defecto de Windows)
reg add "HKLM\SYSTEM\CurrentControlSet\Control" /v "SvcHostSplitThresholdInKB" /t REG_DWORD /d 3670016 /f >nul 2>&1
echo   [+] SvcHostSplitThresholdInKB restaurado a 3670016 KB (3.5 GB por defecto).

:: MMCSS SystemProfile valores por defecto (SystemResponsiveness = 20, NetworkThrottlingIndex = 10)
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v "SystemResponsiveness" /t REG_DWORD /d 20 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v "NetworkThrottlingIndex" /t REG_DWORD /d 10 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "GPU Priority" /t REG_DWORD /d 8 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Priority" /t REG_DWORD /d 2 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Scheduling Category" /t REG_SZ /d "Medium" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "SFIO Priority" /t REG_SZ /d "Normal" /f >nul 2>&1
echo   [+] Perfil MMCSS restaurado a valores por defecto (SystemResponsiveness=20, NetworkThrottlingIndex=10).

:: PowerThrottling y Politicas de Telemetria / IA
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" /v "PowerThrottlingOff" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowTelemetry" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "DoNotShowFeedbackNotifications" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "DisableAIDataAnalysis" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v "TurnOffWindowsCopilot" /f >nul 2>&1
echo   [+] PowerThrottling y politicas de grupo (DataCollection / WindowsAI) restablecidas.

:: ==============================================================================
:: 2. RESTAURAR SERVICIOS DE WINDOWS Y OEM HP A SUS ESTADOS POR DEFECTO
:: ==============================================================================
echo.
echo [2/5] Restaurando estado por defecto de los Servicios de Windows...

:: Servicios que por defecto son Automaticos (auto)
sc config "DiagTrack" start= auto >nul 2>&1
sc start "DiagTrack" >nul 2>&1
sc config "PcaSvc" start= auto >nul 2>&1
sc start "PcaSvc" >nul 2>&1
sc config "MapsBroker" start= delayed-auto >nul 2>&1

:: Servicios que por defecto son Manuales (demand)
for %%S in (dmwappushservice lfsvc WerSvc RetailDemo wisvc) do (
    sc config "%%S" start= demand >nul 2>&1
)

:: Servicios OEM HP (si estan instalados en el equipo, restaurar a Automatico/Manual)
for %%H in (HPTouchpointAnalyticsService HPAppHelperCap HPDiagsCap HPNetworkCap HPSysInfoCap HPOmenCap) do (
    sc query "%%H" >nul 2>&1
    if not errorlevel 1 (
        sc config "%%H" start= auto >nul 2>&1
        sc start "%%H" >nul 2>&1
    )
)

:: Si existe services_backup.csv, restaurar exactamente el StartType guardado
if exist "%BACKUP_DIR%\services_backup.csv" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Csv '%BACKUP_DIR%\services_backup.csv' | ForEach-Object { Set-Service -Name $_.Name -StartupType $_.StartType -ErrorAction SilentlyContinue; if ($_.Status -eq 'Running') { Start-Service -Name $_.Name -ErrorAction SilentlyContinue } }"
    echo   [+] Estados exactos de servicios restaurados desde services_backup.csv.
) else (
    echo   [+] Servicios de Windows y HP restaurados a su configuracion estandar.
)

:: ==============================================================================
:: 3. REHABILITAR TAREAS PROGRAMADAS DE WINDOWS
:: ==============================================================================
echo.
echo [3/5] Rehabilitando Tareas Programadas de Windows...

schtasks /Change /TN "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" /ENABLE >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\Application Experience\ProgramDataUpdater" /ENABLE >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\Application Experience\StartupAppTask" /ENABLE >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\Autochk\Proxy" /ENABLE >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator" /ENABLE >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip" /ENABLE >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector" /ENABLE >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\Feedback\Siuf\DmClient" /ENABLE >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload" /ENABLE >nul 2>&1
echo   [+] Tareas programadas rehabilitadas.

:: ==============================================================================
:: 4. RESTAURAR PLAN DE ENERGIA EQUILIBRADO Y AJUSTES BCD / NTFS
:: ==============================================================================
echo.
echo [4/5] Restaurando Plan de Energia Equilibrado (Balanced) y temporizador BCD...

powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e >nul 2>&1
bcdedit /deletevalue disabledynamictick >nul 2>&1
fsutil behavior set disablelastaccess 2 >nul 2>&1
echo   [+] Plan Equilibrado (381b4222-f694-41f0-9685-ff5bb260df2e) y BCD/NTFS por defecto restaurados.

:: ==============================================================================
:: 5. FINALIZACION
:: ==============================================================================
echo.
echo ==========================================================================
echo   [OK] RESTAURACION COMPLETADA EXITOSAMENTE.
echo   Reinicia tu PC para que todos los servicios y el registro vuelvan
echo   a su comportamiento original de fabrica.
echo   (Tambien puedes usar 'rstrui.exe' para volver al Punto de Restauracion
echo   'Antes_OptiWindows_Antigravity' si lo deseas).
echo ==========================================================================
echo.
pause
exit /b 0
