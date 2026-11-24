@echo off
chcp 65001 >nul
setlocal EnableExtensions

title Sincronizador de Historial Edge -> Brave (Seguro)
set "SYNC_SCRIPT=%~dp0sync_history_when_brave_closed.py"
set "RESULT_JSON=%~dp0last_sync_result.json"
set "BRAVE_HIST=%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\History"

set "PY_EXE=python"

set "BRAVE_EXE=C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe"
if not exist "%BRAVE_EXE%" set "BRAVE_EXE=C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe"
if not exist "%BRAVE_EXE%" set "BRAVE_EXE=%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe"

echo ============================================================================
echo   SINCRONIZADOR DE HISTORIAL, TOP SITES, AUTOCOMPLETADO Y MARCADORES (EDGE -^> BRAVE)
echo ============================================================================
echo.
echo [AVISO] Este proceso hara lo siguiente de forma automatica y segura:
echo   1. Cerrara temporalmente Brave Browser (brave.exe) para liberar SQLite.
echo      (Esperara hasta 10 segundos a que cierre limpio antes de forzar cierre).
echo   2. Ejecutara la sincronizacion completa desde Edge hacia Brave.
echo   3. Mostrara el resumen exacto de registros sincronizados.
echo   4. Relanzara Brave inmediatamente con --restore-last-session para NO perder
echo      ninguna pestana abierta.
echo.

if not exist "%SYNC_SCRIPT%" (
    echo [ERROR] No se encontro el script:
    echo         "%SYNC_SCRIPT%"
    pause
    exit /b 1
)

tasklist /FI "IMAGENAME eq brave.exe" /NH | find /I "brave.exe" >nul
if errorlevel 1 (
    echo [INFO] Brave no estaba abierto. Continuando directamente con la sincronizacion...
    goto :run_sync
)

echo [1/4] Solicitando cierre limpio de Brave Browser...
taskkill /IM brave.exe >nul 2>&1

set "BRAVE_STILL_OPEN=1"
for /L %%i in (1,1,10) do (
    tasklist /FI "IMAGENAME eq brave.exe" /NH | find /I "brave.exe" >nul
    if errorlevel 1 (
        set "BRAVE_STILL_OPEN=0"
        goto :brave_closed
    )
    echo       Esperando cierre de Brave ^(%%i/10 s^)...
    ping -n 2 127.0.0.1 >nul
)

if "%BRAVE_STILL_OPEN%"=="1" (
    echo [AVISO] Brave tardo mas de 10 s; aplicando cierre forzado limpio ^(taskkill /F^)...
    taskkill /F /IM brave.exe /T >nul 2>&1
    ping -n 3 127.0.0.1 >nul
)

:brave_closed
echo [OK] Brave cerrado. Esperando 2 s para liberar bloqueos de archivos SQLite...
ping -n 3 127.0.0.1 >nul

:run_sync
echo.
echo [2/4] Ejecutando sincronizacion Edge -^> Brave...
"%PY_EXE%" "%SYNC_SCRIPT%"
set "SYNC_EXIT=%ERRORLEVEL%"

echo.
echo [3/4] Verificando resultado y limpiando RunOnce obsoleto...
set "SYNC_OK=0"
if "%SYNC_EXIT%"=="0" if exist "%RESULT_JSON%" (
    "%PY_EXE%" -c "import json,pathlib,sys; d=json.loads(pathlib.Path(r'%RESULT_JSON%').read_text(encoding='utf-8')); h=d.get('databases',{}).get('History'); ok=(d.get('status')=='COMPLETED' and isinstance(h,dict)); sys.exit(0 if ok else 2)" >nul 2>&1
    if not errorlevel 1 set "SYNC_OK=1"
)

if "%SYNC_OK%"=="1" (
    reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v BraveEdgeHistorySync /f >nul 2>&1
    echo [OK] Sincronizacion completada y entrada RunOnce BraveEdgeHistorySync limpiada.
) else (
    echo [ADVERTENCIA] La sincronizacion no confirmo estado COMPLETED en History.
    echo               Se conserva RunOnce BraveEdgeHistorySync por seguridad.
)

echo.
echo [4/4] Relanzando Brave Browser con --restore-last-session...
if exist "%BRAVE_EXE%" (
    start "" "%BRAVE_EXE%" --restore-last-session
) else (
    start "" brave.exe --restore-last-session
)

echo.
echo ==================== RESUMEN DE SINCRONIZACION ====================
if exist "%RESULT_JSON%" (
    "%PY_EXE%" -c "import json,pathlib; d=json.loads(pathlib.Path(r'%RESULT_JSON%').read_text(encoding='utf-8')); bm=d.get('bookmarks',{}); db=d.get('databases',{}); h=db.get('History'); t=db.get('Top Sites'); w=db.get('Web Data'); print('Estado:', d.get('status')); print('Marcadores -> Agregados:', bm.get('added_urls'), '| Total final:', bm.get('total_final_urls')); print('History    -> URLs insertadas:', h.get('urls_inserted'), '| Actualizadas:', h.get('urls_updated'), '| Visitas insertadas:', h.get('visits_inserted'), '| Busquedas:', h.get('search_terms_inserted'), '| Total URLs:', h.get('final_urls_total'), '| Total visitas:', h.get('final_visits_total')) if isinstance(h,dict) else print('History    ->', h); print('Top Sites  -> Insertados:', t.get('inserted_top_sites'), '| Total final:', t.get('final_top_sites')) if isinstance(t,dict) else print('Top Sites  ->', t); print('Web Data   -> Autofill insertados:', w.get('autofill_inserted'), '| Direcciones:', w.get('addresses_inserted'), '| Tokens:', w.get('address_tokens_inserted')) if isinstance(w,dict) else print('Web Data   ->', w)"
) else (
    echo [AVISO] No se encontro "%RESULT_JSON%".
)
if exist "%BRAVE_HIST%" (
    for %%F in ("%BRAVE_HIST%") do echo Tamano final de Brave Default\History: %%~zF bytes
)
echo ===================================================================
echo.
pause
endlocal
