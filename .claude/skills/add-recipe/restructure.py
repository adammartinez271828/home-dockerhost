"""Apply a step-restructure plan to existing Tandoor recipes (house style: named
phases, each carrying the ingredients it adds). Usage:

    python3 restructure.py plan.json [--dry]

Ingredient objects are moved unchanged (same food/unit/amount/note); no foods,
units or keywords are touched. --dry validates coverage without writing.
plan: {rid: {"steps": [(name, text_spec, [ingredient indices 1-based]), ...], "servings_text": ..., "servings": ..., ...}}
text_spec: list of paragraph indices (1-based, flattened across existing steps) and/or literal strings, joined by blank lines.
"""
import json, re, sys, pathlib, urllib.request
REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
ENV_FILE = REPO_ROOT / "env.d" / "tandoor-api.env"
_cfg = {}
if ENV_FILE.is_file():
    for _l in ENV_FILE.read_text().splitlines():
        if "=" in _l and not _l.strip().startswith("#"):
            _k, _v = _l.split("=", 1); _cfg[_k.strip()] = _v.strip().strip("'\"")
import os
BASE = (os.environ.get("TANDOOR_URL") or _cfg.get("TANDOOR_URL") or "http://recipes.local").rstrip("/")
tok = os.environ.get("TANDOOR_API_TOKEN") or _cfg.get("TANDOOR_API_TOKEN") or sys.exit("no TANDOOR_API_TOKEN")
H = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}
def api(m, p, body=None):
    req = urllib.request.Request(BASE + "/api/" + p, data=json.dumps(body).encode() if body is not None else None, headers=H, method=m)
    with urllib.request.urlopen(req) as r: return json.load(r)

def apply(rid, spec, dry=False):
    r = api("GET", f"recipe/{rid}/")
    ings = [i for s in r["steps"] for i in s["ingredients"]]
    paras = [p.strip() for s in r["steps"] for p in re.split(r"\s*\n\s*", s["instruction"] or "") if p.strip()]
    used, new_steps = [], []
    for k, (name, tspec, idx) in enumerate(spec["steps"]):
        text = "\n\n".join(paras[t-1] if isinstance(t, int) else t for t in tspec)
        step_ings = []
        for n in idx:
            i = dict(ings[n-1]); i.pop("id", None); step_ings.append(i); used.append(n)
        new_steps.append({"name": name, "instruction": text, "ingredients": step_ings, "time": 0, "order": k, "show_as_header": False, "show_ingredients_table": True})
    assert sorted(used) == list(range(1, len(ings)+1)), f"{rid}: ingredient coverage {sorted(used)} vs {len(ings)}"
    used_p = [t for _, ts, _ in spec["steps"] for t in ts if isinstance(t, int)]
    missing = [p+1 for p in range(len(paras)) if (p+1) not in used_p]
    if missing and not spec.get("allow_dropped_paras"): raise SystemExit(f"{rid}: paragraphs not used: {missing}")
    r["steps"] = new_steps; r["show_ingredient_overview"] = False
    for k in ("servings", "servings_text", "working_time", "waiting_time", "description"):
        if k in spec: r[k] = spec[k]
    if not dry:
        res = api("PUT", f"recipe/{rid}/", r)
        assert sum(len(s["ingredients"]) for s in res["steps"]) == len(ings)
    print(f"{'DRY ' if dry else ''}{rid} {r['name']}: {len(new_steps)} steps | " + " / ".join(f"{s['name']} [{len(s['ingredients'])}]" for s in new_steps))

if __name__ == "__main__":
    plan = json.loads(pathlib.Path(sys.argv[1]).read_text()); dry = "--dry" in sys.argv
    for rid, spec in plan.items(): apply(int(rid), spec, dry)
