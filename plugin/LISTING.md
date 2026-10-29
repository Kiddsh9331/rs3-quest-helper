# mod.io listing draft

Text to paste into the plugin's mod.io page when submitting the release zip
(`python plugin/tools/package.py --email ...`). Lines in [square brackets]
are choices to make before submitting. Requirements are from
developer.runescape.com/rs/submission/process.html and example.html; check
the EULA statement against that page word for word before pasting.

## Name (1 to 50 ASCII characters)

RS3 Quest Buddy

(Must match `NAME` in tools/package.py.)

## Summary (10 to 150 ASCII characters on mod.io's form)

Step-by-step guides for every RS3 quest from the RuneScape Wiki. Shows each step on screen, highlights who to talk to and moves on as you play.

## Tags

chatAccess (required: the plugin requests that permission), plus [whatever
category tags fit, e.g. Quests, Guide].

## Images

- Listing image: 16:9, at least 512x288 (e.g. the step card over the game).
- Gallery (up to 10): step card with highlights, the panel's step list,
  items needed with backpack checks, dialogue options turning blue, the
  dotted path, the settings screen.

## Description

**RS3 Quest Buddy** puts the RuneScape Wiki's quick guides inside the game,
for all ~370 quests, miniquests and sagas.

- **Step card** on the game screen: the current step, the chat options to
  pick, what to bring (checked against your backpack) and what to get.
- **The panel** (Plugins ribbon): every quest with its status, the full
  step list, and the items you need, green when you have them. Missing
  items say whether they're on the Grand Exchange; switch on Ironman to see
  how to make them instead.
- **Highlights**: the NPCs and objects the step is about get a tile outline
  and an arrow, including the right stairs when you're on the wrong floor.
- **Moves on by itself** as you play: talking to the next person, picking
  up the items, climbing where the step says, arriving, or the quest's own
  progress. "Done, next" and the step checkboxes always work too.
- **Dialogue**: the step's chat options turn blue in the conversation.
- **Finding the way** [only if the build has guidance]: a dotted path
  towards the next place, a marker on the step's map tile, and which
  lodestone to use when it's far. Each can be switched off in Settings.

Every quest's guide comes from the wiki and was checked by script, but only a
handful have been played through with the plugin so far. If a step doesn't
move on, press "Done, next", and please report it (see Feedback).

### Credits

Quest guides and item details from the RuneScape Wiki (runescape.wiki),
used under CC BY-NC-SA 3.0. This plugin is free and not made or endorsed
by Jagex or the RuneScape Wiki.

### Feedback and collaboration

Bug reports and suggestions: GitHub issues at
https://github.com/Kiddsh9331/rs3-quest-helper/issues [or the plugin's
channel in the RuneScape Plugin Portal discord, once there is one].
[Collaboration stance, e.g.: "Pull requests are welcome; please open an
issue first for bigger changes." or "This is a solo project; contributions
aren't accepted, but suggestions are."]

### Permissions

This plugin requests the optional chatAccess permission. It is used to
read game messages about kills ("You have slain..."), so a step that asks
you to defeat something moves on once the game says it's done. The plugin
works without it; those steps then move on when the quest progresses or
when you press "Done, next". No other permissions are requested.

### Data protection (case 1)

Any information collected does not leave the local plugin.

Data used: the plugin reads the quest statuses and progress values the game
provides, your position, your backpack contents, what you click and the
conversation text on screen, to know which step you're on. It saves your
place in each quest and your settings. If you switch on "Recording" in
Settings (off by default), it also keeps a log of your last few sessions
(where you walked, your backpack, what you clicked, quest progress and
conversation text; never players' chat or names) so a problem can be
replayed if you choose to send it in. All of this stays in the plugin's own
storage on your device. This information is not transmitted outside of the
plugin under any circumstances.

[Contact email: not required to be public for case 1, but mod.io and
plugin.json still need one. Use a separate address from your RuneScape and
mod.io logins.]

### EULA

This Plugin uses software licensed by Jagex to the developer under the terms of the Jagex End User Licence Agreement (EULA) found at https://legal.jagex.com/docs/terms/eula (and all terms incorporated into it by reference). The development and any use of the Plugin is at all times subject to the Jagex EULA.

## Upload

- Zip from `tools/package.py` (main.lua and plugin.json at its top level).
- Platforms: Windows, Linux, Android, iOS, and Source.
- Mark the listing hidden until it's ready; don't change the mod.io page
  during the review's "submission freeze".
