#!/usr/bin/env python3
"""Seed the Homarr dashboard with every app hosted in the Pineapple cluster.

Creates one Homarr "app" per hosted service (external link + internal ping URL
so tile status reflects the in-cluster service), then places a tile for each
on a board.

Usage:
    HOMARR_API_KEY=<key> ./scripts/homarr-seed.py [--board home] [--dry-run]

Create the API key in Homarr: Management > Tools > API > Authentication tab.
HOMARR_URL defaults to https://dashboard.amdhql.org; point it at a
`kubectl port-forward -n homarr svc/homarr 7575:7575` (http://localhost:7575)
if you prefer not to go through the tunnel.

Idempotent on apps (matched by name). Board tiles are only added for apps
created in this run, so re-running never duplicates tiles.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

ICON_CDN = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons"

def svc(name, namespace, port):
    return f"http://{name}.{namespace}.svc.cluster.local:{port}"

# name, description, icon file, external href ("" = no link), internal ping URL
APPS = [
    # movietime — media stack
    ("Jellyfin",       "Movies & TV streaming",        "svg/jellyfin.svg",        "https://jellyfin.amdhql.org",   svc("jellyfin", "movietime", 8096)),
    ("Seerr",          "Media requests",               "svg/seerr.svg",           "https://seerr.amdhql.org",      svc("seerr", "movietime", 5055)),
    ("Sonarr",         "TV series management",         "svg/sonarr.svg",          "https://sonarr.amdhql.org",     svc("sonarr", "movietime", 8989)),
    ("Radarr",         "Movie management",             "svg/radarr.svg",          "https://radarr.amdhql.org",     svc("radarr", "movietime", 7878)),
    ("Prowlarr",       "Indexer manager",              "svg/prowlarr.svg",        "https://prowlarr.amdhql.org",   svc("prowlarr", "movietime", 9696)),
    ("RDT-Client",     "Real-Debrid downloads",        "svg/rdt-client.svg",      "https://rdt-client.amdhql.org", svc("rdt-client", "movietime", 6500)),
    ("Navidrome",      "Music streaming",              "svg/navidrome.svg",       "https://music.amdhql.org",      svc("navidrome", "movietime", 4533)),
    # standalone apps
    ("Immich",         "Photo & video gallery",        "svg/immich.svg",          "https://immich.amdhql.org",     svc("immich-server", "immich", 2283)),
    ("Audiobookshelf", "Audiobooks & podcasts",        "svg/audiobookshelf.svg",  "https://audiobooks.amdhql.org", svc("audiobookshelf", "audiobookshelf", 3005)),
    ("Suwayomi",       "Manga reader",                 "svg/suwayomi.svg",        "https://manga.amdhql.org",      svc("suwayomi", "suwayomi", 4567)),
    ("Firefly III",    "Personal finance",             "svg/firefly-iii.svg",     "https://money.amdhql.org",      svc("firefly-iii", "firefly-iii", 8080)),
    ("Linkding",       "Bookmark manager",             "svg/linkding.svg",        "https://linkding.amdhql.org",   svc("linkding", "linkding", 9090)),
    ("SparkyFitness",  "Fitness tracking",             "png/sparky-fitness.png",  "https://fitness.amdhql.org",    svc("sparkyfitness", "sparkyfitness", 80)),
    # infrastructure
    ("n8n",            "Workflow automation",          "svg/n8n.svg",             "https://automation.amdhql.org", svc("n8n", "n8n", 5678)),
    ("Grafana",        "Metrics & dashboards",         "svg/grafana.svg",         "https://grafana.amdhql.org",    svc("kube-prometheus-stack-grafana", "monitoring", 80)),
    ("Longhorn",       "Cluster storage UI",           "svg/longhorn.svg",        "",                              svc("longhorn-frontend", "longhorn-system", 80)),
    ("FlareSolverr",   "Scraper proxy (API only)",     "svg/flaresolverr.svg",    "",                              svc("flaresolverr", "flaresolverr", 8191)),
]

# canonical name -> name of a pre-existing, manually created Homarr app that is
# the same service. Those get enriched with a pingUrl instead of duplicated.
ALIASES = {
    "n8n": "Automation",
    "Suwayomi": "Manga",
    "Firefly III": "Money",
    "Navidrome": "Music",
    "Linkding": "bookmarks",
}


def request(base, key, method, path, body=None):
    req = urllib.request.Request(
        base.rstrip("/") + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"ApiKey": key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:500]
        sys.exit(f"{method} {path} failed: HTTP {e.code}\n{detail}")
    except urllib.error.URLError as e:
        sys.exit(f"cannot reach {base}: {e.reason}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--board", default=os.environ.get("HOMARR_BOARD", ""),
                        help="board name to place tiles on (default: your existing board, or create 'home')")
    parser.add_argument("--dry-run", action="store_true", help="print what would happen without writing")
    args = parser.parse_args()

    base = os.environ.get("HOMARR_URL", "https://dashboard.amdhql.org")
    key = os.environ.get("HOMARR_API_KEY")
    if not key:
        sys.exit("Set HOMARR_API_KEY (Homarr > Management > Tools > API > Authentication tab)")

    existing = {a["name"]: a for a in request(base, key, "GET", "/api/apps")}
    print(f"{len(existing)} apps already in Homarr")

    created = []
    for name, description, icon, href, ping_url in APPS:
        current = existing.get(name) or existing.get(ALIASES.get(name, ""))
        if current is not None:
            if current.get("pingUrl"):
                print(f"  skip   {name} ({current['name']} exists, has ping)")
                continue
            if args.dry_run:
                print(f"  would add ping to {current['name']}: {ping_url}")
                continue
            request(base, key, "PATCH", f"/api/apps/{current['id']}", {
                "name": current["name"],
                "description": current.get("description"),
                "iconUrl": current["iconUrl"],
                "href": current.get("href"),
                "pingUrl": ping_url,
            })
            print(f"  ping   {current['name']} <- {ping_url}")
            continue
        payload = {
            "name": name,
            "description": description,
            "iconUrl": f"{ICON_CDN}/{icon}",
            "href": href,
            "pingUrl": ping_url,
        }
        if args.dry_run:
            print(f"  would create {name} -> {href or '(no link)'} ping {ping_url}")
            continue
        request(base, key, "POST", "/api/apps", payload)
        print(f"  create {name}")
        created.append(name)

    if args.dry_run:
        return

    # resolve ids of everything we just created
    all_apps = {a["name"]: a["id"] for a in request(base, key, "GET", "/api/apps")}

    boards = request(base, key, "GET", "/api/boards")
    board = None
    if args.board:
        board = next((b for b in boards if b["name"] == args.board), None)
        if board is None:
            sys.exit(f"board '{args.board}' not found; existing: {[b['name'] for b in boards]}")
    elif boards:
        board = next((b for b in boards if b["name"] == "home"), boards[0])

    if board is None:
        board_name = args.board or "home"
        request(base, key, "POST", "/api/boards",
                {"name": board_name, "columnCount": 10, "isPublic": False})
        board = next(b for b in request(base, key, "GET", "/api/boards") if b["name"] == board_name)
        print(f"created board '{board_name}'")
    print(f"placing tiles on board '{board['name']}'")

    if not created:
        print("no new apps created, no tiles added (edit the board in the UI to rearrange)")
        return

    for name in created:
        request(base, key, "POST", "/api/boards/items",
                {"boardId": board["id"], "kind": "app", "options": {"appId": all_apps[name]}})
        print(f"  tile   {name}")

    print(f"\ndone: {len(created)} apps + tiles added. Open {base}/boards/{board['name']} and drag things where you want them.")


if __name__ == "__main__":
    main()
