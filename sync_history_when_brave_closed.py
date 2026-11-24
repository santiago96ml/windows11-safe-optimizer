#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Sincronizador diferido de Historial, Top Sites, Web Data y Marcadores de Edge a Brave.
Se ejecuta cuando Brave se cierra (o espera a que Brave se cierre con --wait) para
escribir sin bloqueo en las bases SQLite (History, Top Sites, Web Data) y asegurar
que Brave no sobrescriba Bookmarks al cerrarse.
"""

import os
import sys
import time
import json
import subprocess
from pathlib import Path

# Importar funciones desde migrate_edge_to_brave.py
sys.path.insert(0, str(Path(__file__).resolve().parent))
from migrate_edge_to_brave import (
    EDGE_USER_DATA,
    BRAVE_USER_DATA,
    BASE_OPT_DIR,
    find_profiles,
    is_sqlite_writable,
    merge_bookmarks,
    merge_history_db,
    merge_top_sites_db,
    merge_web_data_db,
)


def is_brave_running() -> bool:
    try:
        out = subprocess.check_output(
            ["tasklist", "/FI", "IMAGENAME eq brave.exe", "/NH"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        return "brave.exe" in out.lower()
    except Exception:
        return False


def sync_all_now(wait_for_close: bool = False, max_wait_seconds: int = 3600) -> dict:
    edge_profiles = find_profiles(EDGE_USER_DATA)
    brave_profiles = find_profiles(BRAVE_USER_DATA)
    if not edge_profiles or not brave_profiles:
        raise RuntimeError("No se encontraron perfiles de Edge o Brave.")

    edge_default = edge_profiles[0]
    brave_default = brave_profiles[0]

    if is_brave_running():
        if not wait_for_close:
            print(
                "[AVISO] Brave Browser está abierto actualmente y bloquea las bases SQLite (History, Top Sites, Web Data)."
            )
            print(
                "        Cierra Brave o ejecuta este script con '--wait' para sincronizar automáticamente apenas se cierre."
            )
            return {"status": "BRAVE_RUNNING_LOCKED"}

        print("[ESPERANDO] Esperando a que se cierre Brave Browser (brave.exe)...")
        start = time.time()
        while is_brave_running():
            if time.time() - start > max_wait_seconds:
                return {"status": "TIMEOUT_WAITING_FOR_BRAVE"}
            time.sleep(2)
        # Dar 1.5 segundos adicionales para que libere los descriptores SQLite
        time.sleep(1.5)

    print("[SINCRONIZANDO] Brave está cerrado. Aplicando migración completa a SQLite y Bookmarks...")
    bm_stats = merge_bookmarks(edge_profiles, brave_default)

    # Asegurar que la barra de marcadores sea visible en todas las pestañas de Brave
    pref_path = brave_default / "Preferences"
    if pref_path.exists():
        try:
            prefs = json.loads(pref_path.read_text(encoding="utf-8"))
            if "bookmark_bar" not in prefs or not isinstance(prefs["bookmark_bar"], dict):
                prefs["bookmark_bar"] = {}
            prefs["bookmark_bar"]["show_on_all_tabs"] = True
            pref_path.write_text(json.dumps(prefs, ensure_ascii=False), encoding="utf-8")
        except Exception:
            pass

    results = {"status": "COMPLETED", "bookmarks": bm_stats, "databases": {}}
    for db_name, merge_fn in [
        ("History", merge_history_db),
        ("Top Sites", merge_top_sites_db),
        ("Web Data", merge_web_data_db),
    ]:
        target_db = brave_default / db_name
        src_db = edge_default / db_name
        if src_db.exists() and is_sqlite_writable(target_db):
            stats = merge_fn(src_db, target_db)
            results["databases"][db_name] = stats
            print(f"  [OK] {db_name}: {json.dumps(stats, ensure_ascii=False)}")
        else:
            results["databases"][db_name] = "LOCKED_OR_MISSING"
            print(f"  [WARN] No se pudo escribir en {db_name}")

    out_log = BASE_OPT_DIR / "last_sync_result.json"
    out_log.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"[COMPLETADO] Sincronización finalizada. Registro guardado en {out_log}")
    return results


if __name__ == "__main__":
    wait_flag = "--wait" in sys.argv
    sync_all_now(wait_for_close=wait_flag)
