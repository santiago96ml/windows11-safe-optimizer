# Windows 11 Safe Optimizer & Edge-to-Brave Migrator

Auditable, reversible Windows 10/11 gaming & performance optimization scripts (inspired by OptiJuegos, AtlasOS, and ReviOS) paired with a non-destructive Python SQLite + Bookmarks migrator from **Microsoft Edge** to **Brave Browser**.

Unlike destructive one-way "debloaters", every tweak leaves Windows Update, Microsoft Defender, Bluetooth, Wi-Fi, Audio, Printing, and Xbox Game Pass intact and exports registry/service/profile backups for **full one-click rollback**.

## Included Tools

### 1. Admin System Optimizer (`OPTIMIZAR_WINDOWS_PRO.bat` / `optimizar_windows_admin.ps1`)
- Creates a System Restore checkpoint (`Antes_OptiWindows_Antigravity`) and exports original `PriorityControl`, `SystemProfile`, `GraphicsDrivers`, `SvcHostSplitThresholdInKB`, and service startup modes under `backup_reg\`.
- Disables telemetry services (`DiagTrack`, `dmwappushservice`, etc.) and CEIP telemetry scheduled tasks safely.
- Applies low-latency `Win32PrioritySeparation = 0x26`, MMCSS Gaming (`SystemResponsiveness = 0`, `NetworkThrottlingIndex = 0xFFFFFFFF`), `PowerThrottlingOff = 1`, HAGS (`HwSchMode = 2`), dynamic `SvcHostSplitThresholdInKB`, NTFS `disablelastaccess = 1`, `bcdedit /set disabledynamictick yes`, and privacy policies (`AllowTelemetry = 0`).
- Runs a native C# `psapi.dll` `EmptyWorkingSet` RAM trim pass with a Before vs. After memory summary.
- **Full Rollback:** Run **`restaurar_windows_original.bat`** as Administrator to restore exported `.reg` files, original service states from `services_backup.csv`, scheduled tasks, Balanced power plan, and BCD/NTFS defaults.

### 2. Live User-Space Optimizer (`run_live_user_opt.ps1`)
- Non-admin pass for safe `HKCU` gaming/UI tweaks (disables `GameDVR`), stale `$env:TEMP` cleanup, and user-space working set trim.

### 3. Non-Destructive Edge → Brave Migrator (`migrate_edge_to_brave.py` & `SINCRONIZAR_HISTORIAL_BRAVE.bat`)
- Backs up your untouched Brave profile files (`*.orig`) under `backup_brave_profile\`.
- Merges **Bookmarks** (Chromium JSON with recalculated MD5 checksum + Netscape HTML export), **History**, **Top Sites**, and **Autofill / Web Data** cleanly via SQLite.
- `SINCRONIZAR_HISTORIAL_BRAVE.bat` cleanly closes Brave (or `sync_history_when_brave_closed.py --wait` waits for exit), syncs locked SQLite DBs without corruption, and relaunches Brave with `--restore-last-session`.

### 4. Research Reference
- [INVESTIGACION_OPTIJUEGOS_ATLAS_REVIOS.md](./INVESTIGACION_OPTIJUEGOS_ATLAS_REVIOS.md): Technical comparison of safe vs. risky Windows tuning practices.

## Quick Start

```powershell
# Admin optimization (UAC prompt + auto backup in backup_reg\)
.\OPTIMIZAR_WINDOWS_PRO.bat

# Revert all system-level changes cleanly
.\restaurar_windows_original.bat

# Live non-admin RAM & HKCU pass
powershell -ExecutionPolicy Bypass -File .\run_live_user_opt.ps1

# Migrate Edge data to Brave safely
python migrate_edge_to_brave.py
```

## License

MIT — see [LICENSE](./LICENSE).
