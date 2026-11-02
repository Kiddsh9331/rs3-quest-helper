# RS3 Quest Helper (Alt1 app)

A step-by-step quest quick-guide overlay for RuneScape 3, built for the
[Alt1 Toolkit](https://runeapps.org/alt1) — Jagex's rule-compliant overlay
platform (no memory reading, no injection).

## Features

- **Every quest on the wiki**: the quest index is fetched live from the
  RuneScape Wiki (`Category:Quick guides`, ~370 quests, miniquests and
  events) and cached locally for 7 days
- **Search bar** to filter the quest list as you type
- **On-demand guides**: selecting a quest downloads its quick-guide wikitext
  from runescape.wiki and parses it into checkable steps — sections, item
  requirements, dialogue-option chips, notes, and location tables
- Click a step (or **Done, next**) to tick it off; the current step is
  highlighted; progress is saved per quest and shown in the quest list
- **Overlay** button paints the current step on top of the game screen
- **Map panel**: steps and location tables that carry coordinates on the wiki
  (`{{NPC map}}`/`{{Map}}` templates) get a green "Map x,y" chip that opens
  the RS3 world map (mejrs.github.io) **embedded inside the app**, centred on
  that exact spot with the right floor/plane and layer (e.g. Zanaris)
- Guides are cached locally (last 50) so revisiting a quest is instant
- **Area tasks** (the achievement diaries): an **Area tasks** tab next to
  the quest list with all 13 areas plus New Varrock, each split into its
  tiers (Beginner for Lumbridge, then Easy, Medium, Hard, Elite) with your
  done / total per tier. Open a tier and every task is a step you can tick:
  the task, what it needs, the wiki's notes and a link to its page, with
  the tier's own requirements, items and rewards above. Sync your name and
  the requirements turn green or red against your levels, combat level,
  quest points and quests. Search covers task names once an area is
  loaded (**Load all** fetches every area). Task ticks travel in the same
  progress code as quests. Overlay works for tasks too; Assist and Auto
  stay quest-only, since tasks have no dialogue to read.
- **Assist mode** (Alt1 only, needs pixel + overlay permissions): captures
  the game screen ~1.5×/second and
  - **highlights the dialogue option to click** — when the current step has
    a "Chat:" entry and a dialogue box is open, the matching option gets a
    green box drawn around it in game (option text is OCR'd via the alt1
    DialogReader; falls back to the option number when wording differs)
  - **watches the chatbox** for quest-completion messages and marks the
    quest done automatically
  - shows a live status line in the app so you can see what it detected
- **Auto mode** (needs Assist): dialogue steps tick themselves — when the
  conversation for the current step has been on screen and then ends, the
  step is marked done automatically. Steps without dialogue (walking,
  combat, puzzles) remain manual — Alt1 has no access to game state, so
  there is no reliable generic signal for those.

## Running it

Alt1 loads apps over HTTP, so serve this folder with any static server:

```powershell
# from this folder — pick whichever you have installed:
python -m http.server 8090
# or
npx http-server -p 8090
```

Then install the app into Alt1 either way:

1. **Via link:** with Alt1 running, open this in a browser:
   `alt1://addapp/http://localhost:8090/appconfig.json`
2. **Via Alt1 browser:** open Alt1's built-in browser, navigate to
   `http://localhost:8090`, and click the "add to Alt1" banner at the top.

Accept the **overlay** permission when prompted so the on-screen step display
works. The app also runs in a normal browser for testing (overlay disabled).

Deep links are supported: `index.html?quest=Dragon+Slayer` opens a quest
directly, and `index.html?tasks=Lumbridge/Easy` a task tier
(`?tasks=Lumbridge` just opens the Area tasks tab).

## How the wiki parsing works

Quick guides on the wiki are wikitext built from a handful of templates
(`{{Checklist}}`, `{{Needed}}`, `{{Chat options}}`, wikitables for NPC
locations). `app.js` resolves these client-side via the wiki's CORS-enabled
API (`api.php?action=parse&prop=wikitext&origin=*`). Unknown templates are
dropped and links flattened to text, so the parser degrades gracefully on
unusual guides — and every guide links back to the full wiki page.

Area tasks come from each area's set page (`Lumbridge achievements` and so
on). The wiki builds those task tables from its own database, so the
wikitext has no rows: the app asks for the rendered page instead
(`action=parse&prop=text`) and reads the tables per tier heading. Parsed
sets are cached for 7 days; the ↻ button on an area reloads it.

## Bonus addon: Tile Marker

A second, standalone Alt1 app in this folder (`tile.html` +
`appconfig-tile.json`): a tile-shaped diamond (or square/crosshair) that
follows your mouse over the game window, with size, colour, and line-width
controls. Install it separately:

```
alt1://addapp/http://localhost:8090/appconfig-tile.json
```

Needs the **pixel** (calibration), **gamestate** (mouse position) and
**overlay** permissions. **Calibrate from click marker**: click the ground
in game and the addon measures the game's yellow destination marker,
adopting its exact pixel size and aspect for the hover marker at your
current zoom/camera. Honest limitation: Alt1 cannot read the camera, so
the marker follows the cursor smoothly — it cannot snap to the real tile
grid the way renderer-hooking clients (Bolt/RuneLite-style) can.

## Files

| File             | Purpose                                          |
| ---------------- | ------------------------------------------------ |
| `appconfig.json` | Alt1 app manifest (name, size, permissions)      |
| `index.html`     | App shell (home list view + guide view)          |
| `style.css`      | Dark RS-flavoured theme                          |
| `app.js`         | Wiki fetching, wikitext parser, progress, overlay, assist |
| `libs/`          | Vendored [alt1](https://github.com/skillbert/alt1) UMD bundles by Skillbert (base, ocr, dialog, chatbox) |
| `test.html`      | Self-tests (open `/test.html` to run)            |
| `test-tasks-fixture.js` | Trimmed copy of a real area-task wiki page, for the task parser tests |
| `icon.png`       | Taskbar/app icon                                 |

## Credits

- Quest data: [RuneScape Wiki](https://runescape.wiki) (CC BY-NC-SA 3.0)
- Screen reading: [alt1 libraries](https://github.com/skillbert/alt1) by Skillbert (RuneApps)
- Assist-mode concept inspired by [bolt-questhelper](https://codeberg.org/JasperSurmont/bolt-questhelper)
