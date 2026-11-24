@echo off
chcp 65001 >nul 2>&1
title OPTIMIZAR WINDOWS PRO - Suite de Rendimiento y Gaming (Admin)
color 0B

set "PS_SCRIPT=%~dp0optimizar_windows_admin.ps1"

if not exist "%PS_SCRIPT%" (
    echo [ERROR] No se encontro el script en:
    echo "%PS_SCRIPT%"
    pause
    exit /b 1
)

:: Verificar privilegios de Administrador
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ==========================================================================
    echo   Solicitando permisos de Administrador ^(UAC^) para Optimizar Windows...
    echo ==========================================================================
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%PS_SCRIPT%""' -Verb RunAs"
    exit /b 0
)

:: Si ya tiene privilegios de Administrador, ejecutar directamente
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
exit /b 0
