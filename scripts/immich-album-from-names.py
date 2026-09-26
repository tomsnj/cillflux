#!/usr/bin/env python3
"""
Rebuild an Immich album from a list of filenames.

The photographs are already in Immich; what an export still carries is
which album each name belonged to. This resolves names to asset ids and
creates the album, without re-uploading anything.

Read the index straight from Postgres rather than the search API on
purpose: /api/search/metadata's originalFileName filter is a SUBSTRING
match, not an exact one - "0190101_091427.jpg" (leading digit missing)
still returns the asset - so resolving 200 names through it means 200
queries that each need post-filtering and can silently truncate at the
page limit. One read-only SELECT is exact and instant.

Writes go through the API, never the database.

Usage:
  immich-album-from-names.py --dir  ~/amazon-albums/"Summer 2014"
  immich-album-from-names.py --names-file list.txt --album "Summer 2014"
  ... add --create to actually make the album (default is a dry run)
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.request

SERVER = os.environ.get("IMMICH_SERVER", "https://major.gs-farm.net")
KEYFILE = os.path.expanduser(os.environ.get("IMMICH_KEYFILE", "~/.immich-api-key"))
NS = os.environ.get("IMMICH_PG_NS", "immich")
SELECTOR = os.environ.get("IMMICH_PG_SELECTOR", "app=immich-postgres")

# Junk an export drops next to the photographs.
SKIP_NAMES = {".ds_store", "thumbs.db", "desktop.ini", "picasa.ini"}


def api(path, method="GET", body=None):
    with open(KEYFILE) as fh:
        key = fh.read().strip()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        SERVER + path, data=data, method=method,
        headers={"x-api-key": key, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def build_index():
    """name -> [asset id, ...] for every live asset."""
    pod = subprocess.run(
        ["kubectl", "get", "pods", "-n", NS, "-l", SELECTOR,
         "-o", "jsonpath={.items[0].metadata.name}"],
        capture_output=True, text=True, check=True).stdout.strip()
    if not pod:
        sys.exit(f"no postgres pod matching {SELECTOR} in namespace {NS}")
    out = subprocess.run(
        ["kubectl", "exec", "-n", NS, pod, "--",
         "psql", "-U", "immich", "-d", "immich", "-At", "-F\t", "-c",
         'SELECT "originalFileName", id FROM asset WHERE "deletedAt" IS NULL;'],
        capture_output=True, text=True, check=True).stdout

    exact, lower = {}, {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        name, aid = parts
        exact.setdefault(name, []).append(aid)
        lower.setdefault(name.lower(), []).append(aid)
    return exact, lower


def read_names(args):
    if args.dir:
        names = []
        for entry in sorted(os.listdir(args.dir)):
            if os.path.isfile(os.path.join(args.dir, entry)):
                names.append(entry)
        return names
    with open(args.names_file) as fh:
        # tolerate a Windows "dir" listing pasted in with paths attached
        return [os.path.basename(l.strip().replace("\\", "/"))
                for l in fh if l.strip()]


def main():
    p = argparse.ArgumentParser()
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--dir", help="exported album folder (names taken from it)")
    src.add_argument("--names-file", help="one filename per line")
    p.add_argument("--album", help="album name (default: the folder's name)")
    p.add_argument("--create", action="store_true",
                   help="actually create the album; omitted = dry run")
    p.add_argument("--album-id",
                   help="add to this existing album instead of creating one")
    args = p.parse_args()

    album = args.album or (os.path.basename(os.path.normpath(args.dir))
                           if args.dir else None)
    if not album and not args.album_id:
        sys.exit("--album is required when using --names-file")

    names = [n for n in read_names(args) if n.lower() not in SKIP_NAMES]
    if not names:
        sys.exit("no filenames found")

    exact, lower = build_index()

    resolved, ci_resolved, ambiguous, missing = {}, {}, [], []
    for n in names:
        hits = exact.get(n)
        if hits and len(hits) == 1:
            resolved[n] = hits[0]
        elif hits:
            ambiguous.append((n, len(hits)))
        else:
            hits = lower.get(n.lower())
            if hits and len(hits) == 1:
                ci_resolved[n] = hits[0]
            elif hits:
                ambiguous.append((n, len(hits)))
            else:
                missing.append(n)

    # dedupe: two source names can legitimately point at one asset
    ids, seen = [], set()
    for aid in list(resolved.values()) + list(ci_resolved.values()):
        if aid not in seen:
            seen.add(aid)
            ids.append(aid)
    print(f"album            : {album or args.album_id}")
    print(f"names in source  : {len(names)}")
    print(f"  resolved       : {len(resolved)}")
    if ci_resolved:
        print(f"  resolved (case-insensitive) : {len(ci_resolved)}")
        for n in list(ci_resolved)[:10]:
            print(f"      {n}")
    if ambiguous:
        print(f"  AMBIGUOUS      : {len(ambiguous)}  (skipped, never guessed)")
        for n, c in ambiguous[:10]:
            print(f"      {n}  -> {c} assets")
    if missing:
        print(f"  not in Immich  : {len(missing)}")
        for n in missing[:10]:
            print(f"      {n}")
        if len(missing) > 10:
            print(f"      ... and {len(missing) - 10} more")

    if not args.create:
        print(f"\nDRY RUN - would add {len(ids)} assets. Re-run with --create.")
        return

    if not ids:
        sys.exit("nothing resolved; refusing to create an empty album")

    if args.album_id:
        album_id = args.album_id
    else:
        # Case-insensitive on purpose. An exact-match guard let
        # "Charmer" through alongside an existing "charmer" on
        # 2026-09-26 - two albums differing only in capitalisation is
        # exactly the mess this is meant to prevent, and Immich will
        # not stop you.
        existing = api("/api/albums")
        clash = [a for a in existing if a["albumName"].lower() == album.lower()]
        if clash:
            found = clash[0]
            qualifier = "" if found["albumName"] == album else \
                        f" (differs from {album!r} only in case)"
            sys.exit(f"an album named {found['albumName']!r} already exists"
                     f"{qualifier}: {found['id']}, {found['assetCount']} assets."
                     f"\nPass --album-id to add to it.")
        album_id = api("/api/albums", "POST",
                       {"albumName": album, "assetIds": []})["id"]
        print(f"created album {album_id}")

    added = 0
    for i in range(0, len(ids), 500):
        chunk = ids[i:i + 500]
        for r in api(f"/api/albums/{album_id}/assets", "PUT", {"ids": chunk}):
            if r.get("success"):
                added += 1
            elif r.get("error") != "duplicate":
                print(f"  ! {r.get('id')}: {r.get('error')}")
    print(f"added {added} assets to {album!r} ({album_id})")


if __name__ == "__main__":
    main()
