#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Migrador No-Destructivo de Microsoft Edge (Bing) a Brave Browser
Transfiere:
  1. Marcadores / Favoritos (Bookmarks JSON + Exportación HTML Netscape)
  2. Historial de navegación y términos de búsqueda de Bing/Google (History SQLite)
  3. Sitios más visitados (Top Sites SQLite)
  4. Autocompletado de formularios y direcciones (Web Data SQLite)
"""

import os
import sys
import json
import uuid
import time
import html
import shutil
import hashlib
import sqlite3
import tempfile
from pathlib import Path

EDGE_USER_DATA = Path(os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\Edge\User Data"))
BRAVE_USER_DATA = Path(os.path.expandvars(r"%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data"))

BASE_OPT_DIR = Path(__file__).resolve().parent
BACKUP_DIR = BASE_OPT_DIR / "backup_brave_profile"
STAGED_DIR = BASE_OPT_DIR / "staged_brave_dbs"
HTML_EXPORT_PATH = BASE_OPT_DIR / "backups" / "Favoritos_Edge_para_Brave.html"


def find_profiles(user_data_dir: Path):
    if not user_data_dir.exists():
        return []
    profiles = []
    for d in sorted(user_data_dir.iterdir()):
        if d.is_dir() and (d.name == "Default" or d.name.startswith("Profile ")):
            profiles.append(d)
    return profiles


def copy_unlocked(src: Path, dst: Path):
    """Copia un archivo incluso si está abierto por el navegador."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.copy2(src, dst)
    except PermissionError:
        with open(src, "rb") as fsrc, open(dst, "wb") as fdst:
            shutil.copyfileobj(fsrc, fdst)


def ensure_backup(brave_profile: Path):
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    files = [
        "Bookmarks",
        "Bookmarks.bak",
        "History",
        "History-journal",
        "Top Sites",
        "Top Sites-journal",
        "Web Data",
        "Web Data-journal",
        "Preferences",
        "Shortcuts",
    ]
    backed_up = []
    for fname in files:
        src = brave_profile / fname
        # Guardamos backup original en .orig si aún no existe para nunca sobrescribir el estado puro
        orig_dst = BACKUP_DIR / f"{fname}.orig"
        dst = BACKUP_DIR / fname
        if src.exists():
            if not orig_dst.exists():
                copy_unlocked(src, orig_dst)
            if not dst.exists():
                copy_unlocked(src, dst)
            backed_up.append(fname)
    return backed_up


def compute_chromium_bookmark_checksum(roots: dict) -> str:
    md5 = hashlib.md5()

    def update_node(node: dict):
        md5.update(str(node["id"]).encode("ascii"))
        md5.update(node.get("name", "").encode("utf-16-le"))
        ntype = node.get("type")
        if ntype == "url":
            md5.update(b"url")
            md5.update(node.get("url", "").encode("ascii", errors="ignore"))
        elif ntype == "folder":
            md5.update(b"folder")
            for child in node.get("children", []):
                update_node(child)

    for root_name in ["bookmark_bar", "other", "synced"]:
        if root_name in roots and isinstance(roots[root_name], dict):
            update_node(roots[root_name])
    return md5.hexdigest()


def get_edge_top_sites(edge_profile: Path):
    top_db = edge_profile / "Top Sites"
    if not top_db.exists():
        return []
    tmp_db = Path(tempfile.gettempdir()) / f"edge_top_sites_{os.getpid()}.db"
    copy_unlocked(top_db, tmp_db)
    sites = []
    try:
        conn = sqlite3.connect(str(tmp_db))
        cur = conn.cursor()
        for rank, title, url in cur.execute(
            "SELECT url_rank, title, url FROM top_sites ORDER BY url_rank ASC"
        ).fetchall():
            if url and not url.startswith("edge://"):
                sites.append({"title": title or url, "url": url, "rank": rank})
        conn.close()
    except Exception:
        pass
    finally:
        if tmp_db.exists():
            try:
                tmp_db.unlink()
            except Exception:
                pass
    return sites


def merge_bookmarks(edge_profiles, brave_profile: Path):
    """
    Fusiona de manera no destructiva todos los marcadores de todos los perfiles de Edge
    en el archivo Bookmarks de Brave y genera también un archivo HTML importable.
    """
    brave_bm_path = brave_profile / "Bookmarks"
    orig_bm_path = BACKUP_DIR / "Bookmarks.orig"

    # Leemos el archivo actual de Brave
    if brave_bm_path.exists():
        with open(brave_bm_path, "r", encoding="utf-8") as f:
            brave_bm = json.load(f)
    elif orig_bm_path.exists():
        with open(orig_bm_path, "r", encoding="utf-8") as f:
            brave_bm = json.load(f)
    else:
        raise FileNotFoundError(f"No se encontró Bookmarks en {brave_bm_path}")

    # Recolectar máximo ID y GUIDs existentes en Brave
    max_id = 0
    used_guids = set()

    def scan_tree(node):
        nonlocal max_id
        if not isinstance(node, dict):
            return
        try:
            nid = int(node.get("id", 0))
            if nid > max_id:
                max_id = nid
        except ValueError:
            pass
        if "guid" in node:
            used_guids.add(node["guid"].lower())
        for child in node.get("children", []):
            scan_tree(child)

    for rname, rnode in brave_bm.get("roots", {}).items():
        scan_tree(rnode)

    def next_id():
        nonlocal max_id
        max_id += 1
        return str(max_id)

    def ensure_unique_guid(candidate=None):
        if candidate and candidate.lower() not in used_guids:
            used_guids.add(candidate.lower())
            return candidate.lower()
        new_g = str(uuid.uuid4()).lower()
        while new_g in used_guids:
            new_g = str(uuid.uuid4()).lower()
        used_guids.add(new_g)
        return new_g

    now_webkit = str(int((time.time() + 11644473600) * 1_000_000))

    stats = {
        "edge_raw_urls": 0,
        "edge_raw_folders": 0,
        "brave_existing_urls": 0,
        "added_urls": 0,
        "added_folders": 0,
        "skipped_duplicates_or_internal": 0,
        "top_sites_bookmarked": 0,
        "total_final_urls": 0,
    }

    def count_urls(node):
        if not isinstance(node, dict):
            return 0
        c = 1 if node.get("type") == "url" else 0
        for ch in node.get("children", []):
            c += count_urls(ch)
        return c

    for rname in ["bookmark_bar", "other", "synced"]:
        stats["brave_existing_urls"] += count_urls(brave_bm.get("roots", {}).get(rname, {}))

    def count_edge_raw(node, is_root=False):
        if not isinstance(node, dict):
            return
        if node.get("type") == "url":
            stats["edge_raw_urls"] += 1
        elif node.get("type") == "folder":
            if not is_root:
                stats["edge_raw_folders"] += 1
            for ch in node.get("children", []):
                count_edge_raw(ch, False)

    def merge_folder_children(target_folder: dict, source_children: list):
        if "children" not in target_folder:
            target_folder["children"] = []

        existing_urls = {
            c.get("url"): c
            for c in target_folder["children"]
            if c.get("type") == "url" and c.get("url")
        }
        existing_folders = {
            c.get("name", "").strip().lower(): c
            for c in target_folder["children"]
            if c.get("type") == "folder"
        }

        for src_child in source_children:
            ctype = src_child.get("type")
            if ctype == "url":
                url = src_child.get("url", "")
                if not url or url.startswith("edge://"):
                    stats["skipped_duplicates_or_internal"] += 1
                    continue
                if url in existing_urls:
                    stats["skipped_duplicates_or_internal"] += 1
                    continue
                new_node = {
                    "date_added": src_child.get("date_added", now_webkit),
                    "date_last_used": src_child.get("date_last_used", "0"),
                    "guid": ensure_unique_guid(src_child.get("guid")),
                    "id": next_id(),
                    "meta_info": {"power_bookmark_meta": ""},
                    "name": src_child.get("name", url),
                    "type": "url",
                    "url": url,
                }
                target_folder["children"].append(new_node)
                existing_urls[url] = new_node
                stats["added_urls"] += 1

            elif ctype == "folder":
                fname = src_child.get("name", "Carpeta")
                fkey = fname.strip().lower()
                if fkey in existing_folders:
                    dst_subfolder = existing_folders[fkey]
                else:
                    dst_subfolder = {
                        "children": [],
                        "date_added": src_child.get("date_added", now_webkit),
                        "date_last_used": src_child.get("date_last_used", "0"),
                        "date_modified": src_child.get("date_modified", now_webkit),
                        "guid": ensure_unique_guid(src_child.get("guid")),
                        "id": next_id(),
                        "name": fname,
                        "type": "folder",
                    }
                    target_folder["children"].append(dst_subfolder)
                    existing_folders[fkey] = dst_subfolder
                    stats["added_folders"] += 1

                merge_folder_children(dst_subfolder, src_child.get("children", []))

    for eprof in edge_profiles:
        ebm_path = eprof / "Bookmarks"
        if not ebm_path.exists():
            continue
        with open(ebm_path, "r", encoding="utf-8") as f:
            ebm = json.load(f)

        eroots = ebm.get("roots", {})
        for rname in ["bookmark_bar", "other", "synced"]:
            if rname in eroots and isinstance(eroots[rname], dict):
                count_edge_raw(eroots[rname], is_root=True)
                if rname in brave_bm.get("roots", {}):
                    merge_folder_children(
                        brave_bm["roots"][rname],
                        eroots[rname].get("children", []),
                    )

        # Agregar también carpeta con los Top Sites de Edge/Bing en "Otros favoritos"
        top_sites = get_edge_top_sites(eprof)
        if top_sites and "other" in brave_bm.get("roots", {}):
            top_folder_node = {
                "type": "folder",
                "name": "Sitios Frecuentes (Edge y Bing)",
                "date_added": now_webkit,
                "date_modified": now_webkit,
                "date_last_used": "0",
                "children": [
                    {
                        "type": "url",
                        "name": ts["title"],
                        "url": ts["url"],
                        "date_added": now_webkit,
                        "date_last_used": "0",
                    }
                    for ts in top_sites
                ],
            }
            before_added = stats["added_urls"]
            merge_folder_children(brave_bm["roots"]["other"], [top_folder_node])
            stats["top_sites_bookmarked"] = stats["added_urls"] - before_added

    for rname in ["bookmark_bar", "other", "synced"]:
        stats["total_final_urls"] += count_urls(brave_bm.get("roots", {}).get(rname, {}))

    # Recalcular checksum MD5 oficial de Chromium
    brave_bm["checksum"] = compute_chromium_bookmark_checksum(brave_bm["roots"])

    # Guardar en Brave Default\Bookmarks, Default\Bookmarks.bak y en carpeta staged
    STAGED_DIR.mkdir(parents=True, exist_ok=True)
    for out_path in [
        brave_bm_path,
        brave_profile / "Bookmarks.bak",
        STAGED_DIR / "Bookmarks",
    ]:
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(brave_bm, f, indent=3, ensure_ascii=False)

    # Exportar archivo HTML en formato Netscape Bookmark para importación de 1 clic
    export_bookmarks_html(brave_bm["roots"], HTML_EXPORT_PATH)

    return stats


def export_bookmarks_html(roots: dict, out_html: Path):
    lines = [
        "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
        "<!-- This is an automatically generated file.",
        "     It will be read and overwritten.",
        "     DO NOT EDIT! -->",
        '<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">',
        "<TITLE>Bookmarks</TITLE>",
        "<H1>Bookmarks</H1>",
        "<DL><p>",
    ]

    def render_node(node: dict, indent: int = 1):
        pad = "    " * indent
        ntype = node.get("type")
        name = html.escape(node.get("name", ""))
        if ntype == "url":
            url = html.escape(node.get("url", ""), quote=True)
            lines.append(f'{pad}<DT><A HREF="{url}">{name}</A>')
        elif ntype == "folder":
            lines.append(f"{pad}<DT><H3>{name}</H3>")
            lines.append(f"{pad}<DL><p>")
            for child in node.get("children", []):
                render_node(child, indent + 1)
            lines.append(f"{pad}</DL><p>")

    if "bookmark_bar" in roots:
        pad = "    "
        bbar = roots["bookmark_bar"]
        bname = html.escape(bbar.get("name", "Barra de favoritos"))
        lines.append(f'{pad}<DT><H3 PERSONAL_TOOLBAR_FOLDER="true">{bname}</H3>')
        lines.append(f"{pad}<DL><p>")
        for ch in bbar.get("children", []):
            render_node(ch, 2)
        lines.append(f"{pad}</DL><p>")

    for rkey in ["other", "synced"]:
        if rkey in roots and roots[rkey].get("children"):
            for ch in roots[rkey].get("children", []):
                render_node(ch, 1)

    lines.append("</DL><p>")
    out_html.write_text("\n".join(lines), encoding="utf-8")


def is_sqlite_writable(db_path: Path) -> bool:
    if not db_path.exists():
        return False
    try:
        conn = sqlite3.connect(str(db_path), timeout=1.0)
        cur = conn.cursor()
        cur.execute("BEGIN IMMEDIATE")
        conn.rollback()
        conn.close()
        return True
    except Exception:
        return False


def merge_history_db(edge_hist_src: Path, target_hist_db: Path) -> dict:
    """
    Fusiona urls, visits y keyword_search_terms desde una copia de Edge History
    hacia target_hist_db (sin duplicar URLs ni visitas).
    """
    tmp_edge = Path(tempfile.gettempdir()) / f"edge_hist_{os.getpid()}.db"
    copy_unlocked(edge_hist_src, tmp_edge)

    res = {
        "edge_urls_total": 0,
        "edge_visits_total": 0,
        "edge_search_terms_total": 0,
        "urls_inserted": 0,
        "urls_updated": 0,
        "visits_inserted": 0,
        "search_terms_inserted": 0,
        "final_urls_total": 0,
        "final_visits_total": 0,
        "final_search_terms_total": 0,
    }

    try:
        econn = sqlite3.connect(str(tmp_edge))
        ecur = econn.cursor()

        bconn = sqlite3.connect(str(target_hist_db), timeout=5.0)
        bcur = bconn.cursor()

        res["edge_urls_total"] = ecur.execute("SELECT COUNT(*) FROM urls").fetchone()[0]
        res["edge_visits_total"] = ecur.execute("SELECT COUNT(*) FROM visits").fetchone()[0]
        res["edge_search_terms_total"] = ecur.execute(
            "SELECT COUNT(*) FROM keyword_search_terms"
        ).fetchone()[0]

        # Mapa de URLs existentes en Brave: url -> (id, visit_count, typed_count, last_visit_time)
        existing_urls = {}
        for row in bcur.execute(
            "SELECT id, url, visit_count, typed_count, last_visit_time FROM urls"
        ).fetchall():
            existing_urls[row[1]] = (row[0], row[2], row[3], row[4])

        edge_to_brave_url_id = {}

        edge_urls = ecur.execute(
            "SELECT id, url, title, visit_count, typed_count, last_visit_time, hidden FROM urls"
        ).fetchall()

        for eid, url, title, vcount, tcount, last_vtime, hidden in edge_urls:
            if not url or url.startswith("edge://"):
                continue
            if url in existing_urls:
                bid, bvcount, btcount, blast = existing_urls[url]
                edge_to_brave_url_id[eid] = bid
                new_vcount = max(bvcount or 0, vcount or 0)
                new_tcount = max(btcount or 0, tcount or 0)
                new_last = max(blast or 0, last_vtime or 0)
                if (new_vcount, new_tcount, new_last) != (bvcount, btcount, blast):
                    bcur.execute(
                        "UPDATE urls SET visit_count=?, typed_count=?, last_visit_time=? WHERE id=?",
                        (new_vcount, new_tcount, new_last, bid),
                    )
                    res["urls_updated"] += 1
            else:
                bcur.execute(
                    "INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden) VALUES (?, ?, ?, ?, ?, ?)",
                    (url, title or "", vcount or 1, tcount or 0, last_vtime or 0, hidden or 0),
                )
                bid = bcur.lastrowid
                existing_urls[url] = (bid, vcount, tcount, last_vtime)
                edge_to_brave_url_id[eid] = bid
                res["urls_inserted"] += 1

        # Evitar visitas duplicadas por (url, visit_time)
        existing_visits = set(
            bcur.execute("SELECT url, visit_time FROM visits").fetchall()
        )

        edge_visits = ecur.execute(
            """
            SELECT url, visit_time, external_referrer_url, transition, segment_id,
                   visit_duration, incremented_omnibox_typed_score,
                   originator_cache_guid, originator_visit_id, originator_from_visit,
                   originator_opener_visit, is_known_to_sync,
                   consider_for_ntp_most_visited, visited_link_id, app_id
            FROM visits
            """
        ).fetchall()

        for vrow in edge_visits:
            e_uid = vrow[0]
            vtime = vrow[1]
            b_uid = edge_to_brave_url_id.get(e_uid)
            if not b_uid:
                continue
            if (b_uid, vtime) in existing_visits:
                continue
            bcur.execute(
                """
                INSERT INTO visits (
                    url, visit_time, from_visit, external_referrer_url, transition,
                    segment_id, visit_duration, incremented_omnibox_typed_score,
                    opener_visit, originator_cache_guid, originator_visit_id,
                    originator_from_visit, originator_opener_visit, is_known_to_sync,
                    consider_for_ntp_most_visited, visited_link_id, app_id
                ) VALUES (?, ?, 0, ?, ?, 0, ?, ?, 0, ?, ?, ?, ?, ?, ?, 0, ?)
                """,
                (
                    b_uid,
                    vtime,
                    vrow[2] or "",
                    vrow[3] or 0,
                    vrow[5] or 0,
                    vrow[6] or 0,
                    vrow[7] or "",
                    vrow[8] or 0,
                    vrow[9] or 0,
                    vrow[10] or 0,
                    vrow[11] or 0,
                    vrow[12] or 1,
                    vrow[14],
                ),
            )
            existing_visits.add((b_uid, vtime))
            res["visits_inserted"] += 1

        # Fusionar keyword_search_terms
        existing_terms = set(
            bcur.execute("SELECT url_id, normalized_term FROM keyword_search_terms").fetchall()
        )
        for kw_id, e_uid, term, norm_term in ecur.execute(
            "SELECT keyword_id, url_id, term, normalized_term FROM keyword_search_terms"
        ).fetchall():
            b_uid = edge_to_brave_url_id.get(e_uid)
            if not b_uid:
                continue
            if (b_uid, norm_term) in existing_terms:
                continue
            bcur.execute(
                "INSERT INTO keyword_search_terms (keyword_id, url_id, term, normalized_term) VALUES (?, ?, ?, ?)",
                (kw_id, b_uid, term, norm_term),
            )
            existing_terms.add((b_uid, norm_term))
            res["search_terms_inserted"] += 1

        bconn.commit()

        res["final_urls_total"] = bcur.execute("SELECT COUNT(*) FROM urls").fetchone()[0]
        res["final_visits_total"] = bcur.execute("SELECT COUNT(*) FROM visits").fetchone()[0]
        res["final_search_terms_total"] = bcur.execute(
            "SELECT COUNT(*) FROM keyword_search_terms"
        ).fetchone()[0]

        bconn.close()
        econn.close()
    finally:
        if tmp_edge.exists():
            try:
                tmp_edge.unlink()
            except Exception:
                pass

    return res


def merge_top_sites_db(edge_top_src: Path, target_top_db: Path) -> dict:
    tmp_edge = Path(tempfile.gettempdir()) / f"edge_top_{os.getpid()}.db"
    copy_unlocked(edge_top_src, tmp_edge)
    res = {"edge_top_sites": 0, "inserted_top_sites": 0, "final_top_sites": 0}
    try:
        econn = sqlite3.connect(str(tmp_edge))
        ecur = econn.cursor()
        bconn = sqlite3.connect(str(target_top_db), timeout=5.0)
        bcur = bconn.cursor()

        edge_rows = ecur.execute(
            "SELECT url, url_rank, title FROM top_sites ORDER BY url_rank ASC"
        ).fetchall()
        res["edge_top_sites"] = len(edge_rows)

        existing = {
            r[0] for r in bcur.execute("SELECT url FROM top_sites").fetchall()
        }
        max_rank_row = bcur.execute("SELECT MAX(url_rank) FROM top_sites").fetchone()
        next_rank = (max_rank_row[0] + 1) if (max_rank_row and max_rank_row[0] is not None) else 0

        for url, _, title in edge_rows:
            if not url or url.startswith("edge://") or url in existing:
                continue
            bcur.execute(
                "INSERT INTO top_sites (url, url_rank, title) VALUES (?, ?, ?)",
                (url, next_rank, title or ""),
            )
            existing.add(url)
            next_rank += 1
            res["inserted_top_sites"] += 1

        bconn.commit()
        res["final_top_sites"] = bcur.execute("SELECT COUNT(*) FROM top_sites").fetchone()[0]
        bconn.close()
        econn.close()
    finally:
        if tmp_edge.exists():
            try:
                tmp_edge.unlink()
            except Exception:
                pass
    return res


def merge_web_data_db(edge_web_src: Path, target_web_db: Path) -> dict:
    tmp_edge = Path(tempfile.gettempdir()) / f"edge_web_{os.getpid()}.db"
    copy_unlocked(edge_web_src, tmp_edge)
    res = {
        "edge_autofill": 0,
        "autofill_inserted": 0,
        "final_autofill": 0,
        "edge_addresses": 0,
        "addresses_inserted": 0,
        "address_tokens_inserted": 0,
    }
    try:
        econn = sqlite3.connect(str(tmp_edge))
        ecur = econn.cursor()
        bconn = sqlite3.connect(str(target_web_db), timeout=5.0)
        bcur = bconn.cursor()

        edge_af = ecur.execute(
            "SELECT name, value, value_lower, date_created, date_last_used, count FROM autofill"
        ).fetchall()
        res["edge_autofill"] = len(edge_af)

        existing_af = {
            (r[0], r[1])
            for r in bcur.execute("SELECT name, value FROM autofill").fetchall()
        }
        for name, val, val_low, d_cr, d_lu, cnt in edge_af:
            if (name, val) in existing_af:
                continue
            bcur.execute(
                "INSERT INTO autofill (name, value, value_lower, date_created, date_last_used, count) VALUES (?, ?, ?, ?, ?, ?)",
                (name, val, val_low, d_cr, d_lu, cnt),
            )
            existing_af.add((name, val))
            res["autofill_inserted"] += 1

        # Addresses & address_type_tokens
        edge_addr = ecur.execute(
            "SELECT guid, use_count, use_date, date_modified, language_code, label, initial_creator_id, record_type FROM addresses"
        ).fetchall()
        res["edge_addresses"] = len(edge_addr)
        existing_guids = {
            r[0] for r in bcur.execute("SELECT guid FROM addresses").fetchall()
        }
        for row in edge_addr:
            if row[0] not in existing_guids:
                bcur.execute(
                    "INSERT INTO addresses (guid, use_count, use_date, date_modified, language_code, label, initial_creator_id, record_type) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    row,
                )
                existing_guids.add(row[0])
                res["addresses_inserted"] += 1

        existing_tok = {
            (r[0], r[1])
            for r in bcur.execute("SELECT guid, type FROM address_type_tokens").fetchall()
        }
        for row in ecur.execute(
            "SELECT guid, type, value, verification_status, observations FROM address_type_tokens"
        ).fetchall():
            if (row[0], row[1]) not in existing_tok:
                bcur.execute(
                    "INSERT INTO address_type_tokens (guid, type, value, verification_status, observations) VALUES (?, ?, ?, ?, ?)",
                    row,
                )
                existing_tok.add((row[0], row[1]))
                res["address_tokens_inserted"] += 1

        bconn.commit()
        res["final_autofill"] = bcur.execute("SELECT COUNT(*) FROM autofill").fetchone()[0]
        bconn.close()
        econn.close()
    finally:
        if tmp_edge.exists():
            try:
                tmp_edge.unlink()
            except Exception:
                pass
    return res


def run_migration():
    edge_profiles = find_profiles(EDGE_USER_DATA)
    brave_profiles = find_profiles(BRAVE_USER_DATA)

    if not edge_profiles:
        raise RuntimeError(f"No se encontraron perfiles de Edge en {EDGE_USER_DATA}")
    if not brave_profiles:
        raise RuntimeError(f"No se encontraron perfiles de Brave en {BRAVE_USER_DATA}")

    brave_default = brave_profiles[0]
    edge_default = edge_profiles[0]

    print(f"[1/4] Creando copia de seguridad de Brave en: {BACKUP_DIR}")
    backed = ensure_backup(brave_default)
    print(f"      Archivos respaldados: {', '.join(backed)}")

    print(f"[2/4] Fusionando Marcadores (Bookmarks JSON + HTML Export)...")
    bm_stats = merge_bookmarks(edge_profiles, brave_default)
    print(f"      Estadísticas Bookmarks: {json.dumps(bm_stats, ensure_ascii=False)}")
    print(f"      Archivo HTML exportado en: {HTML_EXPORT_PATH}")

    print(f"[3/4] Preparando y verificando fusión SQLite (History, Top Sites, Web Data)...")
    STAGED_DIR.mkdir(parents=True, exist_ok=True)
    for db_file in ["History", "Top Sites", "Web Data"]:
        copy_unlocked(brave_default / db_file, STAGED_DIR / db_file)

    hist_stats = merge_history_db(edge_default / "History", STAGED_DIR / "History")
    top_stats = merge_top_sites_db(edge_default / "Top Sites", STAGED_DIR / "Top Sites")
    web_stats = merge_web_data_db(edge_default / "Web Data", STAGED_DIR / "Web Data")

    print(f"      Estadísticas History (Staged): {json.dumps(hist_stats, ensure_ascii=False)}")
    print(f"      Estadísticas Top Sites (Staged): {json.dumps(top_stats, ensure_ascii=False)}")
    print(f"      Estadísticas Web Data (Staged): {json.dumps(web_stats, ensure_ascii=False)}")

    print(f"[4/4] Verificando si las bases SQLite de Brave están desbloqueadas...")
    live_synced = {}
    for db_name, merge_fn in [
        ("History", merge_history_db),
        ("Top Sites", merge_top_sites_db),
        ("Web Data", merge_web_data_db),
    ]:
        target_db = brave_default / db_name
        if is_sqlite_writable(target_db):
            merge_fn(edge_default / db_name, target_db)
            live_synced[db_name] = "SYNCED_LIVE"
            print(f"      [OK] {db_name} fusionada directamente en el perfil activo de Brave.")
        else:
            live_synced[db_name] = "STAGED_LOCKED_BY_RUNNING_BRAVE"
            print(
                f"      [INFO] {db_name} está bloqueada porque Brave está abierto; lista en {STAGED_DIR / db_name} y para sync_history_when_brave_closed.py"
            )

    summary = {
        "edge_profiles": [str(p) for p in edge_profiles],
        "brave_profile": str(brave_default),
        "backup_dir": str(BACKUP_DIR),
        "staged_dir": str(STAGED_DIR),
        "html_export": str(HTML_EXPORT_PATH),
        "bookmarks": bm_stats,
        "history": hist_stats,
        "top_sites": top_stats,
        "web_data": web_stats,
        "live_sqlite_status": live_synced,
    }
    summary_path = BASE_OPT_DIR / "migration_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    return summary


if __name__ == "__main__":
    run_migration()
