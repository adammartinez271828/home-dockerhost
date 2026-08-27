#!/usr/bin/env python3
"""Tiny Tandoor Recipes API client for the add-recipe skill (stdlib only).

Config (env vars win over the file):
  TANDOOR_URL        base URL, default http://recipes.local
  TANDOOR_API_TOKEN  API token from Tandoor: Settings -> API -> new token (scope: read write)
  ...or put TANDOOR_API_TOKEN=... in env.d/tandoor-api.env (gitignored) at the repo root.

Subcommands:
  check                      verify URL + token (prints the space name)
  search QUERY               fuzzy search recipes by name (dupe check)
  scrape --url URL           let Tandoor scrape a recipe page -> recipe_json on stdout
  scrape --data FILE         parse a schema.org Recipe JSON-LD (or HTML) file -> recipe_json
  jsonld URL -o FILE         fetch a page here (direct, then Wayback Machine) and extract its
                             schema.org Recipe JSON-LD -- for sites that block Tandoor's scraper
  preview FILE               human-readable summary of a recipe_json file
  create FILE [--no-image]   POST the recipe_json; then attach its `image` URL if present
  image ID (--url U|--file F) set/replace a recipe's image
  get ID -o FILE             fetch an existing recipe as JSON (edit it, then `update`)
  markdown ID [ID…] [-o DIR] render recipe(s) as Markdown (stdout, or one .md per recipe in DIR)
  update FILE                PUT an edited recipe JSON back (must contain its `id`)
  delete ID                  delete a recipe (undo a bad import)
"""
import argparse
import json
import mimetypes
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
ENV_FILE = REPO_ROOT / "env.d" / "tandoor-api.env"


def load_config():
    cfg = {}
    if ENV_FILE.is_file():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip("'\"")
    url = os.environ.get("TANDOOR_URL") or cfg.get("TANDOOR_URL") or "http://recipes.local"
    token = os.environ.get("TANDOOR_API_TOKEN") or cfg.get("TANDOOR_API_TOKEN")
    if not token:
        die(f"no API token: set TANDOOR_API_TOKEN or add it to {ENV_FILE}\n"
            "  (create one in Tandoor: Settings -> API -> Create, scope 'read write')")
    return url.rstrip("/"), token


def die(msg, code=1):
    print(f"tandoor.py: {msg}", file=sys.stderr)
    sys.exit(code)


def request(method, path, body=None, content_type=None, expect=(200, 201, 204), hint500=None):
    base, token = load_config()
    req = urllib.request.Request(base + path, data=body, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/json")
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = resp.read()
            status = resp.status
    except urllib.error.HTTPError as e:
        raw = e.read()
        status = e.code
    except urllib.error.URLError as e:
        die(f"cannot reach {base}: {e.reason}")
    text = raw.decode("utf-8", "replace")
    if status not in expect:
        hint = ""
        if status in (401, 403):
            hint = " (bad/expired token, or token lacks the 'write' scope?)"
        elif status == 500 and hint500:
            hint = f"\n  {hint500}"
        die(f"{method} {path} -> HTTP {status}{hint}\n{text[:2000]}")
    if not raw:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        die(f"{method} {path} -> non-JSON response:\n{text[:2000]}")


def post_json(path, obj, hint500=None, **kw):
    return request("POST", path, json.dumps(obj).encode(), "application/json", hint500=hint500, **kw)


def multipart(fields, files=()):
    """Encode form fields + (name, filename, bytes) files as multipart/form-data."""
    boundary = "----tandoor" + uuid.uuid4().hex
    out = bytearray()
    for name, value in fields.items():
        out += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").encode()
    for name, filename, data in files:
        ctype = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        out += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; "
                f"filename=\"{filename}\"\r\nContent-Type: {ctype}\r\n\r\n").encode()
        out += data + b"\r\n"
    out += f"--{boundary}--\r\n".encode()
    return bytes(out), f"multipart/form-data; boundary={boundary}"


def recipe_link(rid):
    base, _ = load_config()
    return f"{base}/view/recipe/{rid}"


# ---------------------------------------------------------------- commands

def cmd_check(_):
    spaces = request("GET", "/api/space/")
    names = [s.get("name") for s in (spaces if isinstance(spaces, list) else spaces.get("results", []))]
    base, _ = load_config()
    print(f"OK: {base} (space: {', '.join(map(str, names)) or '?'})")


def cmd_search(a):
    q = urllib.parse.quote(a.query)
    res = request("GET", f"/api/recipe/?query={q}&page_size={a.limit}")
    hits = res.get("results", [])
    if not hits:
        print("no matches")
        return
    for r in hits:
        print(f"{r['id']:>5}  {r['name']}  {('<- ' + r['source_url']) if r.get('source_url') else ''}".rstrip())


def cmd_scrape(a):
    if a.url:
        payload = {"url": a.url}
    else:
        data = Path(a.data).read_text()
        # the server runs unquote() on `data`; pre-quote so '%' in text survives round-trip
        payload = {"data": urllib.parse.quote(data)}
    res = post_json("/api/recipe-from-source/", payload, expect=(200,),
                    hint500="Tandoor's scraper crashed -- the site probably blocks bots "
                            "(Vercel/Cloudflare checkpoint). Try: tandoor.py jsonld URL -o FILE, "
                            "then scrape --data FILE")
    if res.get("error"):
        die(f"import failed: {res.get('msg')}")
    rj = res["recipe_json"]
    if a.url and not rj.get("source_url"):
        rj["source_url"] = a.url
    images = res.get("recipe_images") or []
    out = json.dumps(rj, indent=2, ensure_ascii=False)
    if a.output:
        Path(a.output).write_text(out)
        print(f"wrote {a.output}", file=sys.stderr)
    else:
        print(out)
    if res.get("duplicate"):
        print("WARNING: duplicate=true -- a recipe with this source_url already exists", file=sys.stderr)
    if images:
        print(f"other candidate images ({len(images)}):", file=sys.stderr)
        for i in images[:10]:
            print(f"  {i}", file=sys.stderr)


UA = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"


def fetch_html(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode("utf-8", "replace"), resp.status


def find_recipe_ldjson(html):
    """Return the first schema.org Recipe object embedded in the page, or None."""
    found = []

    def walk(o):
        if isinstance(o, dict):
            t = o.get("@type")
            if t == "Recipe" or (isinstance(t, list) and "Recipe" in t):
                found.append(o)
                return
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    for block in re.findall(r"<script[^>]*type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>", html, re.S):
        try:
            walk(json.loads(block.strip()))
        except json.JSONDecodeError:
            continue
        if found:
            return found[0]
    return None


def cmd_jsonld(a):
    url = a.url
    recipe, src = None, None
    try:
        html, _ = fetch_html(url)
        recipe, src = find_recipe_ldjson(html), "direct"
        if not recipe:
            print("direct fetch returned no Recipe JSON-LD (bot check?); trying Wayback Machine", file=sys.stderr)
    except (urllib.error.HTTPError, urllib.error.URLError) as e:
        print(f"direct fetch failed ({e}); trying Wayback Machine", file=sys.stderr)
    if not recipe:
        avail_url = "https://archive.org/wayback/available?url=" + urllib.parse.quote(url, safe="")
        try:
            with urllib.request.urlopen(avail_url, timeout=30) as resp:
                snap = json.load(resp).get("archived_snapshots", {}).get("closest")
        except (urllib.error.URLError, json.JSONDecodeError) as e:
            die(f"Wayback lookup failed: {e}")
        if not snap or not snap.get("available"):
            die("no Wayback snapshot; save the page from a browser (Ctrl+S, HTML only) and use scrape --data page.html")
        ts = snap["timestamp"]
        raw_url = f"https://web.archive.org/web/{ts}id_/{url}"
        try:
            html, _ = fetch_html(raw_url)
        except (urllib.error.HTTPError, urllib.error.URLError) as e:
            die(f"Wayback fetch failed: {e}")
        recipe, src = find_recipe_ldjson(html), f"wayback snapshot {ts[:8]}"
        if not recipe:
            die("Wayback copy has no Recipe JSON-LD; save the page from a browser and use scrape --data page.html")
        # strip archive.org prefixes from any URLs (image etc.)
        wb = re.compile(r"https?://web\.archive\.org/web/\d+(?:id_|im_)?/")

        def clean(o):
            if isinstance(o, str):
                return wb.sub("", o)
            if isinstance(o, dict):
                return {k: clean(v) for k, v in o.items()}
            if isinstance(o, list):
                return [clean(v) for v in o]
            return o
        recipe = clean(recipe)
    recipe["url"] = url  # so Tandoor records the real source_url
    out = json.dumps(recipe, indent=1, ensure_ascii=False)
    if a.output:
        Path(a.output).write_text(out)
        print(f"wrote {a.output} ({src}): {recipe.get('name')!r}, "
              f"{len(recipe.get('recipeIngredient', []))} ingredients", file=sys.stderr)
    else:
        print(out)


def cmd_preview(a):
    rj = json.loads(Path(a.file).read_text())
    print(f"Name:        {rj.get('name')}")
    if rj.get("description"):
        print(f"Description: {rj['description']}")
    print(f"Servings:    {rj.get('servings')} {rj.get('servings_text') or ''}".rstrip())
    print(f"Time:        work {rj.get('working_time', 0)} min, wait {rj.get('waiting_time', 0)} min")
    print(f"Source:      {rj.get('source_url') or '-'}")
    print(f"Image:       {rj.get('image') or '-'}")
    kws = [k.get("name") for k in rj.get("keywords", [])]
    print(f"Keywords:    {', '.join(kws) if kws else '-'}")
    for n, step in enumerate(rj.get("steps", []), 1):
        ings = step.get("ingredients", [])
        print(f"\nStep {n}{(' - ' + step['name']) if step.get('name') else ''}: {len(ings)} ingredient(s)")
        for i in ings:
            amt = i.get("amount") or 0
            amt = int(amt) if float(amt).is_integer() else amt
            unit = (i.get("unit") or {}).get("name") or ""
            food = (i.get("food") or {}).get("name") or "?"
            parts = [str(amt) if amt else "", unit, food]
            line = " ".join(x for x in parts if x)
            if i.get("note"):
                line += f" ({i['note']})"
            print(f"  - {line}")
        instr = (step.get("instruction") or "").strip()
        print("  " + (instr[:600] + ("..." if len(instr) > 600 else "") if instr else "(no instruction text)"))
    empty = [n for n, s in enumerate(rj.get("steps", []), 1)
             if not (s.get("instruction") or "").strip() and not s.get("ingredients")]
    total_ings = sum(len(s.get("ingredients", [])) for s in rj.get("steps", []))
    warn = []
    if not rj.get("name"):
        warn.append("missing name")
    if total_ings == 0:
        warn.append("no ingredients parsed")
    if empty:
        warn.append(f"empty step(s): {empty}")
    if warn:
        print("\nWARNINGS: " + "; ".join(warn))


def cmd_create(a):
    rj = json.loads(Path(a.file).read_text())
    image = rj.pop("image", None)
    rj.pop("id", None)
    res = post_json("/api/recipe/", rj, expect=(201,))
    rid = res["id"]
    print(f"created recipe {rid}: {res['name']}")
    if image and not a.no_image and str(image).startswith(("http://", "https://")):
        try:
            body, ctype = multipart({"image_url": image})
            request("PUT", f"/api/recipe/{rid}/image/", body, ctype)
            print("image attached")
        except SystemExit:
            print("(image attach failed; recipe was still created)", file=sys.stderr)
    print(recipe_link(rid))


def cmd_image(a):
    if a.url:
        body, ctype = multipart({"image_url": a.url})
    else:
        p = Path(a.file)
        body, ctype = multipart({}, [("image", p.name, p.read_bytes())])
    request("PUT", f"/api/recipe/{a.id}/image/", body, ctype)
    print(f"image set on recipe {a.id}")


def cmd_get(a):
    r = request("GET", f"/api/recipe/{a.id}/")
    out = json.dumps(r, indent=2, ensure_ascii=False)
    if a.output:
        Path(a.output).write_text(out)
        print(f"wrote {a.output}: {r['name']!r}, {len(r['steps'])} step(s)", file=sys.stderr)
    else:
        print(out)


def fmt_amount(x):
    if not x:
        return ""
    fr = {0.25: "¼", 0.33: "⅓", 0.5: "½", 0.67: "⅔", 0.75: "¾", 0.125: "⅛"}
    whole, frac = int(x), round(x - int(x), 2)
    if frac == 0:
        return str(whole)
    sym = fr.get(frac) or next((v for k, v in fr.items() if abs(k - frac) < 0.02), None)
    if sym:
        return f"{whole} {sym}" if whole else sym
    return f"{x:g}"


def recipe_markdown(r):
    out = [f"# {r['name']}", ""]
    if r.get("description"):
        out += [r["description"], ""]
    meta = []
    if r.get("servings"):
        meta.append(f"**{r['servings']} {r.get('servings_text') or 'servings'}**")
    if r.get("working_time"):
        meta.append(f"{r['working_time']} min active")
    if r.get("waiting_time"):
        w = r["waiting_time"]
        meta.append(f"{w // 60} h {w % 60} min hands-off" if w >= 60 else f"{w} min hands-off")
    if meta:
        out += [" · ".join(meta), ""]
    if r.get("source_url"):
        out += [f"Source: {r['source_url']}", ""]
    steps = r.get("steps", [])
    if len(steps) > 1:
        # combined ingredient list up top, then per-step detail
        out += ["## Ingredients", ""]
        for s in steps:
            if s.get("name") and s.get("ingredients"):
                out.append(f"**{s['name']}**")
            for i in s.get("ingredients", []):
                out.append(ingredient_line(i))
            if s.get("ingredients"):
                out.append("")
        out += ["## Directions", ""]
        for n, s in enumerate(steps, 1):
            out += [f"### {n}. {s['name']}" if s.get("name") else f"### Step {n}", ""]
            out += [(s.get("instruction") or "").strip(), ""]
    else:
        s = steps[0] if steps else {"ingredients": [], "instruction": ""}
        out += ["## Ingredients", ""] + [ingredient_line(i) for i in s.get("ingredients", [])] + ["", "## Directions", "", (s.get("instruction") or "").strip(), ""]
    return "\n".join(out).rstrip() + "\n"


def ingredient_line(i):
    amt = fmt_amount(i.get("amount"))
    unit = (i.get("unit") or {}).get("name") or ""
    food = (i.get("food") or {}).get("name") or ""
    line = " ".join(x for x in (amt, unit, food) if x)
    if i.get("note"):
        line += f" ({i['note']})"
    return f"- {line}"


def cmd_markdown(a):
    for rid in a.ids:
        r = request("GET", f"recipe/{rid}/")
        md = recipe_markdown(r)
        if a.output:
            d = Path(a.output); d.mkdir(parents=True, exist_ok=True)
            slug = re.sub(r"[^a-z0-9]+", "-", r["name"].lower()).strip("-")
            f = d / f"{slug}.md"; f.write_text(md); print(f"wrote {f}", file=sys.stderr)
        else:
            print(md)


def cmd_update(a):
    rj = json.loads(Path(a.file).read_text())
    rid = rj.get("id") or die("recipe JSON has no `id` (use `get ID` output)")
    body = json.dumps(rj).encode()
    res = request("PUT", f"/api/recipe/{rid}/", body, "application/json")
    print(f"updated recipe {rid}: {res['name']} ({len(res['steps'])} steps)")
    print(recipe_link(rid))


def cmd_delete(a):
    request("DELETE", f"/api/recipe/{a.id}/", expect=(204,))
    print(f"deleted recipe {a.id}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest="cmd", required=True)
    sp.add_parser("check").set_defaults(fn=cmd_check)
    s = sp.add_parser("search"); s.add_argument("query"); s.add_argument("--limit", type=int, default=10); s.set_defaults(fn=cmd_search)
    s = sp.add_parser("scrape"); g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--url"); g.add_argument("--data", metavar="FILE"); s.add_argument("-o", "--output"); s.set_defaults(fn=cmd_scrape)
    s = sp.add_parser("jsonld"); s.add_argument("url"); s.add_argument("-o", "--output"); s.set_defaults(fn=cmd_jsonld)
    s = sp.add_parser("preview"); s.add_argument("file"); s.set_defaults(fn=cmd_preview)
    s = sp.add_parser("create"); s.add_argument("file"); s.add_argument("--no-image", action="store_true"); s.set_defaults(fn=cmd_create)
    s = sp.add_parser("image"); s.add_argument("id", type=int); g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--url"); g.add_argument("--file"); s.set_defaults(fn=cmd_image)
    s = sp.add_parser("get"); s.add_argument("id", type=int); s.add_argument("-o", "--output"); s.set_defaults(fn=cmd_get)
    s = sp.add_parser("markdown"); s.add_argument("ids", type=int, nargs="+"); s.add_argument("-o", "--output", metavar="DIR"); s.set_defaults(fn=cmd_markdown)
    s = sp.add_parser("update"); s.add_argument("file"); s.set_defaults(fn=cmd_update)
    s = sp.add_parser("delete"); s.add_argument("id", type=int); s.set_defaults(fn=cmd_delete)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
