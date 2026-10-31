# RS3 Quest Buddy: improvement plan

Deep dive of 2026-10-30 over all 372 quests (11,433 steps), the plugin's UI
code, and what's out there (the official Quest Helper plugin, the Jagex API
docs). Each item has the evidence, what to change, how to verify, and a
prompt to paste into Claude Code to get it done.

## How to use this file

- Run one item at a time: paste its prompt, or say
  `Do item A3 from plugin/IMPROVEMENTS.md`. Items are independent unless
  the text says otherwise.
- Every item ends the same way: `python plugin/tests/run.py` must print
  `ALL PLUGIN TESTS PASSED`, and for anything touching step logic also run
  `python plugin/tests/check_quests.py plugin/rs3-quest-buddy/quests.lua --cache <scratch>/wiki.json --out findings.json`
  and compare the per-kind counts with the numbers in "Where things stand".
- Rules that always apply: `quests.lua` is generated (change
  `tools/build_quests.py`, never the data by hand); plugin work stays on
  branch `plugin-all-quests`; commit or push only when asked; README and
  CODE-TOUR get a line when behaviour changes.
- When an item is done, change its `Status:` line here to `done <date>` and
  note anything learned under it.

Status key: `open`, `needs in-game check`, `done <date>`.

## Where things stand (checker totals, 2026-10-30 evening, after the first pass through this file)

The "was" numbers are from the morning, before the items below were run.
`tests/check_baseline.json` holds the current counts; `python plugin/tests/run.py --full <wiki cache>`
compares against it.

| What | Count | Meaning |
|---|---|---|
| steps | 11,433 | across 372 quests, miniquests and sagas |
| no-trigger | 3,525 (31%), was 4,719 | steps the plugin can't finish by itself: "Done, next" or Alt+D |
| travel-no-place | 370, was 795 | travel steps with no map spot, so no beacon, dots or "arrived" |
| no-nav | 713, was 817 | steps naming an NPC/thing with nowhere to point at |
| outlines | 1,812 | steps that outline something (common objects only; the deeper check found 7,788) |
| placed | 456 | outlines narrowed to the one the text means |
| unplaced | 151, was 220 | text says which one, plugin can't read it |
| climb-early | 103 | climb steps that finish on the climb though they name another action (review list) |
| link-unknown | 169 | wiki links to pages that aren't an NPC, item or place |
| picture | 48 | steps that refer to an image the card can't show |
| card-long | 39 | steps over 900 characters on the card |
| chat-empty | 39 | chat strings the option matcher can't use ("1 / 1", "~", "4 X") |
| itemsNoHelp | 520 | "Bring:" lines with no GE, recipe, hint or parts |

Fixed today (uncommitted, on top of commit `b6d1dc5`): outlines sorted by
real distance, one set of stairs at a time, placements ("by the water
wheel", "on the eastern wall", "north of you"), no double advance after an
item, climb steps outline what's up there, "use X on Y" anywhere in the
sentence, landmarks and partial names no longer outlined, "Enter" steps
fall back to doors only when nothing named is in sight, landmark clicks
don't jump ahead. The checker now also tests linked scenery and click
jumps. See the two replies of 2026-10-30 for the full list.

## What's out there (research notes)

- **Official Quest Helper** (Zoinkwiz, JosTheFarmer, Techpure; on the Jagex
  Plugin Hub since 19 Oct 2026, 69 quests at launch, repo at
  codeberg.org/QuestHelper/QuestHelper). Two windows by default: an overview
  (all steps, requirements, rewards) and a current-step detail window;
  "Full / Medium / Minimum assistance" picked on first use; asterisk on
  supported quests in the Quests tab; a minimap arrow; auto-advance. Known
  complaints: windows hard to resize (edge only, no cursor feedback), scroll
  position not remembered, settings not persisted. Our edge: all ~370
  guides, items checked against the backpack, teleport hints, the dotted
  path. Their edge: hand-made steps with real progress detection, puzzle
  guidance, requirements and rewards up front, a minimap arrow.
- **Jagex API docs** (developer.runescape.com/rs/): components take
  `SetSize(x, y, parentShareX, parentShareY)` and `SetPos` with parent and
  self shares, have read-only `width`/`height`, and fire `ONRESIZE`.
  `ui.Text` has `font`, `maxLines`, `lineSpacing`, align, shadow. No text
  measuring call, no screen-size call found on the pages read (leads:
  /rs/game/screenconvert.html, /rs/ui/common_types.html, the FontType
  config page for the font list, /rs/game/config/mapelementtype.html for
  minimap elements). `ui.Canvas` draws lines, rectangles, sprites and text
  inside its own component only.
- OSRS RuneLite Quest Helper (the model everyone copies): requirements and
  all steps in a sidebar, current step in the top-left, arrows on world map
  and minimap, highlighted NPC/object/tile, item requirement icons, puzzle
  solvers, varbit-driven auto-advance.

---

## A. Quest steps, navigation and indication

### A1. Clicking the step's own object should finish the step
Status: done 2026-10-30
Notes: Guards: item steps, use/make steps, a next step that hands over or uses something, same-step items. `ownClickStep` is exported for the checker, which now counts own clicks and kill messages as triggers. Replay of session 3 reaches step 13 on the bellows click (the recording ended there).

Evidence: 4,719 steps have no auto trigger. First words of those: open 217,
search 164, use 159, pull 50, read 53, investigate/inspect 78, interact 32,
place 30, push, operate, light, dig. Today `MatchInteraction` only moves on
when a click matches a *later* step; a click on the current step's own
object returns the current index, which `onInteraction` ignores
(`index > currentIndex()`). So "Search the crate" never finishes when you
search the crate, even though the crate is outlined.

Change: in `onInteraction`, when the click's subject is something the
current step outlines (`sceneryMatcher` says yes for that name, or
`namesObject`) and the step's main action is a click verb (open, search,
pull, push, read, investigate, inspect, operate, light, dig, interact,
touch, activate, turn, rotate, pick-lock), finish the step. Guard it: not
when the step also waits for an item (`acquireWants` non-empty, the item
finishes it), not when the step is a "use X on Y" (the item use already
does it), and not when the next step is about the same object. Delay the
advance by one tick and cancel it if a chat line like "You find nothing"
or "The door is locked" arrives (`onChat` already sees chat types 0/4).
Recordings show the subject text for scenery clicks, so replay session 3
(EW1) and session 5 to confirm nothing jumps.

Verify: new tests in `run.lua` (search the outlined crate finishes the
step; search a crate on a "Go upstairs and search the drawers" step doesn't
finish before the climb; "You find nothing" cancels); checker no-trigger
count drops by a few hundred; `replay.py --session 3` and `--session 5`
report 0 regressions.

Prompt:
```
Do item A1 from plugin/IMPROVEMENTS.md: make a click on the current step's own outlined object finish the step (open/search/pull/read/investigate and the other click verbs), with the guards listed there (item steps, use-on steps, same object next step, "nothing found" chat lines). Add the run.lua tests named in the item, rerun check_quests and the session replays, and report the before/after no-trigger count. Don't commit.
```

### A2. Read more "which one" phrasings; fix the checker's false positives
Status: done 2026-10-30
Notes: Adjectives between direction and name, "in the middle of X" (`centre`), "second from the north" (`rank`); `placeGroup` handles both. Checker no longer counts "wall" for Wall. unplaced 220 -> 151.

Evidence: 220 "unplaced" findings. 53 are `Wall: wall` where "wall" is the
object itself ("Open the eastern strange wall"), a checker artefact. The
real misses have an adjective between the direction and the name ("the
eastern strange wall", "the north-eastern small tile", "the southern most
door"), "second from the north", "in the middle of the prison", "to the
right of the door" (right/left relative to facing, probably skip), and
"on the north side of the house".

Change: in `Advance.Placement`, let a compass word sit one or two words
before the name (skip adjectives: strange, small, large, first, second,
wooden, stone, locked, old, broken); treat "in the middle/centre of X" as
"nearest the centre of X" (anchor with no direction, pick the one nearest
the group's centroid); treat "N-th from the <dir>" as extreme in that
direction with rank N. In `check_quests.lua` PLACE_HINTS, don't count
"wall" when the outlined name is Wall.

Verify: `placement()` tests in run.lua for each phrase; unplaced count well
under 150 with the Wall artefact gone.

Prompt:
```
Do item A2 from plugin/IMPROVEMENTS.md: extend Advance.Placement for a compass word separated from the name by one or two adjectives, "in the middle of X", and "second from the north", and stop check_quests counting "wall" as a hint for the Wall object. Add placement() tests, rerun check_quests, report the unplaced count before and after. Don't commit.
```

### A3. Travel steps with no place: point somewhere anyway
Status: done 2026-10-30 (rules 1, 2 and 4)
Notes: Short NPC names via `Advance.MentionsPart`; a direction with no place becomes a `rough` spot 10 tiles that way from the last place (dots, no marker, arrival within 20 tiles); a travel step borrows the next step's own spot. travel-no-place 795 -> 370. Rule 3 (teleport destinations from the wiki) waits for a quests.lua rebuild.

Evidence: 795 travel steps have no spot. Patterns: "Return to Ug" (NPC
named by a short form the quest list doesn't match), "Return to the Duke",
"Head inside the room to the north", "Run to the south east end of the
cavern", "Run south to the farming patches", "Teleport to Anachronia".

Change, in `stepTargets`:
1. Short NPC names: match "Duke" to "Duke Horacio", "Ug" to "Ug", "the
   King" to the quest's one king, by first or last word of `questNPCs`
   names when only one NPC fits.
2. Relative directions with no anchor ("the room to the north", "run
   south"): nav = previous step's nav shifted 8 tiles that way, flagged
   `rough = true` so the beacon is drawn hollow and "arrived" uses a wider
   radius. `Advance.Compass` already parses the words.
3. "Teleport to <place>" with no link: `Travel.Named` covers lodestones;
   add the places quest guides teleport to with a named spot table built
   from the wiki (`build_quests.py`: for each quest's linked teleport items,
   take the destination coordinates from the item page's infobox or the
   "Teleport" page) rather than hand lists.
4. Sections' lead `{{Map}}` is already attached to the first step; also
   let a travel step with no spot borrow the *next* step's spot when the
   next step has one and isn't a travel step ("Go to the cave. Talk to
   Bob" with Bob mapped).

Verify: travel-no-place drops (target: under 500); EW1 replay unchanged;
a run.lua test for each of the four rules.

Prompt:
```
Do item A3 from plugin/IMPROVEMENTS.md: give travel steps with no map spot a place to point at (short NPC names, relative directions off the previous spot flagged rough, teleport destinations from the wiki via build_quests.py, borrowing the next step's spot). Add tests, rerun check_quests, report travel-no-place before and after. Don't commit; don't hand-edit quests.lua.
```

### A4. Pages that aren't NPCs are treated as NPCs
Status: done 2026-10-30 at runtime; rebuild pending
Notes: `stepTargets` takes an unplaced page as a person only when it's written as a name in the step. `build_quests.py` now gives infobox-less pages `kind = "other"`, which takes effect when quests.lua is rebuilt (needs guides_all.json, not in the repo).

Evidence: `stepTargets` puts every linked page with `kind == nil` into
`targets.npcs` ("worth a look"). 169 link-unknown findings include
"backpack", "minimap", "tool belt", "three wise monkeys", "water spells",
"Point of interest", quick-guide pages. They become names the world tries
to highlight and the card lists, and "no-nav" is partly them.

Change: in `build_quests.py`, classify a page that exists but has no NPC,
item, scenery or location infobox as `kind = "other"` (already the plan in
its comment at line 233; check why these slip through: redirects,
disambiguation pages, pages with `{{Infobox Monster}}`), and in
`stepTargets` only take `kind == nil` as an NPC when the page name is
capitalised in the step text. Monsters ("vyrewatch", "giant lobster")
should become `kind = "npc"` with no map.

Verify: link-unknown under 40; no-nav count drops; run.lua test that
"backpack" in a step's links isn't a target.

Prompt:
```
Do item A4 from plugin/IMPROVEMENTS.md: stop treating linked non-NPC pages (backpack, minimap, spells, guide pages) as NPC targets. Fix the classification in tools/build_quests.py, rebuild quests.lua with the cached wiki answers, add the stepTargets guard and a test, rerun check_quests and report link-unknown and no-nav before and after. Don't commit.
```

### A5. Finish more step kinds by themselves
Status: needs in-game check
Notes: API research: `SkillTransmit` and `Player.GetLevelCapped` exist; no worn-equipment inventory or event is documented (Inventory IDs page gives examples only). Cutscene steps could use the existing `checkCutscene`. Not implemented yet.

Evidence: besides A1, the no-trigger list has "Watch the cutscene" (41),
"Equip X" (44), "Kill X" (68; `KILL_MESSAGES` in `onChat` exist but the
checker doesn't count them as a trigger), "Read the book" (53), "Exit the
room / Leave the house" (60).

Change: cutscene steps finish when `checkCutscene` sees the cutscene end
after it began on that step; equip steps finish when the worn-equipment
interface changes (find the event or poll the worn slots every
BACKPACK_SCAN_EVERY ticks, API check needed); read steps finish when a new
non-dialogue interface opens after a click on the named object (the
dialogue watch already notices new interfaces); exit/leave steps finish by
distance from the step's start position (left the 12-tile circle). Teach
`check_quests.lua` about kill messages and cutscene steps so no-trigger
reflects reality.

Verify: run.lua tests with the mock firing the relevant events; recordings
confirm the worn-equipment and interface events exist (ask for a session
with an "Equip" step).

Prompt:
```
Do item A5 from plugin/IMPROVEMENTS.md: add auto-finish for cutscene, equip, read and exit/leave steps where the API allows it (check mock.lua and the recordings for the events; if an event isn't available, say so and skip that kind), and make check_quests count kill messages and cutscenes as triggers. Tests, checker numbers, no commit.
```

### A6. Climb steps that finish too early or not at all
Status: done 2026-10-30
Notes: "mine" is a verb only before a count, article or ore word; "twice" / "N times" / "N sets of" multiply the climb goal; "down"/"up" count only next to the climb; complete/finish are actions. The checker now uses `Advance.MainAction` for its climb-early list (so its count changed meaning: 95 -> 103 are review notes, not regressions).

Evidence: 95 climb-early: "Go down the ladder to enter the Dwarven mines"
(mines read as the verb "mine"), "Kill the golem and descend the stairs"
(the kill comes first, so the climb should finish it: fine), "Complete 1
lap of the agility course by climbing the rope ladder" (shouldn't finish
on the first ladder), "Equip the ancient mace and climb down" (fine).
`ClimbDirection` returns "down" for any " down" in the text ("Go down the
path to the ladder" is "down"), and `climb-multi` shows "Climb the
north-west staircase twice" counts one climb.

Change: `mine`/`mines` as a verb only before a/an/the/some/a number or an
ore word; "twice"/"two sets of"/"three times" multiplies the climb goal;
`ClimbDirection` "down" only when "down" is within 2 words of a climb word
or is "downstairs"; "climbing the rope ladder" inside a "complete the
course" step doesn't finish it (an action word before the climb that isn't
a travel word means wait).

Verify: climb-early under 60; tests for each phrase.

Prompt:
```
Do item A6 from plugin/IMPROVEMENTS.md: fix the climb classification cases listed there (mines as a noun, "twice", "down" far from the climb word, course laps). Tests, rerun check_quests, report climb-early before and after. No commit.
```

### A7. Number-only chat strings
Status: done 2026-10-30 for the card text
Notes: `Probe.ChatNumbers` / `Probe.ChatLabel`: "1 / 1" shows as "option 1, then option 1", "~" as "any option". Colouring the N-th option in the dialogue box needs an in-game look at how the numbered labels sit in the interface.

Evidence: 39 chat-empty findings: "1 / 1", "5", "4 X", "~ / ~". The guide
means "pick option 1, then option 1" or "any option". `Probe.ChatCandidates`
only yields option text, so nothing gets coloured and the card shows the
raw string.

Change: parse number chains into a list of option indexes per screen
(the Alt1 app already does "screen-stepped number chains" in app.js, copy
the rule), colour the N-th option in the dialogue interface, and show
"Chat: option 1, then 1" on the card. "~" means any option: show "Chat:
any option" and colour nothing.

Verify: run.lua dialogue test with a numbered chain; chat-empty 0.

Prompt:
```
Do item A7 from plugin/IMPROVEMENTS.md: support numeric chat chains ("1 / 1", "4 X", "~") in Probe.ChatCandidates and the option colouring, show them readably on the card, add a run.lua dialogue test, rerun check_quests (chat-empty should be 0). No commit.
```

### A8. Steps that lean on a picture
Status: done 2026-10-30 (mechanism)
Notes: Picture steps get "The wiki shows a picture for this step."; `tools/step_overrides.json` is merged into sub-bullets by `build_quests.py`. The file is empty: the puzzle solutions still need writing (wiki research), then a rebuild.

Evidence: 48 steps say "see the picture below", "as shown in the image",
"marked on the map". The card can't show images (Canvas draws game
sprites only; no web images). Puzzle steps (Slug Menace, Tale of the
Muspah, Monkey Madness, Elemental Workshop III levers) are the painful
ones.

Change: `Advance.WithoutPictureRefs` already strips the phrases; add a
muted line "The wiki shows a picture for this step" with the guide's
section anchor so the player can Alt+Tab to it. For the known puzzle
steps, add a small overrides file in `tools/` (quest key + step text
prefix → extra text lines, e.g. the Muspah tile coordinates or the lever
order) that `build_quests.py` merges in as sub-bullets. Keep it to steps
where the text alone is unusable.

Verify: the overrides land in quests.lua subs; `check_quests` "picture"
findings all carry the note.

Prompt:
```
Do item A8 from plugin/IMPROVEMENTS.md: add the "the wiki shows a picture for this step" note for picture steps and a tools/step_overrides.json merged by build_quests.py with text solutions for the puzzle steps the checker lists under "picture" where the text alone doesn't work. Rebuild quests.lua, tests, no commit.
```

### A9. Long steps and list-headed steps on the card
Status: done 2026-10-30
Notes: Instructions over 300 characters are cut on the card with "(more in the panel)"; list steps ("Locations:") tick one sub-bullet per Alt+D (saved as `subDone`), the last press moves the step on; "Done, next" still moves the whole step.

Evidence: 39 steps over 900 characters; steps whose text is just a header
("Locations:", "Investigate:", "Solve the four puzzles:") with everything
in sub-bullets, capped at 8 on the card.

Change: on the card, cut the instruction at 4 lines with "… (more in the
panel)"; for header steps, show the sub-bullets as a numbered list and
let Alt+D (or the checkbox) tick through them one at a time: keep a
`subDone` counter per step in the saved state, highlight the next
sub-bullet, finish the step when the last is ticked. The Alt1 app ticks
sub-steps already; mirror its behaviour.

Verify: run.lua test on a header step: Alt+D advances the sub-bullet, not
the step, until the last one; card-long 0.

Prompt:
```
Do item A9 from plugin/IMPROVEMENTS.md: truncate very long instructions on the card with a pointer to the panel, and make header steps ("Locations:") walk their sub-bullets one at a time with Alt+D / the checkbox before finishing. Tests, no commit.
```

### A10. Teleports the guide itself names
Status: done 2026-10-30
Notes: `Advance.NamedTeleport`: medallions, ectophial, fairy ring codes, tablets, "via X". Shown on the card and under the player; the lodestone hint is dropped; dots are suppressed while far (60 tiles). Landing spots for the dots still need the wiki data.

Evidence: `Travel` only knows lodestones (1,075 hints computed). Guides
say "Teleport to the Meiyerditch Laboratories via Drakan's medallion",
"use the Ectophial", "fairy ring code CKR", "Ring of kinship". The
lodestone hint then argues with the step.

Change: when the step text names a teleport (medallion, ectophial, fairy
ring code, tablet, "teleport to X via Y"), suppress the lodestone hint and
put "Teleport: <what the step says>" on the card instead. Later: a small
table of teleport items → destination tiles built from the wiki (same
pipeline as A3.3) so the dots can start from the landing spot.

Verify: run.lua test: a step naming Drakan's medallion shows no lodestone
hint; `pathSuppressed` behaviour unchanged for lodestone hints.

Prompt:
```
Do item A10 from plugin/IMPROVEMENTS.md: when a step names its own teleport (medallion, ectophial, fairy ring code, tablet, "via X"), show that on the card instead of a lodestone hint. Add a test. No commit.
```

### A11. Better world indication: model highlight and minimap arrow
Status: needs in-game check
Notes: API research: no minimap or world-map drawing call found; `MapElementType` is config only (sprite, text, showOnMiniMap flags). No entity outline call found either. Nothing to build on yet; keep an eye on API updates.

Evidence: we outline the tile and bob an arrow; the official plugin has a
minimap arrow and (per its issues) highlighted models. The API pages read
so far show no minimap call; `/rs/game/config/mapelementtype.html` and the
ScreenConvert page are unread.

Change: research first (see E1). If a minimap/world-map element can be
placed, add a minimap arrow to the nav tile. If entity outlines exist,
outline the NPC/object model instead of its tile for the nearest target.
Keep the tile outline as the fallback.

Prompt:
```
Do item A11 from plugin/IMPROVEMENTS.md, research half only: read the Jagex API pages for map elements, ScreenConvert and entity highlighting and write what is possible (with exact calls) into the item's notes. Don't change plugin code yet.
```

### A12. "Return to X" where X has no map but was met earlier: wider match
Status: done 2026-10-30
Notes: `Advance.MentionsPart` (first or last word, 4+ letters, not a generic kind of person) in `stepTargets` and `StepMentions`, so "Talk to Veldaban" finds Commander Veldaban and the click on him matches the step. no-nav 817 -> 713.

Evidence: no-nav 817 includes NPCs met earlier under a longer name
("Veldaban" vs "Commander Veldaban", "Jhallan", "Gujuo"). `stepTargets`
inherits the spot only on an exact display-name match.

Change: match earlier NPC names by last word or by containment when
unambiguous within the quest; reuse that step's nav.

Verify: no-nav drops; test "Talk to Veldaban" after "Talk to Commander
Veldaban" points at the same spot.

Prompt:
```
Do item A12 from plugin/IMPROVEMENTS.md: let "Return to Veldaban" find "Commander Veldaban" met earlier (last-word or containment match when unambiguous) and reuse that step's spot. Test, check_quests no-nav before/after, no commit.
```

### A13. Coins in the money pouch, free backpack slots, "Backpack full"
Status: done 2026-10-31; money pouch inventory to confirm in game
Evidence: beta session 6 (Fight Arena). "5 coins (0/5)" stayed red with 788 coins in the money pouch (the plugin only read the backpack). "3 free inventory slots during the first stage" had no check, the backpack was full, the "Borrow" on the suit of armour failed but the quest var still moved, so the step was ticked with nothing in the bag. "Beer or 2 coins to purchase a pint" only ever checked the beer.
Notes: Coins from the money pouch are counted as backpack coins (`readBackpack`: an `id.Inv` name with POUCH/MONEY, else `config.Inv.FromID(623)`; the docs don't list the pouch, so the Probe API button logs the inventory names and ids 94/623, and `diag.moneyPouch` says what was found). Free slots from `Inv.freeSlotCount` (docs: Inventory page), lines like "N free inventory slots" show "(free: X/N)". A step with a "Get:" list and fewer free slots than missing items shows "Backpack full: free N slots first." in red. "X or Y" lines check each option with its own count and purpose clause dropped (`Advance.OptionNeed`). Not done: holding a step's tick when its var moves but the item never arrived (the var is the more reliable signal in general); worn equipment still isn't readable (no inventory documented, see A5).
Prompt:
```
Do item A13 from plugin/IMPROVEMENTS.md: after an in-game Probe API run, set the money pouch inventory from what it logged (name or id) instead of the search, and if a worn-equipment inventory shows up, use it for "Equip the armour" steps (A5). Test, no commit.
```

### A14. Progress moves that don't match the guide's steps
Status: done 2026-10-31 (talk and fight steps); replay of beta session 6 matches the play
Evidence: Fight Arena, beta session 6: the var moved for the arena cutscene (14:46) and each stage, so "Kill the Khazard ogre" ticked before the fight, "Talk to Hengrad" and "Open the prison door" ticked while the player was still in the arena. Also: "Talk to Angor in the bar" outlined three bar counters; "Sammy's cell door north of Lazy Khazard Guard" highlighted the guard and no door; "buy a bottle of Khali brew for five coins" never finished because coins counted as a wanted item; option 2 in Angor's dialogue wasn't blue because the options interface opens after "Continue", when the dialogue watch had already stopped.
Notes: `recentActs` (app.lua) remembers the last Talk-to and Attack and when each step began. A progress move on a "Talk to X" step (MainAction talk/speak, NPC targets) counts only after a Talk-to on X since the previous step began, otherwise it's held (`recentActs.pending`, recording note "progress moved on step N, waiting for a talk on X"); the talk then finishes the step. A "Kill X" step needs an Attack on X before the move. A second move while holding counts for one step; after `TUNE.holdVar` (200 ticks) it counts anyway. Landmark NPCs go to `targets.landmarks` (anchors for placements, not highlighted); "in"/"at" are landmark words; a use-on-door step gets the door fallback with the step's placement; coins after "for ... coins" aren't acquire wants; the dialogue watch restarts on "Continue" and keeps going after the first interface; `id.Interface.DIALOGUE_OPTIONS` seeds the options interface. Not done: per-quest var tables (the official helper's approach) for steps that aren't talk or fight; "Open the prison door" still needs chat access (own click) or the next var.
Prompt:
```
Do item A14 from plugin/IMPROVEMENTS.md: review the held-var rule against new recordings (read_rec notes "waiting for"), tune TUNE.holdVar, and consider holding "Enter/Open the door" steps until a door click. Test, replay every session, no commit.
```

---

## B. UI and text for any screen size and ratio

### B1. Card size and position follow the screen
Status: done 2026-10-30 offline; confirm in game
Notes: Width is a share of the plugin layer's width (small 0.22 / medium 0.28 / large 0.36, 360..640 units) when the layer reports a size, else 480; the saved position is clamped on build; `WindowSizeChanged` rebuilds the card. Check in game that `layer.width` is reported (Probe API button logs it).

Evidence: `card.lua` has `WIDTH = 480` fixed in interface units, the font
fixed at `MUSEO_SANS_15PT_REGULAR`, default position y=70 top centre, and
a saved absolute position. A card dropped at the right edge on 2560 wide
sits off-screen at 1366 wide; on 4K with 100% UI scale it's a small box.
No `ONRESIZE` handling anywhere.

Change:
1. On `build` and on the plugin layer's `ONRESIZE`, clamp the saved
   position so the whole card is inside the layer (`layer.width/height`).
2. Card width as a share of the layer width (`SetSize(0, h, 0.28, 0)`)
   with a minimum of 360 and maximum of 640 units; recompute `CharsFor`
   from the actual `box.width` after `UpdateLayout`.
3. Settings: "Card: small / medium / large" (width share 0.22 / 0.28 /
   0.36) next to the Dots setting; if the FontType list has a larger Museo
   Sans, "Text: normal / large" too, with `UNITS_PER_CHAR` measured per
   font (E2).
4. The floating teleport line: width from the text length, not a fixed
   360.

Verify: mock gets `width/height` on the layer and an `ONRESIZE` hook;
tests: card clamped after a resize, width share applied, settings row
present. Then an in-game check at two resolutions (ask for a recording;
`Diag.Snapshot("panelSize")` already logs the panel size, add the layer
size too).

Prompt:
```
Do item B1 from plugin/IMPROVEMENTS.md: make the step card size itself from the plugin layer width (with min/max), clamp its saved position on build and on ONRESIZE, add a Card size setting, size the floating teleport text to its content, and log the layer size in diagnostics. Extend mock.lua as needed, add tests, update README. No commit.
```

### B2. Panel re-layout on resize
Status: done 2026-10-30
Notes: `ONRESIZE` on the panel root, redraw 10 ticks after it settles, plus a width poll every 50 ticks in case the hook never fires.

Evidence: `View.Render` reads `root.width/height` once; the redraw is
skipped when the row signature is unchanged. Resizing the panel window in
game leaves text wrapped for the old width (cut off or with gaps) until
the step changes. The scroll offset isn't re-clamped either.

Change: in `Event.ContentLayerReady` subscribe `panelRoot` to `ONRESIZE`,
and on it reset `panelSignature` and call `refreshPanel` (debounced to one
redraw per 10 ticks since resize fires continuously); include the width in
the signature so a width change always redraws; call `applyScroll` after.

Verify: run.lua: fire the resize hook on the mock root with a new width,
check the body is rebuilt with a different `contentWidth` and the scroll
offset stays within range.

Prompt:
```
Do item B2 from plugin/IMPROVEMENTS.md: redraw the panel when its root resizes (ONRESIZE, debounced), include the width in the row signature, re-clamp the scroll offset. Mock hook plus test. No commit.
```

### B3. Text wrapping that matches the game
Status: done 2026-10-30 offline; confirm in game
Notes: In game on 2026-10-30 the panel drew one item over the next: the diagnostics said `textMeasure = estimate` (the first version called `GetStringHeightAndLineCount(text, width)`, but the FontType docs want `(text, wrapWidth, lineSpacing, ...)` and return the height first, so the call threw), and the average-width estimate wrapped a line of wide letters a row too late. Now: `View.TextHeight` tries `font:GetStringLineCount(text, width)` per `<br>` paragraph, then `GetStringHeightAndLineCount(text, width, 18)`, else the estimate; and the estimate uses per-glyph widths (`View.TextWidth`, Museo Sans advance widths scaled to 16.2 units per em, fitted to four wrap points from the screenshot). Still to confirm in game: that `wrapWidth` in pixels equals interface units at the player's UI scale (Probe API logs the measured and estimated width of one string), and whether `font.baseline` should replace the fixed 18-unit line height.

Evidence: `View.LineCount` estimates wrapped lines from an average
character width (7.1 units) measured once for one font. Long words, many
narrow letters ("ill") or wide ones ("WWW") throw it off, leaving gaps or
cut-off last lines. The API has no text-measure call.

Change: two options, pick after E2: (a) read the `ui.Text` component's
`height` after `UpdateLayout` with `maxLines = 0` and lay out the next
block from that (if the engine reports the wrapped height, the estimate
goes away entirely); (b) if it doesn't, keep the estimate but calibrate
per font in game with a probe string and add 1 line of slack only for
blocks longer than 3 lines, and treat words longer than `charsPerLine` as
breaking mid-word (already done).

Verify: in-game screenshots of the longest steps (Dimension of Disaster
#1, While Guthix Sleeps #107) at two panel widths.

Prompt:
```
Do item B3 from plugin/IMPROVEMENTS.md after E2 is answered: if the engine reports a Text component's wrapped height, lay the card and panel out from that instead of View.LineCount; otherwise calibrate UNITS_PER_CHAR per font from the probe and add the slack rule. Tests for the layout code path. No commit.
```

### B4. Card header overflow
Status: done 2026-10-30
Notes: `Card.Title` shortens the name so the counter fits.

Evidence: the header button label is `"<quest name>  3 / 22"`; names like
"Once Upon a Time in Gielinor: Foreshadowing" or "Recipe for Disaster:
Freeing King Awowogei" overflow the 480-unit button and get clipped.

Change: shorten the name to fit (`CharsFor(WIDTH - 60)` characters, with
"…"), keep the step counter always visible; show the full name on the
panel title.

Verify: test that a long name produces a label within the limit.

Prompt:
```
Do item B4 from plugin/IMPROVEMENTS.md: shorten long quest names on the card header so the step counter always fits. Test, no commit.
```

### B5. Scrolling quality of life
Status: done 2026-10-30
Notes: List scroll remembered across a guide, "Current step" button, scroll bar on the right, wheel step a quarter of the view.

Evidence: no scrollbar, no "jump to current step", list scroll position
lost when coming back from a guide (`View.ScrollToTop` on every screen
switch), wheel step fixed at 40 units. The official plugin gets the same
complaint (their issue #445).

Change: remember the list's scroll offset when opening a quest and restore
it on "Quest list"; add a thin scroll indicator (a 4-unit rectangle on the
right whose height/position reflect `scroll.offset / content`); add a
"Current step" button next to the progress bar that scrolls to the anchor;
wheel step proportional to view height (a quarter of it).

Verify: run.lua: open a quest from a scrolled list, go back, offset
restored; "Current step" button lands at the anchor.

Prompt:
```
Do item B5 from plugin/IMPROVEMENTS.md: restore the quest list's scroll position when returning from a guide, add a scroll indicator and a "Current step" button, and scale the wheel step to the view height. Tests, README line. No commit.
```

### B6. Card content priorities on small screens
Status: done 2026-10-30
Notes: Settings > Card detail: full / compact. The small-screen default waits for B1's in-game numbers.

Evidence: the card stacks instruction, chat, up to 8 sub-bullets, Bring
and Get lists, plus a teleport line, with `MAX_BLOCKS = 40`. On a laptop
screen this covers a third of the view.

Change: a "Card detail: full / compact" setting. Compact = instruction,
chat, teleport line, and items only when something is missing (red lines);
sub-bullets and owned items go to the panel. Default compact when the
layer is under 1300 units wide (after B1 the width is known).

Verify: test both modes' block lists from `stepBlocks`.

Prompt:
```
Do item B6 from plugin/IMPROVEMENTS.md: add a compact card mode (instruction, chat, teleport, missing items only) with a setting and a small-screen default. Tests, README. No commit.
```

### B7. Finding a quest in the list
Status: done 2026-10-30 except the search box
Notes: All / Started / Not started / Done filters (Started includes steps ticked here) and A-D ... U-Z jumps (`View.ScrollToRow`). `ui.InputField` exists per the docs (ONCONTENTCHANGED, emptyText), but a filter-as-you-type box would be destroyed by the redraw it triggers; it needs to live outside the rebuilt body. Not done.

Evidence: `listRows` draws all 372 quests as one scrolling list (started
first, then A to Z, done last) with the credits paragraph above it every
time. No search, no filter, no jump. The web app has search, "hide done",
"can do now" and sort modes.

Change: a filter row above the list: "All / Started / Not started / Done"
buttons and an "A-Z" jump (a row of letter buttons that scrolls to that
letter, cheap with the existing anchor mechanism). If the API has a text
input component (check `/rs/ui/` for TextInput or similar in E2), a search
box that filters as you type. Move the credits to Settings > About only
(already there) and keep one short line on the list.

Verify: run.lua: pressing "Done" shows only complete quests; the letter
jump lands on the first quest with that letter.

Prompt:
```
Do item B7 from plugin/IMPROVEMENTS.md: add status filter buttons and an A-Z jump row to the quest list, and a search box if the API offers a text input (say so if it doesn't). Tests, README. No commit.
```

---

## C. Opening a quest lands on the top, not on the current step

### C1. Panel: start at requirements and items
Status: done 2026-10-30
Notes: `openQuest` and `restartQuest` set `focusedStep` before `setStep`, so the first render doesn't focus.

Evidence: `openQuest` calls `View.ScrollToTop()` and then `setStep`, which
calls `refreshPanel`; there `focus` is true because the step key differs
from `focusedStep`, so `View.Render` scrolls to the current step
(`anchorY - 60`) and the items overview scrolls off. The same happens when
coming back to a quest already in progress. The user wants the top first:
status, progress, items needed, recommended, then the steps.

Change: in `refreshPanel`, only focus when the step changed *while already
on that quest's guide screen*: keep `focusedStep` but set it to the new
quest's key in `openQuest` (and `restartQuest`) before `setStep`, so the
first render of a newly opened quest has `focus = false`. Later step
changes keep scrolling to the step. Add the "Current step" button from B5
if not done yet, so a long quest is one click from the step.

Verify: run.lua: open a quest with the step index saved at 7, check
`scroll.offset == 0` (expose it via `World`/`View` or `M.db["diag.*"]`),
then advance a step and check the offset moved to the anchor; opening the
same quest again from the list lands at 0 again.

Prompt:
```
Do item C1 from plugin/IMPROVEMENTS.md: opening a quest (and restarting one) must show the panel from the top (status, items needed, recommended) instead of scrolling to the current step; later step changes still scroll to the step. Add the run.lua checks described, update README. No commit.
```

### C2. Requirements block at the top of a quest
Status: done 2026-10-30 from game data
Notes: Requirements come from `config.Quest.preReqSkills` / `preReqQuests` / `preReqQuestPoints` with `Player.GetLevelCapped` for the player's level, no wiki data needed. Start point and rewards not shown (not in the game data read so far).

Evidence: the panel shows status, progress, "Items needed" and
"Recommended" only. The quest page's `{{Infobox Quest}}` has requirements
(skills, quests, items), start point, length and rewards. The game's own
flag gives "Missing reqs" but not which. The official plugin shows
requirements and rewards in its overview.

Change: `build_quests.py` extracts `requirements`, `start`, `length` and
`rewards` from the infobox (plain text lines, quest links resolved to
names); the panel gets a "Requirements" heading above "Items needed" with
each line, and quest prerequisites coloured green/red from the game's
quest status (`questStatus` by name). Skill levels: colour them if the API
exposes skill levels (E3), else plain. "Start" gets a map spot used as the
beacon before step 1 is reached. A "Hide overview" toggle already exists
and should cover the new block.

Verify: rebuild quests.lua; tests on `guideRows` output for a quest with
prerequisites; checker unaffected.

Prompt:
```
Do item C2 from plugin/IMPROVEMENTS.md: pull quest requirements, start point, length and rewards from the quest infobox in build_quests.py, show a Requirements block at the top of the guide with prerequisite quests coloured by the game's quest status, and use the start point as the beacon before step 1. Rebuild quests.lua from the cached wiki answers, tests, README. No commit.
```

### C3. Web app (Alt1): same preference
Status: open (master branch)
Notes: The web app lives on master; this branch only carries the plugin.

Evidence: `app.js openQuest` → `renderSteps` → `scrollCurrentToTop`, which
lands on the first section heading for a fresh quest but on the current
step for one in progress. `style.css` has no `@media` rules at all, so
narrow Alt1 windows squeeze the two-column header.

Change: a setting "On opening a quest: show the top / show the current
step" (default top, to match the plugin), honoured in `openQuest`; add
breakpoints at 520 and 380 px for the header tools, items panel and step
rows (stack the search and sync row, shrink paddings, keep buttons
reachable).

Verify: test.html cases for the setting; manual check at 380 px wide.

Prompt:
```
Do item C3 from plugin/IMPROVEMENTS.md on the master branch's web app (app.js, style.css, test.html): add an "on open: top / current step" setting defaulting to top, and responsive breakpoints at 520 and 380 px. Tests in test.html, no commit.
```

---

## D. Items and guide text quality

### D1. "Bring:" lines with no help
Status: done 2026-10-30
Notes: Kit advice ("combat gear and food") is shown in grey with no check; "X or Y" lines were already checked for either.

Evidence: 520 item lines (270 distinct) can't be explained: "combat gear
and food" (78), "ice gloves for defeating Flambeed", "blisterwood weaponry
or Ivandis flail", "an anti-dragon shield or super antifire potion".
These are kit phrases, not items, and `checkable()` already knows
KIT_WORDS; they still show as unchecked items.

Change: classify lines with "or", "such as", "for <purpose>" and kit words
as advice: show them muted under a "Bring (your choice)" heading, no
backpack check, no GE lookup. Lines like "X or Y" with two real items:
check for either (`HaveCount` over alternatives).

Verify: itemsNoHelp near 0; tests on `stepItems` for an "A or B" line and a
kit line.

Prompt:
```
Do item D1 from plugin/IMPROVEMENTS.md: treat kit phrases and "X or Y" item lines as advice or alternatives instead of unchecked items. Tests, check_quests itemsNoHelp before/after, no commit.
```

### D2. Regression gate for the checker
Status: done 2026-10-30
Notes: `check_quests.py --baseline tests/check_baseline.json` (and `--write-baseline`); `run.py --full <wiki cache>` runs it and fails on new bug-class findings. Baseline committed with today's numbers.

Evidence: the checker is run by hand and compared by eye. Today's fixes
were verified by diffing JSON files in the scratchpad.

Change: `tests/check_quests.py --baseline plugin/tests/check_baseline.json`
writes/compares the per-kind counts and the exact set of (quest, step,
kind) findings; `run.py --full` runs it and fails on new findings of the
kinds that mean a bug (jump-own, jump-retalk, jump-click, linked-missed,
climb-early, travel-early). Commit the baseline with each change that
moves it, so the diff shows what moved.

Prompt:
```
Do item D2 from plugin/IMPROVEMENTS.md: add a baseline file and --baseline comparison to tests/check_quests.py, and a run.py --full mode that fails on new bug-class findings. Document it in README. No commit.
```

---

## E. Things to find out in game (research tasks)

Each of these is a short probe added to the test build's `devtools.lua`
(behind the Show debug button) plus a recording, so the answer ends up in
the diagnostics and in this file.

### E1. Minimap / world-map elements and entity highlighting
Status: research done; probe pending
Notes: See A11. `Probe API` in the Debug section logs what the client reports.

Read `/rs/game/config/mapelementtype.html`, `/rs/game/screenconvert.html`
and the entity pages on developer.runescape.com; try creating a map
element at the nav tile; try an outline on an NPC entity. Record what
worked. Feeds A11.

Prompt:
```
Do item E1 from plugin/IMPROVEMENTS.md: read the three API pages, write the findings into the item, and add a devtools probe for anything that looks possible. No commit.
```

### E2. Screen size, UI scale, fonts, text height
Status: research done; probe pending
Notes: Docs: `WindowSizeChanged(oldWidth, oldHeight, newWidth, newHeight)`, component `width`/`height` are read-only properties, `ONRESIZE` exists, `config.Font` has `GetStringWidth`, `GetStringHeightAndLineCount`, `SplitString`. No screen-size getter or UI-scale getter found; the font list isn't on the docs page. `Probe API` logs layer size, a measured string and the font table.

Probe: `pluginLayer().width/height` at two window sizes, whether
`ONRESIZE` fires on the layer and on the panel root, the `id.Font` table
contents (which Museo sizes exist), and whether a `ui.Text` with
`maxLines = 0` reports its wrapped `height` after `UpdateLayout`. Feeds
B1, B3.

Prompt:
```
Do item E2 from plugin/IMPROVEMENTS.md: add a devtools probe that logs the plugin layer size, the font list, and a wrapped Text component's height to diagnostics, then tell me what to click in game and what recording to send back. No commit.
```

### E3. Skill levels, worn equipment, quest requirement data
Status: research done; probe pending
Notes: Docs: `Player.GetLevelCapped(skill)` / `GetLevelGameplay`, `SkillType` enum 0..28, `SkillTransmit` event; `config.Quest` has `preReqSkills` (skillType, minimumLevel), `preReqQuests`, `preReqQuestPoints`, `difficulty`, `questPoints`. Worn equipment: not documented.

Probe: is there a player skills API (level per skill), a worn-equipment
list or event, and does the quest data expose the requirement list the
game uses for "requirements not met". Feeds A5, C2.

Prompt:
```
Do item E3 from plugin/IMPROVEMENTS.md: find the API calls for skill levels, worn equipment and quest requirements (docs plus a devtools probe), write the answer into the item. No commit.
```

---

## F. Order I'd do them in

1. C1 (small, what the user asked for first), B4 (small polish).
2. A1, A4, A12 (biggest drop in "Done, next" presses and wrong targets).
3. E2 then B1, B2, B3 (screen sizes), then B5, B6, B7.
4. C2 and E3 together (requirements block).
5. A2, A3, A6, A7, A10, D1 (text understanding).
6. A8, A9 (pictures and long steps).
7. D2 (gate) once the numbers settle; E1 then A11 last (needs the API).

Master prompt for a batch:
```
Work through plugin/IMPROVEMENTS.md items C1, B4 and A1 in that order. For each: read the item, make the change, add the tests it names, run python plugin/tests/run.py, update the item's Status line, and give me a one-paragraph summary per item. Don't commit; stop and ask if an item needs an in-game check.
```
