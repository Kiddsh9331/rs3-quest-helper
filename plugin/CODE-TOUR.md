# Code tour

Jagex only accepts plugins whose author understands the code, AI-assisted or
not. This is a map for reading it all once: about 4,800 lines of Lua, plus
`quests.lua` (77,000 lines of generated data, no logic). Suggested order:
the small modules first, then `app.lua`, which ties them together.

## How it runs

`main.lua` loads `app.lua` inside an error guard. `app.lua` builds the step
lists, then subscribes to the game's events:

| Event | What happens |
|---|---|
| `ServerLogic` (every 0.6s tick) | checks position (climbs, arrivals), updates highlights and the path, the card, dialogue option colours, the teleport hint, the recording |
| `Logic` (every frame) | keeps the card following the mouse while it's being moved |
| `Draw` | the arrows over targets and the path dots |
| `MiniMenuEntrySelected` | a click in the world: may jump to the step it belongs to |
| `InventoryUpdated` | backpack changed: may finish get/make/hand-over steps |
| `VarTransmit` | the quest's progress value rose: finishes the current step |
| `ChatMessage` (with chatAccess) | "You have slain ..." finishes a fight step |
| `KeyDown` | Alt+D: done, next; Alt+F: flag a problem (recording only) |
| `ContentLayerReady` | the ribbon panel opened: build it |

Everything that can fail runs through `Diag.Guard`, so one error is logged
(locally) instead of breaking the plugin.

## Modules

**edition.lua** (13 lines). Test build or release build. `tools/package.py`
rewrites it in the release zip.

**diag.lua** (49). Error and status notes kept in the plugin's own storage
(PersistentDB), plus the console.

**travel.lua** (61). A table of lodestone tiles. `Suggest` says which one
lands closest to a far-away target, if it saves enough walking. `Named`
finds a lodestone a step mentions ("Teleport to Varrock").

**recorder.lua** (118). The optional session log (Settings, off in the
release). Lines like `tick<TAB>kind<TAB>fields`, saved in chunks, newest 5
sessions kept. Never leaves the device.

**path.lua** (165). A* path-finding over tiles for the dots: walls block
tile edges, solid objects block tiles, doors count as open. Pure logic, no
game calls.

**probe.lua** (218). Reads text from the game's interfaces, only components
the game reports as visible. Used to find the dialogue box and match the
step's chat options against its text.

**card.lua** (392). The step card on the game screen: title bar (click to
pick up and move), progress strip, text blocks. Also turns matching
dialogue options blue (text colour only).

**view.lua** (488). Draws the ribbon panel from a list of "rows" (title,
text, buttons, step with checkbox...). Handles scrolling and only redraws
when the rows changed.

**advance.lua** (929). The step logic, pure text rules (no game calls):
what kind of step it is (travel, climb, use, make, get, fight), which step a
click belongs to (`MatchInteraction`), whether climbing or arriving finishes
a step, what a step says to get, item quantities in the backpack, landmarks
vs things to click ("north of the well" vs "search the crate"), and which
one of several a step means (`Placement`: "the lever by the water wheel").

**world.lua** (717). Everything drawn in the 3D world: tile outlines and
arrows over the NPCs/objects the step names (`SetTargets`, `Update`; nearest
first, narrowed to the one the step means by `placeGroup`), the
right stairs when you're on the wrong floor or underground, the tile marker,
and the dotted path (`drawPath`, using path.lua with the walls nearby).

**app.lua** (2,388). The plugin itself, top to bottom:
1. Settings, saved state (current quest and step per quest), step lists.
2. Quest status and progress from the game's quest data.
3. Items: what each step needs, backpack checks, Grand Exchange or recipe hints.
4. `stepTargets`: who and where a step is about (NPCs, place, map tile).
5. `sceneryMatcher`: which objects to outline for a step (`fallbackMatcher`:
   what to outline when none of them is in sight).
6. Step text for the card and panel (`stepBlocks`), then the card.
7. Dialogue: noticing the conversation box, colouring the step's options.
8. Moving through steps: `setStep`, and the auto-advance rules (clicks,
   progress value, backpack, position).
9. The panel screens: quest list, guide, settings.
10. Event subscriptions and startup.

**devtools.lua** (209, test build only, not in the release zip). The
Debug section: dump visible interface text to the console, test a wiki
download, show the progress value log.

**quests.lua** (generated, don't edit). Built by `tools/build_quests.py`
from the wiki's quick guides via the Alt1 app's parser: quests -> sections
-> steps (text, chat options, linked pages, map tile, sub-bullets), plus
what each linked page is and where (`pages`), item notes, recipes and
Grand Exchange status.

## Not in the plugin

`tests/` (offline tests against a stand-in API, `run.py`; the all-quests
check; recording replays) and `tools/` (data build, packaging) are for
development and aren't in the release zip.
