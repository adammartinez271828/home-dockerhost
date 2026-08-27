---
name: add-recipe
description: Add a recipe to the Tandoor server at recipes.local from a web URL, pasted/dictated text, or a photo/PDF of a recipe. Use when the user wants to import, add, save, or transcribe a recipe into Tandoor / recipes.local.
---

# Add a recipe to Tandoor (recipes.local)

Tandoor 1.5.x REST API, driven through `tandoor.py` in this directory (stdlib only).
All commands: `python3 .claude/skills/add-recipe/tandoor.py <cmd>` — run from the repo root.
Keep working files in the scratchpad directory, not the repo.

## One-time setup

Needs an API token. If `tandoor.py check` fails with "no API token", tell the user:

1. In Tandoor (`http://recipes.local`) → user menu → **Settings → API** → *Create* a token with scope **read write**.
2. Copy it into `env.d/tandoor-api.env` (gitignored; template at `env.d/tandoor-api.env.example`):
   `TANDOOR_API_TOKEN=tda_...` — or export `TANDOOR_API_TOKEN` in the shell.

Then `tandoor.py check` should print `OK: http://recipes.local (space: …)`.

## Workflow

Three inputs, one pipeline: **get a `recipe_json` → preview → create**.
Tandoor does the ingredient parsing (amount / unit / food / note) server-side, so never
hand-build the nested `steps[].ingredients[]` structure — always go through `scrape`.

### 1. Get a recipe_json

**A. URL** — the user gives a link to a recipe page:

```sh
tandoor.py scrape --url "https://…" -o "$SCRATCH/recipe.json"
```

Tandoor fetches and scrapes the page itself (schema.org / recipe-scrapers). stderr reports
`duplicate=true` if a recipe with that `source_url` already exists, plus other candidate images.

If that fails — **HTTP 500** (the site blocks bots, e.g. Food52's Vercel checkpoint) or
"No usable data could be found" — fetch the page's structured data from this machine instead:

```sh
tandoor.py jsonld "https://…" -o "$SCRATCH/recipe.jsonld"   # direct fetch, then Wayback Machine
tandoor.py scrape --data "$SCRATCH/recipe.jsonld" -o "$SCRATCH/recipe.json"
```

`jsonld` extracts the page's schema.org Recipe (the same data Tandoor would have scraped) and
sets `url` so `source_url` is still the real page.

If that fails too (hard bot-walls like thekitchn.com: 403 direct, Wayback copy stripped), use
**Claude in Chrome** — a real browser passes the check. Load the `claude-in-chrome` skill, then
`tabs_context_mcp` → `navigate` to the URL → `javascript_tool` to read the JSON-LD from the DOM:

```js
let f=null;const w=o=>{if(f)return;if(Array.isArray(o))o.forEach(w);else if(o&&typeof o==='object'){const t=o['@type'];if(t==='Recipe'||(Array.isArray(t)&&t.includes('Recipe'))){f=o;return}Object.values(o).forEach(w)}};
[...document.querySelectorAll('script[type="application/ld+json"]')].forEach(s=>{try{w(JSON.parse(s.textContent))}catch(e){}});
f.recipeIngredient.map((x,i)=>(i+1)+'|'+x).join('\n')   // then recipeInstructions, then name/yield/times/image/keywords
```

The tool output is capped around 1 KB, so pull ingredients, instructions and metadata in
separate calls (slice long instruction arrays), then write the JSON-LD file yourself and
`scrape --data` it. Close the tab when done. If the browser isn't connected, ask the user to
save the page (Ctrl+S, "HTML only") and pass the `.html` to `scrape --data`.

**B. Pasted / dictated text, C. photo or PDF** — read the source (use the Read tool for
images/PDFs; it returns the picture/text to you), then write a **schema.org Recipe JSON-LD**
file and let Tandoor parse it:

```json
{
  "@context": "https://schema.org",
  "@type": "Recipe",
  "name": "Grandma's Banana Bread",
  "description": "One short sentence (optional).",
  "recipeYield": "1 loaf",
  "prepTime": "PT15M",
  "cookTime": "PT60M",
  "recipeIngredient": [
    "2 cups all-purpose flour",
    "1 tsp baking soda",
    "3 ripe bananas, mashed",
    "1/2 cup butter, melted"
  ],
  "recipeInstructions": [
    "Preheat the oven to 350°F and grease a loaf pan.",
    "Whisk the flour and baking soda together."
  ],
  "keywords": "baking, quick bread",
  "recipeCuisine": "American",
  "url": "https://original-source-if-any"
}
```

```sh
tandoor.py scrape --data "$SCRATCH/recipe.jsonld" -o "$SCRATCH/recipe.json"
```

Transcription rules:
- One ingredient per string, in `<amount> <unit> <food>, <note>` order — that's what the parser
  expects. Fractions (`1/2`, `½`) and ranges are fine. Don't invent amounts that aren't there;
  an ingredient with no amount is just the food name (`salt`, `fresh parsley for garnish`).
- One instruction string per step, in order. Keep the original wording; fix only obvious OCR
  errors. Merge heading-only lines ("For the sauce:") into the following step or use them as
  a note — don't emit empty steps.
- `prepTime` / `cookTime` are ISO-8601 durations (`PT1H30M`). Omit fields you don't know.
- Only set `image` if you have a real, publicly reachable image URL. For a photo of a printed
  recipe, do **not** attach the photo as the recipe image unless the user asks.
- `url` = the original web source if the user gave one; otherwise omit it.

### 2. Preview and sanity-check

```sh
tandoor.py preview "$SCRATCH/recipe.json"
tandoor.py search "<recipe name>"          # name-based duplicate check
```

Show the user a compact summary (name, servings, times, ingredient count, step count,
keywords, image) — not the raw JSON. Look for: missing name, zero ingredients, empty steps,
ingredients with `?` food names, `duplicate=true`, or a `search` hit with the same name.

**Check the parsed food names.** Tandoor's parser is good at `<amount> <unit> <food>, <note>`
but leaks qualifiers into `food.name` on complex lines — e.g. `thick-cut bacon (about 5 ounces)`,
`yellow onion, diced`, or a whole `small beans, such as navy, pinto…, drained and rinsed`.
Each Food becomes a reusable entry in Tandoor's food list, so keep names canonical: set
`food` to `{"name": "yellow onion"}` (no `id` — it's looked up/created by name) and move the
rest into `note`. Do this before `create`; fixing afterwards leaves orphan Food entries (harmless — never delete them, see below).

**Never DELETE a Food or Unit via the API.** `Ingredient.food` is `on_delete=CASCADE` (deleting a
food deletes every ingredient line using it, in every recipe) and `Ingredient.unit` is `SET_NULL`
(the unit silently vanishes from every recipe). The API does not refuse either. To fix a junk
food name on an *existing* recipe, don't create a new food — either **rename in place**
(`PATCH /api/food/<id>/ {"name": …}`, when the malformed food is used only by that line and no
canonical food exists) or **merge** into the existing canonical food
(`PUT /api/food/<bad_id>/merge/<canonical_id>/`, which re-points every ingredient first). Then
`PATCH /api/ingredient/<id>/ {"note": …}` to park the qualifier. Same for units. Also note the parser
treats the word after a bare number as the unit (`2 medium onions` → unit `medium`,
`4 chicken thighs` → unit `chicken` + food `thighs`, `2 dried bay leaves` → unit `dried`) — scan
the preview for these **before `create`**, since `create` persists the junk unit; `medium`/`small`/`large` as units is the existing house convention (recipe 14),
so keep those and only null out real nonsense like `chicken` or `dried`.

**Recipe Notes** (variations, storage) aren't in JSON-LD — grab them from the page when
available and append to the last step as `**Notes**` followed by `*Label:* text` paragraphs
(recipe 14 and 54 do this).

You may edit `recipe.json` before creating: fix `name`, `servings`, `servings_text`
(often mangled from yields like "Serves 4 to 6" → set `servings: 4`, `servings_text: "servings"`),
`working_time`/`waiting_time` (minutes), drop junk `keywords` (scrapers often include the
site's domain and author — keep those only if the user wants them), set `description`,
or swap `image` for one of the other candidates. Keep the `steps[].ingredients[]` objects as
returned. Keywords are `{"name": "...", "label": "..."}` objects (an existing one also has `id`).

### 2b. Structure the steps (house style)

Scrapers return **one step holding every ingredient** and all the instructions run together.
Adam's recipes (see recipe 14 "Adam's Spanish Rice", recipe 53 "Instant Pot Risotto") are laid
out as a few **named cooking phases, each listing only the ingredients it uses**. Restructure
`recipe.json` to match before creating:

- **A step = one ingredient-addition event plus everything that happens until the next one.**
  Start a new step only when a new batch of ingredients goes into the pot/bowl. Hands-off
  stretches (pressure cook, rest, bake) and serving/seasoning notes belong to the step whose
  ingredients they act on — so **every step has at least one ingredient**; never emit an
  ingredient-less step. Typical shape: prep/aromatics → main cook → finish & serve.
- Aim for **~3–4 steps** for a normal recipe (not one per source paragraph; 6 is too many).
  Keep the source paragraphs inside a step as separate paragraphs (blank line between them),
  text verbatim.
- Give each step a short `name` describing the phase — compound names are fine
  ("Sauté Aromatics and deglaze", "Pressure Cook", "Finish").
- Move each ingredient object (unchanged, from `steps[0].ingredients`) into the step where it
  is first added. Every ingredient must land in exactly one step — check the total matches.
- Per step: `"show_ingredients_table": true`, `"show_as_header": false`, `"time": 0`,
  `"order": <index>`. On the recipe: `"show_ingredient_overview": false`,
  `"servings_text": "Servings"`.

Worked example (recipe 53, from six source paragraphs):

| Step | Ingredients | Source paragraphs |
|---|---|---|
| Sauté Aromatics and deglaze | oil, onion, garlic, wine | 1–2 |
| Pressure Cook | rice, salt, broth | 3–4 (add + cook) |
| Finish | spinach, Parmesan, butter, lemon juice, zest | 5–6 (finish + season & serve) |

Recipe 54 (baked beans, five source steps) → *Cook Bacon* (bacon; steps 1–2) → *Sauté Onion*
(onion, salt, pepper; step 3) → *Simmer and Bake* (everything else; steps 4–5 + notes).

Do this for URL imports and transcriptions alike. For a transcription you can go further and
put the JSON-LD's `recipeInstructions` in the intended step granularity up front — the
ingredients will still all land in step 1 and need distributing.

To restructure recipes that are already in Tandoor, use `restructure.py` with a plan file
(`--dry` first — it asserts every ingredient lands in exactly one step and every paragraph is
used unless `allow_dropped_paras`):

```json
{"11": {"servings_text": "Servings", "steps": [
   ["Coat the Chicken",   ["literal sentence(s) …"], [2, 3, 4]],
   ["Layer and Pressure Cook", [3, 4],                [9, 10]] ]}}
```

Each step is `[name, text_spec, ingredient_numbers]`: text_spec mixes 1-based paragraph
indices (flattened across the recipe's existing steps, split on newlines) and literal strings;
ingredient numbers are 1-based across the existing steps in order. Dump a recipe's numbered
ingredients/paragraphs first (see `tandoor.py get`) to write the plan. Leave the user's own
hand-built two-phase recipes (e.g. marinate-today / roast-tomorrow) alone even if the second
phase has no ingredients — that split is deliberate.

**If a recipe PUT/POST returns HTTP 500 with an empty body**, bisect the keywords: Tandoor's
uniqueness check breaks when two keywords differ only by whitespace/case (`' mexican'` vs
`'mexican'` — imports create the space-prefixed ones). Fix with the lossless merge endpoint,
`PUT /api/keyword/<dup_id>/merge/<clean_id>/`, never DELETE. Foods and units have the same
merge endpoint.

Tandoor requests are **not atomic**: a POST/PUT that returns 500 may still have created or
modified the recipe before crashing. After any 500, GET the recipe (or `search ZZ-TEMP`) to
see what actually landed, and prefix any throwaway test recipes with `ZZ-TEMP` so they're
easy to find and delete.

### 3. Create

- URL import that parsed cleanly, was restructured per 2b, and isn't a duplicate → create right away.
- Transcribed text/photo/PDF → show the preview and get a quick OK first (skip the pause if
  the user said to just add it). Transcription mistakes are the main risk here.

```sh
tandoor.py create "$SCRATCH/recipe.json"    # POSTs the recipe, then attaches its image URL
```

Prints the recipe id and link (`http://recipes.local/view/recipe/<id>`). Report that link.
Use `--no-image` to skip the image, or set one afterwards:
`tandoor.py image <id> --url "https://…"` / `--file photo.jpg`.

### Export as Markdown

`tandoor.py markdown <id> [<id>…]` prints a recipe as Markdown (title, description, servings/times,
source, a combined ingredient list grouped by step, then the directions per step); `-o DIR` writes
one `<slug>.md` per recipe instead. Use it when the user wants to share or copy-paste a recipe.

### Undo

`tandoor.py delete <id>` removes a recipe. Only on the user's request (e.g. the import came
out wrong); it's permanent.

## Notes

- `TANDOOR_URL` (env or `env.d/tandoor-api.env`) overrides the default `http://recipes.local`.
- URL imports are rate-limited by Tandoor (`RecipeImportThrottle`); batch imports should go
  one at a time, not in a tight parallel loop.
- Tandoor's `data` import also accepts raw HTML — if you already have a page's HTML (e.g. a
  site that blocks the Pi but not the laptop), save it to a file and `scrape --data page.html`.
