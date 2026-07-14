/* RS3 Quest Helper — Alt1 overlay app.
 *
 * Home view lists every quest/miniquest quick guide on the RuneScape Wiki
 * (fetched from Category:Quick guides, cached locally). Selecting one
 * downloads its quick-guide wikitext, parses it into checkable steps, tracks
 * progress in localStorage, and can paint the current step onto the game
 * screen via Alt1's overlay API. */
(function () {
	"use strict";

	var WIKI_API = "https://runescape.wiki/api.php";
	var INDEX_CACHE_KEY = "rs3qh-index-v1";
	var GUIDE_CACHE_KEY = "rs3qh-guides-v6";
	var PROGRESS_KEY = "rs3qh-progress-v2";
	var INDEX_TTL_MS = 7 * 24 * 3600 * 1000;
	var GUIDE_TTL_MS = 7 * 24 * 3600 * 1000;
	var GUIDE_CACHE_MAX = 50;
	var OVERLAY_REFRESH_MS = 10000; // Alt1 overlays expire; repaint every 10s.

	var RM_URL = "https://apps.runescape.com/runemetrics/quests?user=";
	var RM_CACHE_KEY = "rs3qh-rm-v1";
	var RM_TTL_MS = 30 * 60 * 1000;
	var ORDER_CACHE_KEY = "rs3qh-order-v1";
	var ORDER_TTL_MS = 7 * 24 * 3600 * 1000;
	var PREFS_KEY = "rs3qh-prefs-v1";

	var questIndex = [];    // [{ title: "X/Quick guide", name: "X" }]
	var guide = null;       // parsed guide for the open quest
	var flatSteps = [];     // steps flattened across sections, in order
	var progress = load(PROGRESS_KEY, {});
	var prefs = load(PREFS_KEY, { rsn: "", hideDone: false, sort: "az" });
	var rmStatuses = null;  // { normalised quest name: "COMPLETED" | "STARTED" | "NOT_STARTED" }
	var optimalRank = null; // { normalised quest name: position in progression guide }
	var overlayTimer = null;

	// ---------- storage ----------

	function load(key, fallback) {
		try {
			var v = JSON.parse(localStorage.getItem(key));
			return v === null || v === undefined ? fallback : v;
		} catch (e) {
			return fallback;
		}
	}

	function store(key, value) {
		try {
			localStorage.setItem(key, JSON.stringify(value));
		} catch (e) { /* storage full — non-fatal */ }
	}

	function questProgress() {
		if (!progress[guide.title]) progress[guide.title] = { done: {} };
		var p = progress[guide.title];
		if (!p.items) p.items = {};
		return p;
	}

	function itemChecked(name) {
		return !!questProgress().items[name.toLowerCase()];
	}

	function setItemChecked(name, val) {
		if (val) questProgress().items[name.toLowerCase()] = true;
		else delete questProgress().items[name.toLowerCase()];
		store(PROGRESS_KEY, progress);
	}

	// ---------- wiki api ----------

	function wikiGet(params, cb, errcb) {
		params.format = "json";
		params.origin = "*"; // anonymous CORS
		var qs = Object.keys(params).map(function (k) {
			return encodeURIComponent(k) + "=" + encodeURIComponent(params[k]);
		}).join("&");
		var xhr = new XMLHttpRequest();
		xhr.open("GET", WIKI_API + "?" + qs);
		xhr.onload = function () {
			try {
				cb(JSON.parse(xhr.responseText));
			} catch (e) {
				errcb("Bad response from the wiki.");
			}
		};
		xhr.onerror = function () { errcb("Could not reach runescape.wiki."); };
		xhr.send();
	}

	function fetchQuestIndex(cb, errcb) {
		var cached = load(INDEX_CACHE_KEY, null);
		if (cached && Date.now() - cached.ts < INDEX_TTL_MS) {
			cb(cached.list);
			return;
		}
		var all = [];
		(function page(cont) {
			var params = {
				action: "query",
				list: "categorymembers",
				cmtitle: "Category:Quick guides",
				cmtype: "page",
				cmlimit: "500"
			};
			if (cont) params.cmcontinue = cont;
			wikiGet(params, function (data) {
				var members = (data.query && data.query.categorymembers) || [];
				members.forEach(function (m) {
					if (/\/Quick guide$/.test(m.title)) {
						all.push({
							title: m.title,
							name: m.title.replace(/\/Quick guide$/, "")
						});
					}
				});
				if (data["continue"] && data["continue"].cmcontinue) {
					page(data["continue"].cmcontinue);
				} else {
					all.sort(function (a, b) { return a.name.localeCompare(b.name); });
					store(INDEX_CACHE_KEY, { ts: Date.now(), list: all });
					cb(all);
				}
			}, function (msg) {
				// Fall back to a stale cache rather than showing nothing.
				if (cached) cb(cached.list);
				else errcb(msg);
			});
		})(null);
	}

	function fetchGuide(title, cb, errcb) {
		var cache = load(GUIDE_CACHE_KEY, {});
		var hit = cache[title];
		if (hit && Date.now() - hit.ts < GUIDE_TTL_MS) {
			cb(hit.data);
			return;
		}
		wikiGet({ action: "parse", page: title, prop: "wikitext" }, function (data) {
			if (!data.parse || !data.parse.wikitext) {
				errcb("The wiki returned no guide for this quest.");
				return;
			}
			var parsed = parseQuickGuide(data.parse.wikitext["*"]);
			parsed.title = title;
			parsed.name = title.replace(/\/Quick guide$/, "");
			cache[title] = { ts: Date.now(), data: parsed };
			pruneGuideCache(cache);
			store(GUIDE_CACHE_KEY, cache);
			cb(parsed);
		}, errcb);
	}

	// ---------- runemetrics + optimal order ----------

	// Match quest titles across sources: RuneMetrics and the wiki write
	// names slightly differently ("(miniquest)" suffixes, punctuation).
	function normName(s) {
		return s.toLowerCase()
			.replace(/\(miniquest\)|\(saga\)/g, "")
			.replace(/&/g, "and")
			.replace(/[^a-z0-9]+/g, "");
	}

	// Parse a RuneMetrics quests payload into a normalised status map, or
	// return null when it does not look like quest data.
	function parseRmPayload(text) {
		var data;
		try {
			data = JSON.parse(text);
		} catch (e) {
			// Some proxies wrap the payload in metadata — dig the quests
			// object out of the body.
			var s = text.indexOf('{"quests"');
			if (s === -1) return null;
			var depth = 0, e2 = -1;
			for (var i = s; i < text.length; i++) {
				if (text[i] === "{") depth++;
				else if (text[i] === "}" && --depth === 0) { e2 = i + 1; break; }
			}
			if (e2 === -1) return null;
			try {
				data = JSON.parse(text.slice(s, e2));
			} catch (e3) {
				return null;
			}
		}
		if (!data || !data.quests || !data.quests.length) return null;
		var statuses = {};
		data.quests.forEach(function (q) {
			statuses[normName(q.title)] = q.status;
		});
		return statuses;
	}

	// RuneMetrics sends no CORS headers, so a direct request only works in
	// permissive environments. Fall back through public CORS proxies; the
	// only thing sent is the (public) player name.
	function rmUrls(name) {
		var direct = RM_URL + encodeURIComponent(name);
		return [
			direct,
			"https://corsproxy.io/?url=" + encodeURIComponent(direct),
			"https://proxy.corsfix.com/?" + direct,
			"https://r.jina.ai/" + direct,
			"https://api.allorigins.win/raw?url=" + encodeURIComponent(direct)
		];
	}

	function fetchRuneMetrics(name, force, cb, errcb) {
		var cached = load(RM_CACHE_KEY, null);
		if (!force && cached && cached.name === name && Date.now() - cached.ts < RM_TTL_MS) {
			cb(cached.statuses);
			return;
		}
		var urls = rmUrls(name);
		(function attempt(i) {
			if (i >= urls.length) {
				errcb("Could not reach RuneMetrics directly or via a proxy. Use \"Import manually\" below — that always works.");
				return;
			}
			var xhr = new XMLHttpRequest();
			xhr.open("GET", urls[i]);
			xhr.timeout = 10000;
			xhr.onload = function () {
				var statuses = parseRmPayload(xhr.responseText);
				if (statuses) {
					store(RM_CACHE_KEY, { ts: Date.now(), name: name, statuses: statuses });
					cb(statuses);
				} else if (i === 0 && xhr.status === 200) {
					// Direct request answered but without quests: private profile.
					errcb("RuneMetrics returned no quests — is the profile set to private? (RuneMetrics settings in game)");
				} else {
					attempt(i + 1);
				}
			};
			xhr.onerror = function () { attempt(i + 1); };
			xhr.ontimeout = function () { attempt(i + 1); };
			xhr.send();
		})(0);
	}

	function fetchOptimalOrder(cb, errcb) {
		var cached = load(ORDER_CACHE_KEY, null);
		if (cached && Date.now() - cached.ts < ORDER_TTL_MS) {
			cb(cached.rank);
			return;
		}
		wikiGet({ action: "parse", page: "Quests/Progression_guide", prop: "wikitext" }, function (data) {
			if (!data.parse || !data.parse.wikitext) {
				errcb("Could not load the progression guide.");
				return;
			}
			var text = data.parse.wikitext["*"];
			var rank = {};
			var n = 0;
			var re = /data-rowid="([^"]+)"/g;
			var m;
			while ((m = re.exec(text)) !== null) {
				var key = normName(m[1]);
				if (!(key in rank)) rank[key] = n++;
			}
			if (!n) {
				errcb("The progression guide format changed — could not extract an order.");
				return;
			}
			store(ORDER_CACHE_KEY, { ts: Date.now(), rank: rank });
			cb(rank);
		}, errcb);
	}

	function pruneGuideCache(cache) {
		var keys = Object.keys(cache);
		if (keys.length <= GUIDE_CACHE_MAX) return;
		keys.sort(function (a, b) { return cache[a].ts - cache[b].ts; });
		while (keys.length > GUIDE_CACHE_MAX) delete cache[keys.shift()];
	}

	// ---------- wikitext parsing ----------
	// Quick guides are wikitext with ==Section== headings, {{Checklist|...}}
	// blocks of "*" bullets, {{Needed|...}} item lines, inline {{Chat
	// options|...}}, and the occasional wikitable. The parser is tolerant:
	// templates it does not understand are dropped, links become plain text.
	// Plain-ASCII sentinels mark chat options and item lines during parsing.

	var CHAT_OPEN = "@@C[";
	var CHAT_CLOSE = "]C@@";
	var MAP_OPEN = "@@M[";
	var MAP_CLOSE = "]M@@";
	var ITEM_OPEN = "@@I[";
	var ITEM_CLOSE = "]I@@";
	var IMG_OPEN = "@@P[";
	var IMG_CLOSE = "]P@@";
	var LINK_OPEN = "@@L[";
	var LINK_CLOSE = "]L@@";
	var NEEDED_MARK = "@@NEEDED@@";

	// Split template params on top-level pipes (ignoring pipes nested in
	// {{...}} or [[...]]).
	function splitParams(body) {
		var parts = [], depth = 0, cur = "";
		for (var i = 0; i < body.length; i++) {
			var two = body.substr(i, 2);
			if (two === "{{" || two === "[[") { depth++; cur += two; i++; }
			else if (two === "}}" || two === "]]") { depth--; cur += two; i++; }
			else if (body[i] === "|" && depth === 0) { parts.push(cur); cur = ""; }
			else cur += body[i];
		}
		parts.push(cur);
		return parts;
	}

	function unnamedParams(parts) {
		return parts.filter(function (p) {
			return !/^\s*[a-z0-9_ -]+\s*=/i.test(p);
		}).map(function (p) { return p.trim(); }).filter(Boolean);
	}

	function namedParam(parts, key) {
		for (var i = 0; i < parts.length; i++) {
			var m = /^\s*([a-z0-9_ -]+)\s*=([\s\S]*)$/i.exec(parts[i]);
			if (m && m[1].trim().toLowerCase() === key) return m[2].trim();
		}
		return null;
	}

	// Map templates carry "x, y" coords plus optional plane/mapID params.
	function mapSentinel(parts, args) {
		var coords = null;
		args.forEach(function (a) {
			var c = /^(\d{1,5})\s*,\s*(\d{1,5})$/.exec(a);
			if (c) coords = { x: +c[1], y: +c[2] };
		});
		if (!coords) return "";
		var plane = namedParam(parts, "plane") || "0";
		var mapId = namedParam(parts, "mapid") || "-1";
		return MAP_OPEN + coords.x + "," + coords.y + "," + plane + "," + mapId + MAP_CLOSE;
	}

	// Replace one innermost {{template}} at a time until none remain.
	function resolveTemplates(text) {
		for (var guard = 0; guard < 2000; guard++) {
			var m = /\{\{([^{}]*)\}\}/.exec(text);
			if (!m) break;
			var parts = splitParams(m[1]);
			var name = parts.shift().trim().toLowerCase().replace(/_/g, " ");
			var args = unnamedParams(parts);
			var out = "";
			if (name === "chat options" || name === "chat") {
				out = CHAT_OPEN + args.join(" / ") + CHAT_CLOSE;
			} else if (name === "needed" || name === "recommended") {
				var src = args.join(", ");
				out = NEEDED_MARK + (name === "recommended" ? "Recommended: " : "") + src;
				// Item links inside Needed lines are exact wiki page names —
				// keep them (with the required amount, when the guide gives
				// one) so the backpack scanner knows what to look for.
				var lm, lre = /\[\[([^\]|#]+)(?:#([^\]|]*))?(?:\|([^\]]*))?\]\]/g;
				while ((lm = lre.exec(src)) !== null) {
					var iname = lm[1].trim();
					var anchor = (lm[2] || "").trim();
					// Potion links use dose anchors ([[antipoison#(3)|...]]);
					// the dosed name is also the icon's file name.
					if (/^\(\d+\)$/.test(anchor)) iname += " " + anchor;
					var qty = 1;
					var before = /(\d+)\s*(?:x\s*)?$/i.exec(src.slice(Math.max(0, lm.index - 10), lm.index));
					var labelNum = /^(\d+)\s/.exec((lm[3] || "").trim());
					if (before) qty = +before[1];
					else if (labelNum) qty = +labelNum[1];
					out += ITEM_OPEN + iname + "|" + qty + ITEM_CLOSE;
				}
			} else if (name === "checklist") {
				out = "\n" + args.join("\n") + "\n";
			} else if (name === "members") {
				out = args[0] && /^no$/i.test(args[0]) ? "F2P" : "Members";
			} else if (name === "sic") {
				out = args[0] || "";
			} else if (name === "coins") {
				out = (args[0] || "") + " coins";
			} else if (name === "floornumber") {
				out = "floor " + (args[0] || "");
			} else if (name === "sq" || name === "!") {
				out = "|";
			} else if (name === "npc map" || name === "object map" || name === "map" || name === "maplink") {
				out = mapSentinel(parts, args);
			}
			// Anything else (maps, refs, nav templates, {{QG}} ...) is dropped.
			text = text.slice(0, m.index) + out + text.slice(m.index + m[0].length);
		}
		return text;
	}

	function cleanMarkup(text) {
		return text
			.replace(/<!--[\s\S]*?-->/g, "")
			.replace(/<ref[^>]*\/>/gi, "")
			.replace(/<ref[^>]*>[\s\S]*?<\/ref>/gi, "")
			.replace(/<br\s*\/?>/gi, " ")
			.replace(/<[^>]+>/g, "")
			.replace(/\[\[(?:File|Image):([^\[\]]*(?:\[\[[^\]]*\]\][^\[\]]*)*)\]\]/gi, function (_, inner) {
				// Keep guide images (puzzle solutions etc.) as sentinels; the
				// last non-formatting parameter is the caption.
				var parts = splitParams(inner);
				var name = parts.shift().trim();
				if (!/\.(png|jpe?g|gif|webp)$/i.test(name)) return "";
				var caption = "";
				parts.forEach(function (p) {
					p = p.trim();
					if (!p) return;
					if (/^(thumb|thumbnail|frame|frameless|border|right|left|center|none|baseline|sub|super|top|text-top|middle|bottom|text-bottom|upright[\s\S]*|x?\d+(x\d+)?px|link=[\s\S]*|alt=[\s\S]*|page=[\s\S]*|class=[\s\S]*|lang=[\s\S]*)$/i.test(p)) return;
					caption = p;
				});
				return IMG_OPEN + name + "|" + caption + IMG_CLOSE;
			})
			.replace(/\[\[Category:[^\]]*\]\]/gi, "")
			.replace(/\[\[([^\]|#\n]+)(?:#[^\]|\n]*)?\|([^\]\n]*)\]\]/g, function (_, page, label) {
				return LINK_OPEN + page.trim() + "|" + label + LINK_CLOSE;
			})
			.replace(/\[\[([^\]#|\n]+)(?:#[^\]\n]*)?\]\]/g, function (_, page) {
				var p = page.trim();
				return LINK_OPEN + p + "|" + p + LINK_CLOSE;
			})
			.replace(/\[\[([^\]]*)\]\]/g, "$1")
			.replace(/\[https?:\/\/[^\s\]]+ ([^\]]*)\]/g, "$1")
			.replace(/'''''|'''|''/g, "")
			.replace(/&nbsp;/g, " ")
			.replace(/[ \t]+/g, " ");
	}

	// Pull chat-option and map sentinels out of a line -> { text, chat, maps }.
	function extractChat(line) {
		var chat = [];
		var maps = [];
		var links = [];
		var text = line;
		var start;
		// Links first: replace each sentinel with its label so every other
		// extraction (chat, needed, notes) sees plain text; remember the
		// page for clickable names in steps.
		while ((start = text.indexOf(LINK_OPEN)) !== -1) {
			var lend = text.indexOf(LINK_CLOSE, start);
			if (lend === -1) { text = text.replace(LINK_OPEN, ""); continue; }
			var lbody = text.slice(start + LINK_OPEN.length, lend);
			var lsep = lbody.indexOf("|");
			var lpage = (lsep === -1 ? lbody : lbody.slice(0, lsep)).trim();
			var llabel = (lsep === -1 ? lbody : lbody.slice(lsep + 1)).trim();
			if (lpage && llabel) links.push({ page: lpage, label: llabel });
			text = text.slice(0, start) + llabel + text.slice(lend + LINK_CLOSE.length);
		}
		while ((start = text.indexOf(CHAT_OPEN)) !== -1) {
			var end = text.indexOf(CHAT_CLOSE, start);
			if (end === -1) { text = text.replace(CHAT_OPEN, ""); continue; }
			var inner = text.slice(start + CHAT_OPEN.length, end).trim();
			if (inner) chat.push(inner);
			text = text.slice(0, start) + text.slice(end + CHAT_CLOSE.length);
		}
		while ((start = text.indexOf(MAP_OPEN)) !== -1) {
			var mend = text.indexOf(MAP_CLOSE, start);
			if (mend === -1) { text = text.replace(MAP_OPEN, ""); continue; }
			var raw = text.slice(start + MAP_OPEN.length, mend).split(",");
			if (raw.length === 4) {
				maps.push({ x: +raw[0], y: +raw[1], plane: +raw[2], mapId: +raw[3] });
			}
			text = text.slice(0, start) + text.slice(mend + MAP_CLOSE.length);
		}
		var items = [];
		while ((start = text.indexOf(ITEM_OPEN)) !== -1) {
			var iend = text.indexOf(ITEM_CLOSE, start);
			if (iend === -1) { text = text.replace(ITEM_OPEN, ""); continue; }
			var ibody = text.slice(start + ITEM_OPEN.length, iend);
			var isep = ibody.lastIndexOf("|");
			var iname = (isep === -1 ? ibody : ibody.slice(0, isep)).trim();
			var iqty = isep === -1 ? 1 : Math.max(1, parseInt(ibody.slice(isep + 1), 10) || 1);
			if (iname) items.push({ name: iname, qty: iqty });
			text = text.slice(0, start) + text.slice(iend + ITEM_CLOSE.length);
		}
		var images = [];
		while ((start = text.indexOf(IMG_OPEN)) !== -1) {
			var pend = text.indexOf(IMG_CLOSE, start);
			if (pend === -1) { text = text.replace(IMG_OPEN, ""); continue; }
			var body = text.slice(start + IMG_OPEN.length, pend);
			var sep = body.indexOf("|");
			var file = (sep === -1 ? body : body.slice(0, sep)).trim();
			var caption = sep === -1 ? "" : body.slice(sep + 1).replace(/\s+/g, " ").trim();
			if (file) images.push({ file: file, caption: caption });
			text = text.slice(0, start) + text.slice(pend + IMG_CLOSE.length);
		}
		// Scrub any leftover sentinel fragments (e.g. from wiki markup that
		// splits a sentinel across lines) so they never reach the UI.
		text = text.replace(/@@[CMIPL]\[|\][CMIPL]@@|@@NEEDED@@/g, "");
		return {
			text: text.replace(/\s+/g, " ").trim(),
			chat: chat.join(" / ") || null,
			maps: maps,
			items: items,
			images: images,
			links: links
		};
	}

	// Parse a wikitable block (array of raw lines) into display rows.
	function parseTable(lines) {
		var rows = [], cells = [];
		function flush() {
			var texts = [], maps = [];
			cells.forEach(function (c) {
				var parsed = extractChat(cleanMarkup(resolveTemplates(c)));
				if (parsed.text) texts.push(parsed.text);
				maps = maps.concat(parsed.maps);
			});
			if (texts.length) rows.push({ text: texts.join(" — "), maps: maps });
			cells = [];
		}
		lines.forEach(function (line) {
			line = line.trim();
			if (/^\{\|/.test(line) || /^\|\}/.test(line) || /^\|\+/.test(line) || /^!/.test(line)) return;
			if (/^\|-/.test(line)) { flush(); return; }
			if (/^\|/.test(line)) {
				line.slice(1).split("||").forEach(function (c) { cells.push(c); });
			} else if (cells.length) {
				cells[cells.length - 1] += " " + line;
			}
		});
		flush();
		return rows;
	}

	function parseQuickGuide(wikitext) {
		var sections = [];
		var current = null;
		var lines = wikitext.split("\n");
		var i;

		// Pre-pass: pull out wikitable blocks so template resolution does not
		// mangle them; leave a placeholder line referencing the parsed rows.
		var tables = [];
		var kept = [];
		for (i = 0; i < lines.length; i++) {
			if (/^\s*\{\|/.test(lines[i])) {
				var tbl = [];
				while (i < lines.length && !/^\s*\|\}/.test(lines[i])) tbl.push(lines[i++]);
				if (i < lines.length) tbl.push(lines[i]);
				tables.push(parseTable(tbl));
				kept.push("%%TABLE:" + (tables.length - 1) + "%%");
			} else {
				kept.push(lines[i]);
			}
		}

		function newSection(title) {
			current = { title: title, needed: [], steps: [], images: [] };
			sections.push(current);
		}

		function lastStep() {
			return current && current.steps.length ? current.steps[current.steps.length - 1] : null;
		}

		// Templates like {{Checklist|...}} span multiple lines, so resolve
		// them over the whole document, then walk the resulting lines.
		var resolved = cleanMarkup(resolveTemplates(kept.join("\n")));

		resolved.split("\n").forEach(function (ln) {
			var trimmed = ln.trim();
			if (!trimmed) return;

			var h = /^==+\s*(.*?)\s*=+=$/.exec(trimmed);
			if (h) {
				var title = extractChat(h[1]).text;
				if (/^(overview|rewards?|required items|credits)$/i.test(title)) current = null;
				else newSection(title);
				return;
			}
			if (!current) return;

			var tm = /^%%TABLE:(\d+)%%$/.exec(trimmed);
			if (tm) {
				var rows = tables[+tm[1]];
				if (rows.length) {
					var host = lastStep();
					if (!host) {
						current.steps.push({ text: "Locations:", chat: null, sub: [] });
						host = lastStep();
					}
					host.sub = (host.sub || []).concat(rows.map(function (r) { return { text: r.text, maps: r.maps }; }));
				}
				return;
			}

			if (trimmed.indexOf(NEEDED_MARK) !== -1) {
				var neededLine = extractChat(trimmed.split(NEEDED_MARK).join(""));
				if (neededLine.text) current.needed.push(neededLine.text);
				if (neededLine.items.length) {
					current.items = (current.items || []).concat(neededLine.items);
				}
				if (neededLine.images.length) current.images = current.images.concat(neededLine.images);
				return;
			}

			var b = /^(\*+|#+)\s*(.*)$/.exec(trimmed);
			if (b) {
				var depth = b[1].length;
				var parsedLine = extractChat(b[2]);
				if (!parsedLine.text && !parsedLine.chat && !parsedLine.images.length) return;
				if (depth === 1 || !lastStep()) {
					current.steps.push({ text: parsedLine.text, chat: parsedLine.chat, maps: parsedLine.maps, images: parsedLine.images, links: parsedLine.links, sub: [] });
				} else {
					lastStep().sub.push({ text: parsedLine.text, chat: parsedLine.chat, maps: parsedLine.maps, links: parsedLine.links });
					if (parsedLine.images.length) {
						lastStep().images = (lastStep().images || []).concat(parsedLine.images);
					}
				}
				return;
			}

			// Loose prose inside a section: attach as a note to the last
			// step, or keep as a section-level info line. Images on their
			// own line (the common wiki pattern) belong to the section when
			// no steps exist yet, otherwise to the latest step.
			var prose = extractChat(trimmed);
			if (!prose.text && !prose.images.length) return;
			var stepHost = lastStep();
			if (stepHost) {
				if (prose.text) stepHost.note = (stepHost.note ? stepHost.note + " " : "") + prose.text;
				if (prose.maps.length) stepHost.maps = (stepHost.maps || []).concat(prose.maps);
				if (prose.images.length) stepHost.images = (stepHost.images || []).concat(prose.images);
			} else {
				if (prose.text) current.needed.push(prose.text);
				if (prose.images.length) current.images = current.images.concat(prose.images);
			}
		});

		// Drop sections that ended up with no steps and no info.
		sections = sections.filter(function (s) { return s.steps.length || s.needed.length || s.images.length; });
		return { sections: sections };
	}

	// Extract the {{Quest details}} items/recommended lists from a quest's
	// main page — these carry the "obtainable during the quest" style
	// annotations that quick guides leave out.
	function parseQuestDetails(wikitext) {
		var idx = wikitext.search(/\{\{Quest details/i);
		if (idx === -1) return { items: [], recommended: [] };
		var depth = 0, end = -1;
		for (var i = idx; i < wikitext.length - 1; i++) {
			var two = wikitext.substr(i, 2);
			if (two === "{{") { depth++; i++; }
			else if (two === "}}") { depth--; i++; if (!depth) { end = i + 1; break; } }
		}
		if (end === -1) return { items: [], recommended: [] };
		var parts = splitParams(wikitext.slice(idx + 2, end - 2));
		function listOf(key) {
			var v = namedParam(parts, key);
			if (!v || /^(none|no)\.?$/i.test(v.trim())) return [];
			return cleanMarkup(resolveTemplates(v)).split("\n").map(function (l) {
				return extractChat(l.replace(/^\s*[*#:]+\s*/, "")).text;
			}).filter(Boolean);
		}
		return { items: listOf("items"), recommended: listOf("recommended") };
	}

	function attachQuestDetails(cb) {
		if (guide.details) { cb(); return; }
		wikiGet({ action: "parse", page: guide.name, prop: "wikitext" }, function (data) {
			var wt = data.parse && data.parse.wikitext ? data.parse.wikitext["*"] : "";
			guide.details = parseQuestDetails(wt);
			var cache = load(GUIDE_CACHE_KEY, {});
			if (cache[guide.title]) {
				cache[guide.title].data = guide;
				store(GUIDE_CACHE_KEY, cache);
			}
			cb();
		}, function () {
			// Non-fatal: the panel just shows the quick-guide info alone.
			cb();
		});
	}

	// ---------- alt1 integration ----------

	function inAlt1() {
		return typeof window.alt1 !== "undefined";
	}

	// Alt1 colours are packed (a<<24 | r<<16 | g<<8 | b).
	function mixColor(r, g, b, a) {
		if (a === undefined) a = 255;
		return (b << 0) | (g << 8) | (r << 16) | (a << 24);
	}

	// Render the overlay as a proper card on a canvas: dark rounded panel
	// with wrapped step text, progress, chat options and a next-step hint.
	function renderOverlayCard(step, doneCount, total) {
		var W = 440, PAD = 12, LH = 20, MAXH = 400;
		var canvas = document.createElement("canvas");
		canvas.width = W;
		canvas.height = MAXH;
		var ctx = canvas.getContext("2d", { willReadFrequently: true });

		function wrap(text, font, maxLines) {
			ctx.font = font;
			var words = text.split(" ");
			var lines = [], cur = "";
			for (var i = 0; i < words.length; i++) {
				var probe = cur ? cur + " " + words[i] : words[i];
				if (ctx.measureText(probe).width > W - PAD * 2 && cur) {
					lines.push(cur);
					cur = words[i];
					if (lines.length === maxLines) {
						lines[maxLines - 1] = lines[maxLines - 1].replace(/\s*\S*$/, "") + "…";
						return lines;
					}
				} else {
					cur = probe;
				}
			}
			if (cur) lines.push(cur);
			return lines.slice(0, maxLines);
		}

		// Autosize: the step text wraps fully instead of being cut off.
		var stepLines = step ? wrap(step.text, "600 15px 'Segoe UI', sans-serif", 8) : ["Quest complete! 🎉"];
		var chatLines = step && step.chat ? wrap("Chat: " + step.chat, "13px 'Segoe UI', sans-serif", 3) : [];
		// Items needed for the current section, if the guide lists any.
		var neededLines = [];
		if (step && guide.sections && guide.sections[step.sectionIndex] && guide.sections[step.sectionIndex].needed.length) {
			neededLines = wrap("Items: " + guide.sections[step.sectionIndex].needed.join("; "),
				"12px 'Segoe UI', sans-serif", 2);
		}

		var H = Math.min(MAXH,
			PAD + 16 + 6 + stepLines.length * LH + chatLines.length * 18 + neededLines.length * 17 + PAD);

		// Panel
		ctx.clearRect(0, 0, W, 220);
		ctx.beginPath();
		var r = 8;
		ctx.moveTo(r, 0); ctx.lineTo(W - r, 0); ctx.arcTo(W, 0, W, r, r);
		ctx.lineTo(W, H - r); ctx.arcTo(W, H, W - r, H, r);
		ctx.lineTo(r, H); ctx.arcTo(0, H, 0, H - r, r);
		ctx.lineTo(0, r); ctx.arcTo(0, 0, r, 0, r);
		ctx.fillStyle = "rgba(18, 22, 18, 0.86)";
		ctx.fill();
		ctx.strokeStyle = "rgba(231, 193, 90, 0.9)";
		ctx.lineWidth = 1.5;
		ctx.stroke();

		// Header: quest name + progress
		var y = PAD + 11;
		ctx.font = "700 11px 'Segoe UI', sans-serif";
		ctx.fillStyle = "#e7c15a";
		var header = (guide.name || "").toUpperCase();
		ctx.fillText(header, PAD, y, W - PAD * 2 - 60);
		ctx.textAlign = "right";
		ctx.fillText(doneCount + " / " + total, W - PAD, y);
		ctx.textAlign = "left";
		y += 6;

		// Step text
		ctx.font = "600 15px 'Segoe UI', sans-serif";
		ctx.fillStyle = "#f2ecd8";
		stepLines.forEach(function (l) { y += LH; ctx.fillText(l, PAD, y); });

		// Chat options
		ctx.font = "13px 'Segoe UI', sans-serif";
		ctx.fillStyle = "#7fb8f0";
		chatLines.forEach(function (l) { y += 18; ctx.fillText(l, PAD, y); });

		// Items needed for this section
		ctx.font = "12px 'Segoe UI', sans-serif";
		ctx.fillStyle = "#9fd47f";
		neededLines.forEach(function (l) { y += 17; ctx.fillText(l, PAD, y); });

		return ctx.getImageData(0, 0, W, H);
	}

	function overlayCardPos(w, h) {
		var margin = 18;
		switch (prefs.overlayPos || "tc") {
			case "tl": return { x: margin, y: margin };
			case "tr": return { x: Math.max(0, alt1.rsWidth - w - margin), y: margin };
			case "bc": return { x: Math.max(0, Math.round((alt1.rsWidth - w) / 2)), y: Math.max(0, alt1.rsHeight - h - 130) };
			case "free": return {
				x: Math.round((prefs.overlayFreeX === undefined ? 0.5 : prefs.overlayFreeX) * Math.max(0, alt1.rsWidth - w)),
				y: Math.round((prefs.overlayFreeY === undefined ? 0.05 : prefs.overlayFreeY) * Math.max(0, alt1.rsHeight - h))
			};
			default: return { x: Math.max(0, Math.round((alt1.rsWidth - w) / 2)), y: margin };
		}
	}

	function paintOverlay() {
		if (!inAlt1() || !alt1.permissionOverlay || !guide) return;
		// Game closed or unlinked: clean up rather than paint into nowhere.
		if (alt1.rsLinked === false) { clearOverlay(); return; }
		var step = currentStep();
		var doneCount = 0;
		flatSteps.forEach(function (s) { if (isDone(s)) doneCount++; });
		try {
			var card = renderOverlayCard(step, doneCount, flatSteps.length);
			var pos = overlayCardPos(card.width, card.height);
			alt1.overLaySetGroup("rs3qh");
			alt1.overLayClearGroup("rs3qh");
			alt1.overLayImage(pos.x, pos.y, A1lib.encodeImageString(card), card.width, OVERLAY_REFRESH_MS + 2000);
			alt1.overLayRefreshGroup("rs3qh");
		} catch (e) {
			// Fall back to plain text if image overlays are unavailable.
			var text = step ? "Quest: " + step.text : "Quest complete!";
			if (step && step.chat) text += "  [Chat: " + step.chat + "]";
			if (text.length > 120) text = text.slice(0, 117) + "...";
			try {
				alt1.overLaySetGroup("rs3qh");
				alt1.overLayClearGroup("rs3qh");
				alt1.overLayTextEx(text, mixColor(231, 193, 90), 16,
					Math.round(alt1.rsWidth / 2), 40, OVERLAY_REFRESH_MS + 2000, "", true, true);
				alt1.overLayRefreshGroup("rs3qh");
			} catch (e2) { /* overlay unavailable */ }
		}
	}

	function clearOverlay() {
		if (!inAlt1() || !alt1.permissionOverlay) return;
		try {
			alt1.overLaySetGroup("rs3qh");
			alt1.overLayClearGroup("rs3qh");
			alt1.overLayRefreshGroup("rs3qh");
		} catch (e) { /* ignore */ }
	}

	function setOverlay(on) {
		var btn = document.getElementById("btn-overlay");
		if (overlayTimer) { clearInterval(overlayTimer); overlayTimer = null; }
		if (on) {
			paintOverlay();
			overlayTimer = setInterval(paintOverlay, OVERLAY_REFRESH_MS);
			btn.textContent = "Overlay: on";
			btn.classList.add("active");
		} else {
			clearOverlay();
			btn.textContent = "Overlay: off";
			btn.classList.remove("active");
		}
	}

	// ---------- assist: dialogue highlighting + chat watching ----------
	// Inspired by bolt-questhelper's conversation highlighting, rebuilt on
	// Alt1's pixel API: capture the screen, OCR the open dialogue via the
	// alt1 DialogReader, and draw an overlay box around the option matching
	// the current step's chat options. The chatbox is watched for quest
	// completion messages.

	// Fast ticks keep the highlight responsive (it expires ~600ms after the
	// dialogue changes); conversation tracking still samples at the original
	// 700ms cadence via CONVO_EVERY so its tick-count thresholds keep the
	// same wall-clock meaning.
	var ASSIST_INTERVAL_MS = 350;
	var CONVO_EVERY = 2;
	var CHAT_EVERY = 4;
	var AUTO_KEY = "rs3qh-auto-v1";
	var assistTimer = null;
	var assistTickN = 0;
	var dialogReader = null;
	var chatReader = null;
	var chatFound = false;
	var autoAdvance = load(AUTO_KEY, false);

	// Conversation tracker for auto-ticking dialogue steps. A conversation
	// "ends" when a dialogue was on screen for >=2 ticks and then gone for
	// >=3 ticks (~2s). Crucially, ending alone is NOT enough to tick: one
	// of the step's expected chat options must have been seen matched
	// during the conversation (the evidence) — otherwise unrelated
	// dialogues (cutscenes, eavesdropping, other NPCs) would tick steps
	// whose dialogue never happened.
	//
	// Steps like "1 Convince / 2 Persuade / 3 Threaten" list several
	// options on the SAME screen that must each be tried in separate
	// conversations — when several candidates match one screen at once,
	// that many evidenced conversations are required before the step
	// ticks.
	var convo = { key: null, seen: 0, gone: 0, evidence: null, required: 1, completions: 0 };

	// Returns null (nothing to do), { none: true } (a conversation ended
	// but its options never matched — do not tick), { partial, required }
	// (one of several required conversations done), or the evidence
	// target { key, subIndex } to tick.
	function convoObserve(key, dialogVisible, matchedTarget, candCount) {
		if (convo.key !== key) {
			convo.key = key;
			convo.seen = 0;
			convo.gone = 0;
			convo.evidence = null;
			convo.required = 1;
			convo.completions = 0;
		}
		if (dialogVisible) {
			convo.seen++;
			convo.gone = 0;
			if (matchedTarget) {
				convo.evidence = matchedTarget;
				if (candCount && (matchedTarget.subIndex === null || matchedTarget.subIndex === undefined) &&
					candCount > convo.required) {
					convo.required = candCount;
				}
			}
			return null;
		}
		if (convo.seen >= 2) {
			convo.gone++;
			if (convo.gone >= 3) {
				convo.seen = 0;
				convo.gone = 0;
				var ev = convo.evidence;
				convo.evidence = null;
				if (!ev || ev.key !== key) return { none: true };
				// Sub-steps are granular already — tick directly.
				if (ev.subIndex !== null && ev.subIndex !== undefined) return ev;
				convo.completions++;
				if (convo.completions >= convo.required) return ev;
				return { partial: convo.completions, required: convo.required };
			}
		}
		return null;
	}

	// How many distinct chat candidates of this step match the current
	// options screen (multiple at once = "try each of these").
	function countMatchedCandidates(chatField, opts) {
		var n = 0;
		chatField.split(" / ").forEach(function (cand) {
			cand = cand.trim();
			if (/^any$/i.test(cand)) return;
			var numMatch = /^(\d)[.)]?\s*(.*)$/.exec(cand);
			var num = numMatch ? +numMatch[1] : null;
			var textPart = normOpt(numMatch ? numMatch[2] : cand);
			var matched = false;
			if (textPart.length >= 3) {
				opts.forEach(function (o) {
					if (optTextMatches(textPart, normOpt(o.text || ""))) matched = true;
				});
			} else if (num !== null && num >= 1 && num <= opts.length) {
				matched = true;
			}
			if (matched) n++;
		});
		return n;
	}

	function assistAvailable() {
		return inAlt1() && alt1.permissionPixel && alt1.permissionOverlay &&
			typeof A1lib !== "undefined" && typeof Dialog !== "undefined";
	}

	// Normalise option text for comparison: lowercase, no punctuation.
	function normOpt(s) {
		return s.toLowerCase().replace(/[^a-z0-9 ]+/g, " ").replace(/\s+/g, " ").trim();
	}

	// Fuzzy option-text comparison: substring either way, or most of the
	// candidate's meaningful words appear in the option (OCR drops chars).
	function optTextMatches(cand, optText) {
		if (!cand || !optText) return false;
		if (optText.indexOf(cand) !== -1 || cand.indexOf(optText) !== -1) return true;
		var ctoks = cand.split(" ").filter(function (t) { return t.length > 2; });
		if (ctoks.length < 2) return false;
		var otoks = optText.split(" ");
		var hit = 0;
		ctoks.forEach(function (t) { if (otoks.indexOf(t) !== -1) hit++; });
		return hit / ctoks.length >= 0.6;
	}

	// The step's chat field looks like "1 Talk about the quest. / Any" —
	// candidates separated by " / ", each either "Any", a bare option
	// number, or a number plus the option text. Candidates usually belong
	// to DIFFERENT screens of a conversation chain, so a text candidate
	// that does not match this screen must stay silent — falling back to
	// its number would box the wrong option (numbers only count when the
	// guide gives a number alone).
	function matchOptions(chatField, opts) {
		var picked = [];
		var hasAny = false;
		function add(o) { if (picked.indexOf(o) === -1) picked.push(o); }

		chatField.split(" / ").forEach(function (cand) {
			cand = cand.trim();
			if (/^any$/i.test(cand)) {
				hasAny = true;
				return;
			}
			var numMatch = /^(\d)[.)]?\s*(.*)$/.exec(cand);
			var num = numMatch ? +numMatch[1] : null;
			var textPart = normOpt(numMatch ? numMatch[2] : cand);

			if (textPart.length >= 3) {
				opts.forEach(function (o) {
					if (optTextMatches(textPart, normOpt(o.text || ""))) add(o);
				});
			} else if (num !== null && num >= 1 && num <= opts.length) {
				add(opts[num - 1]);
			}
		});
		// "Any" only means "every option works" when no specific candidate
		// matched this screen (guides chain "1 Talk about X / Any").
		if (!picked.length && hasAny) picked = opts.slice();
		return picked;
	}

	// Alt1's readers only match the interface pixel-for-pixel at 100% scale.
	// The chatbox is always on screen, so when it has never been recognised
	// and no dialogue has either, the interface is almost certainly scaled —
	// say so instead of failing silently. Pure so it can be tested.
	function scaleHintText(chatMisses, anyChatFound, anyDialogFound) {
		if (anyChatFound || anyDialogFound || chatMisses < 8) return "";
		return " ⚠ Nothing on screen is being recognised — if your in-game interface " +
			"scale isn't 100% (graphics settings), Alt1 apps can't read the interface. " +
			"The guide and overlay still work at any scale.";
	}

	var chatScanMisses = 0;
	var dialogEverFound = false;

	function setAssistStatus(msg) {
		var node = document.getElementById("assist-status");
		if (msg) msg += scaleHintText(chatScanMisses, chatFound, dialogEverFound);
		node.textContent = msg || "";
		node.classList.toggle("hidden", !msg);
	}

	function clearAssistOverlay() {
		if (!inAlt1() || !alt1.permissionOverlay) return;
		try {
			alt1.overLaySetGroup("rs3qh-assist");
			alt1.overLayClearGroup("rs3qh-assist");
			alt1.overLayRefreshGroup("rs3qh-assist");
		} catch (e) { /* ignore */ }
	}

	// Alt1 image overlays cannot blend with the game (semi-transparent
	// pixels composite against black and cover whatever is underneath), so
	// the highlight is built from outline primitives that leave the option
	// text untouched: a "neon" border — dim outer ring, bright core, dim
	// inner ring — plus a chevron pointing at the choice. Pure geometry so
	// it can be tested headless; drawOptionBoxes renders it.
	var HL_BRIGHT = mixColor(141, 255, 90);
	var HL_DIM = mixColor(52, 110, 34);

	// Find the dark option button inside a crop centred on the OCR'd text
	// row, so the highlight hugs the real button instead of guessing its
	// size from text length. RS3 buttons are near-black bars on parchment;
	// their light glyphs only poke small holes in the darkness. Returns
	// {x, y, w, h} relative to the crop, or null when nothing button-like
	// is there (legacy skin draws plain text — the caller falls back).
	function measureOptionButton(crop) {
		var w = crop.width, h = crop.height, d = crop.data;
		function dark(px, py) {
			var i = (py * w + px) * 4;
			return d[i] + d[i + 1] + d[i + 2] < 250;
		}
		var mid = Math.floor(h / 2);
		var probes = [mid - 4, mid, mid + 4];
		function anyDark(px) {
			for (var r = 0; r < probes.length; r++) if (dark(px, probes[r])) return true;
			return false;
		}
		// Horizontal extent: a >=3px dark run from either side marks the
		// button caps (single dark specks on parchment don't count).
		var left = -1, right = -1, run = 0, px;
		for (px = 0; px < w; px++) {
			run = anyDark(px) ? run + 1 : 0;
			if (run >= 3) { left = px - 2; break; }
		}
		run = 0;
		for (px = w - 1; px >= 0; px--) {
			run = anyDark(px) ? run + 1 : 0;
			if (run >= 3) { right = px + 2; break; }
		}
		if (left < 0 || right - left < 60) return null;
		// Vertical extent: grow from the middle row while rows stay mostly
		// dark, so a neighbouring option at the crop's edge is never
		// swallowed (the parchment gap between buttons stops the growth).
		function rowDark(py) {
			var cnt = 0, tot = 0;
			for (var qx = left; qx <= right; qx += 4) { tot++; if (dark(qx, py)) cnt++; }
			return cnt / tot > 0.45;
		}
		if (!rowDark(mid)) return null;
		var top = mid, bottom = mid;
		while (top > 0 && rowDark(top - 1)) top--;
		while (bottom < h - 1 && rowDark(bottom + 1)) bottom++;
		if (bottom - top < 8) return null;
		return { x: left, y: top, w: right - left + 1, h: bottom - top + 1 };
	}
	function highlightShapes(x, y, w, h) {
		var cy = Math.round(y + h / 2);
		return [
			{ kind: "rect", color: HL_DIM, x: x - 3, y: y - 3, w: w + 6, h: h + 6, lw: 1 },
			{ kind: "rect", color: HL_BRIGHT, x: x - 1, y: y - 1, w: w + 2, h: h + 2, lw: 2 },
			{ kind: "rect", color: HL_DIM, x: x + 1, y: y + 1, w: w - 2, h: h - 2, lw: 1 },
			{ kind: "line", color: HL_BRIGHT, lw: 3, x1: x + 8, y1: cy - 5, x2: x + 14, y2: cy },
			{ kind: "line", color: HL_BRIGHT, lw: 3, x1: x + 14, y1: cy, x2: x + 8, y2: cy + 5 }
		];
	}

	function drawOptionBoxes(matches, dialogPos, img) {
		try {
			alt1.overLaySetGroup("rs3qh-assist");
			alt1.overLayFreezeGroup("rs3qh-assist");
			alt1.overLayClearGroup("rs3qh-assist");
			// Short-lived boxes: if the dialogue changes and the next tick
			// doesn't reconfirm them, they expire on their own instead of
			// lingering over whatever replaced the options.
			var ttl = ASSIST_INTERVAL_MS + 250;
			matches.forEach(function (o) {
				// Best case: measure the actual button from the capture so
				// the highlight hugs it exactly.
				var box = null;
				if (img && dialogPos && dialogPos.width) {
					try {
						var cx0 = dialogPos.x + 6, cy0 = o.y - 14;
						var mb = measureOptionButton(img.toData(cx0, cy0, dialogPos.width - 12, 28));
						if (mb) box = { x: cx0 + mb.x, y: cy0 + mb.y, w: mb.w, h: mb.h };
					} catch (e3) { /* capture crop failed — fall through */ }
				}
				if (!box) {
					// Fallback: size the box from the OCR'd text length
					// (~8px/char mono font) plus room for the number and
					// arrows. RS3 centres option buttons in the dialogue;
					// legacy mode left-aligns them.
					var textw = ((o.text || "").length * 8) + 120;
					var x, w;
					if (dialogPos && dialogPos.width && !dialogPos.legacy) {
						w = Math.min(Math.max(textw, 170), dialogPos.width - 16);
						x = dialogPos.x + Math.round((dialogPos.width - w) / 2);
					} else if (dialogPos && dialogPos.width) {
						w = Math.min(Math.max(textw, 170), dialogPos.width - 16);
						x = Math.max(o.x - 50, dialogPos.x + 8);
					} else {
						x = (o.buttonx || o.x - 4) - 2;
						w = Math.max(textw, 260);
					}
					box = { x: x, y: o.y - 10, w: w, h: 26 };
				}
				highlightShapes(box.x, box.y, box.w, box.h).forEach(function (s) {
					if (s.kind === "rect") {
						alt1.overLayRect(s.color, s.x, s.y, s.w, s.h, ttl, s.lw);
					} else if (typeof alt1.overLayLine === "function") {
						alt1.overLayLine(s.color, s.lw, s.x1, s.y1, s.x2, s.y2, ttl);
					}
				});
			});
			alt1.overLayRefreshGroup("rs3qh-assist");
		} catch (e) { /* overlay unavailable */ }
	}

	function markQuestComplete() {
		if (!guide) return;
		var changed = false;
		flatSteps.forEach(function (s) {
			if (!isDone(s)) { questProgress().done[stepKey(s)] = true; changed = true; }
		});
		if (changed) {
			store(PROGRESS_KEY, progress);
			renderSteps();
			if (overlayTimer) paintOverlay();
			setAssistStatus("Quest completion detected in chat — all steps marked done.");
		}
	}

	function assistTick() {
		if (!guide) { setAssistStatus(""); return; }
		if (alt1.rsLinked === false) { clearAssistOverlay(); return; }
		assistTickN++;
		var img;
		try {
			img = A1lib.captureHoldFullRs();
		} catch (e) {
			setAssistStatus("Assist: could not capture the game screen.");
			return;
		}

		// Watch the chatbox for quest completion (heavier OCR — every 4th tick).
		try {
			if (chatReader && assistTickN % CHAT_EVERY === 0) {
				if (!chatFound) {
					var boxes = chatReader.find(img);
					chatFound = !!(boxes && boxes.length);
					if (!chatFound) chatScanMisses++;
				}
				if (chatFound) {
					var lines = chatReader.read(img) || [];
					for (var i = 0; i < lines.length; i++) {
						if (/congratulations.*(complete|finish)|quest complete/i.test(lines[i].text)) {
							markQuestComplete();
						}
					}
				}
			}
		} catch (e) { /* chat reading is best-effort */ }

		// Highlight dialogue options for the current step and its unchecked
		// sub-steps; auto-tick whichever one the finished conversation was for.
		var step = currentStep();
		var targets = [];
		if (step) {
			if (step.chat) targets.push({ chat: step.chat, subIndex: null, label: step.text });
			(step.subs || []).forEach(function (sub, k) {
				if (sub.chat && !isSubDone(step, k)) {
					targets.push({ chat: sub.chat, subIndex: k, label: sub.text });
				}
			});
		}
		if (!step || !targets.length) {
			clearAssistOverlay();
			setAssistStatus("Assist: on — current step has no dialogue options" + (chatFound ? "; watching chat." : "."));
			return;
		}
		try {
			var pos = dialogReader.find(img);
			if (pos) dialogEverFound = true;

			// Read the dialogue and match options against the step targets
			// FIRST — the result doubles as auto-tick evidence.
			var dlg = null;
			var allMatches = [];
			var matchedTarget = null;
			if (pos) {
				dlg = dialogReader.read(img);
				if (dlg && dlg.opts && dlg.opts.length) {
					targets.forEach(function (t) {
						var m = matchOptions(t.chat, dlg.opts);
						if (m.length && !matchedTarget) matchedTarget = t;
						m.forEach(function (o) {
							if (allMatches.indexOf(o) === -1) allMatches.push(o);
						});
					});
				}
			}

			// Auto-tick only with evidence: the conversation that just
			// ended must have shown one of this step's expected options.
			// Sampled every 2nd tick so convoObserve's seen/gone tick
			// thresholds keep their original 700ms-cadence timing.
			if (autoAdvance && assistTickN % CONVO_EVERY === 0) {
				var candCount = 0;
				if (matchedTarget && matchedTarget.subIndex === null && dlg && dlg.opts) {
					candCount = countMatchedCandidates(matchedTarget.chat, dlg.opts);
				}
				var res = convoObserve(stepKey(step), !!pos,
					matchedTarget ? { key: stepKey(step), subIndex: matchedTarget.subIndex } : null, candCount);
				if (res) {
					clearAssistOverlay();
					if (res.none) {
						setAssistStatus("Assist: a conversation ended, but this step's options never appeared — not ticked (tick manually if it was the right one).");
					} else if (res.partial) {
						setAssistStatus("Assist: conversation done — " + res.partial + "/" + res.required +
							" of this step's dialogue options completed. Talk again for the next one.");
					} else if (res.subIndex !== null && res.subIndex !== undefined) {
						setSubDone(step, res.subIndex, true);
						setAssistStatus("Assist: conversation finished — sub-step ticked automatically.");
						return;
					} else {
						setDone(step, true);
						setAssistStatus("Assist: conversation finished — step ticked automatically.");
						return;
					}
				}
			}

			if (!pos) {
				clearAssistOverlay();
				if (!autoAdvance || !convo.gone) {
					setAssistStatus("Assist: on — waiting for a dialogue box. Target: " +
						targets.map(function (t) { return t.chat; }).join(" | "));
				}
				return;
			}
			if (!dlg || !dlg.opts || !dlg.opts.length) {
				clearAssistOverlay();
				setAssistStatus("Assist: dialogue open, no options readable yet.");
				return;
			}
			if (allMatches.length) {
				drawOptionBoxes(allMatches, pos, img);
				setAssistStatus("Assist: highlighted \"" +
					(allMatches[0].text || ("option " + (dlg.opts.indexOf(allMatches[0]) + 1))) + "\"" +
					(matchedTarget.subIndex !== null ? " (sub-step)" : ""));
			} else {
				clearAssistOverlay();
				setAssistStatus("Assist: no option matched — read: " +
					dlg.opts.map(function (o) { return o.text; }).join(" | "));
			}
		} catch (e) {
			clearAssistOverlay();
			setAssistStatus("Assist: dialogue read failed (" + (e && e.message ? e.message : "error") + ")");
		}
	}

	function setAssist(on) {
		var btn = document.getElementById("btn-assist");
		if (assistTimer) { clearInterval(assistTimer); assistTimer = null; }
		if (on) {
			if (!dialogReader) dialogReader = new Dialog.default();
			if (!chatReader && typeof Chatbox !== "undefined") chatReader = new Chatbox.default();
			chatFound = false;
			chatScanMisses = 0;
			dialogEverFound = false;
			convo.key = null;
			convo.evidence = null;
			assistTickN = 0;
			assistTimer = setInterval(assistTick, ASSIST_INTERVAL_MS);
			assistTick();
			btn.textContent = "Assist: on";
			btn.classList.add("active");
		} else {
			clearAssistOverlay();
			setAssistStatus("");
			btn.textContent = "Assist: off";
			btn.classList.remove("active");
		}
	}

	// ---------- item info popup (what is it, how to make, where to buy) ----------

	var itemInfoCache = {};

	// Pull the materials/skill out of an {{Infobox Recipe}} block.
	function parseRecipe(wt) {
		var idx = wt.search(/\{\{Infobox Recipe/i);
		if (idx === -1) return null;
		var depth = 0, end = -1;
		for (var i = idx; i < wt.length - 1; i++) {
			var two = wt.substr(i, 2);
			if (two === "{{") { depth++; i++; }
			else if (two === "}}") { depth--; i++; if (!depth) { end = i + 1; break; } }
		}
		if (end === -1) return null;
		var parts = splitParams(wt.slice(idx + 2, end - 2));
		function clean(v) { return v ? extractChat(cleanMarkup(resolveTemplates(v))).text : ""; }
		var mats = [];
		for (var m = 1; m <= 12; m++) {
			var mat = namedParam(parts, "mat" + m);
			if (!mat) break;
			var q = namedParam(parts, "mat" + m + "quantity") || namedParam(parts, "mat" + m + "qty") || "1";
			mats.push(clean(q) + "× " + clean(mat));
		}
		if (!mats.length) return null;
		var skill = clean(namedParam(parts, "skill1") || namedParam(parts, "skill") || "");
		var lvl = clean(namedParam(parts, "skill1lvl") || namedParam(parts, "level") || "");
		return { mats: mats, skill: skill, level: lvl };
	}

	// Turn a rendered shop-locations section into rows of
	// { text: "Seller — Location — price", page: "Shop article title" }.
	function parseShopRows(html) {
		var rows = [];
		try {
			var doc = new DOMParser().parseFromString(html, "text/html");
			var table = doc.querySelector("table");
			if (!table) return rows;
			var trs = table.querySelectorAll("tr");
			for (var i = 1; i < trs.length && rows.length < 5; i++) {
				var cells = trs[i].querySelectorAll("td");
				if (!cells.length) continue;
				var texts = [];
				for (var c = 0; c < Math.min(cells.length, 2); c++) {
					var t = cells[c].textContent.replace(/\s+/g, " ").trim();
					if (t) texts.push(t);
				}
				// Sell price column (position 3) when the table has one.
				if (cells.length > 3) {
					var price = cells[3].textContent.replace(/\s+/g, " ").trim();
					if (price) texts.push(price);
				}
				if (!texts.length) continue;
				var row = { text: texts.join(" — "), page: null };
				var a = cells[0].querySelector("a[title]");
				if (a) row.page = a.getAttribute("title");
				if (cells.length > 5 && /member/i.test(cells[5].textContent)) row.text += " (members)";
				// Location-implied unlocks (buildable camps, gated cities).
				if (cells.length > 1) row.lock = locationLockNote(cells[1].textContent);
				rows.push(row);
			}
		} catch (e) { /* tolerate table changes */ }
		return rows;
	}

	// First sentence of a shop's intro that hints at an unlock requirement.
	function questLockNote(extract) {
		if (!extract) return null;
		var sentences = extract.split(". ");
		for (var i = 0; i < sentences.length; i++) {
			if (/quest|requir|unlock|only (be )?(accessed|used|entered)|after (complet|start|build)|must (have|be)|(be )?built|constructed/i.test(sentences[i])) {
				var s = sentences[i].trim();
				if (s && !/\.$/.test(s)) s += ".";
				return s.length > 160 ? s.slice(0, 157) + "…" : s;
			}
		}
		return null;
	}

	// Some shop locations imply an unlock by themselves (buildable camps,
	// quest-gated cities) even when the shop's own page never says so.
	var GATED_LOCATIONS = [
		[/anachronia|base camp/i, "Anachronia base camp — the shop's building must be constructed at your camp first."],
		[/fort forinthry/i, "Fort Forinthry — the relevant building must be constructed (New Foundations)."],
		[/prifddinas/i, "Prifddinas — requires completing Plague's End."],
		[/zanaris/i, "Zanaris — requires Lost City."],
		[/sophanem/i, "Sophanem — requires starting Icthlarin's Little Helper."],
		[/menaphos/i, "Menaphos — requires The Jack of Spades."],
		[/keldagrim/i, "Keldagrim — requires starting The Giant Dwarf."],
		[/dorgesh-kaan/i, "Dorgesh-Kaan — requires Death to the Dorgeshuun."],
		[/lletya/i, "Lletya — requires starting Mourning's End Part I."],
		[/miscellania|etceteria/i, "Miscellania — requires The Fremennik Trials."],
		[/mos le'harmless/i, "Mos Le'Harmless — requires Cabin Fever."],
		[/ape atoll|marim/i, "Ape Atoll — requires Monkey Madness."],
		[/oo'glog/i, "Oo'glog — requires As a First Resort."],
		[/city of um/i, "City of Um — requires the Necromancy! questline."]
	];

	function locationLockNote(location) {
		if (!location) return null;
		for (var i = 0; i < GATED_LOCATIONS.length; i++) {
			if (GATED_LOCATIONS[i][0].test(location)) return GATED_LOCATIONS[i][1];
		}
		return null;
	}

	function renderItemInfo(name, info) {
		var body = document.getElementById("item-popup-body");
		body.innerHTML = "";
		if (info.intro) body.appendChild(el("p", null, info.intro));
		if (info.recipe) {
			body.appendChild(el("div", "req-head", "How to make"));
			body.appendChild(el("p", null, info.recipe.mats.join(", ") +
				(info.recipe.skill ? " (" + info.recipe.skill + (info.recipe.level ? " level " + info.recipe.level : "") + ")" : "")));
		}
		if (info.shops && info.shops.length) {
			body.appendChild(el("div", "req-head", "Sold by"));
			var ul = el("ul", null);
			info.shops.forEach(function (s) {
				var li = el("li", null, s.text);
				if (s.lock) li.appendChild(el("div", "shop-lock", "⚠ " + s.lock));
				ul.appendChild(li);
			});
			body.appendChild(ul);
		}
		if (!info.intro && !info.recipe && (!info.shops || !info.shops.length)) {
			body.appendChild(el("p", null, "No summary available — use the full wiki page link above."));
		}
	}

	function showItemInfo(name) {
		var popup = document.getElementById("item-popup");
		document.getElementById("item-popup-title").textContent = name;
		document.getElementById("item-popup-link").href =
			"https://runescape.wiki/w/" + encodeURIComponent(name.replace(/ /g, "_"));
		document.getElementById("item-popup-body").textContent = "Loading from the wiki…";
		popup.classList.remove("hidden");
		if (itemInfoCache[name]) { renderItemInfo(name, itemInfoCache[name]); return; }

		var info = { intro: "", recipe: null, shops: [] };
		function finish() {
			itemInfoCache[name] = info;
			// Only render if this item is still the one being shown.
			if (document.getElementById("item-popup-title").textContent === name) {
				renderItemInfo(name, info);
			}
		}
		wikiGet({ action: "query", prop: "extracts", exintro: "1", explaintext: "1", redirects: "1", titles: name }, function (d) {
			try {
				var pages = d.query.pages;
				var ext = pages[Object.keys(pages)[0]].extract || "";
				info.intro = ext.split("\n")[0];
			} catch (e) { /* no extract */ }
			wikiGet({ action: "parse", page: name, prop: "sections", redirects: "1" }, function (sd) {
				var secs = (sd.parse && sd.parse.sections) || [];
				var creation = null, shop = null;
				secs.forEach(function (s) {
					if (!creation && /creation|making/i.test(s.line)) creation = s;
					if (!shop && /shop|store/i.test(s.line)) shop = s;
				});
				var pending = 1;
				function done() { if (--pending === 0) finish(); }
				if (creation) {
					pending++;
					wikiGet({ action: "parse", page: name, prop: "wikitext", section: creation.index, redirects: "1" }, function (cd) {
						try { info.recipe = parseRecipe(cd.parse.wikitext["*"]); } catch (e) { /* none */ }
						done();
					}, done);
				}
				if (shop) {
					pending++;
					wikiGet({ action: "parse", page: name, prop: "text", section: shop.index, redirects: "1" }, function (td) {
						try { info.shops = parseShopRows(td.parse.text["*"]); } catch (e) { /* none */ }
						// Shops can be quest-locked; their own pages say so.
						var titles = [];
						info.shops.forEach(function (s) {
							if (s.page && titles.indexOf(s.page) === -1) titles.push(s.page);
						});
						if (!titles.length) { done(); return; }
						wikiGet({
							action: "query", prop: "extracts", exintro: "1", explaintext: "1",
							redirects: "1", titles: titles.slice(0, 15).join("|")
						}, function (ed) {
							try {
								var pages = ed.query.pages;
								var byTitle = {};
								Object.keys(pages).forEach(function (k) {
									byTitle[pages[k].title] = pages[k].extract || "";
								});
								info.shops.forEach(function (s) {
									if (s.page && byTitle[s.page] !== undefined) {
										// A note from the shop's own page wins, but
										// never erase a location-implied one.
										s.lock = questLockNote(byTitle[s.page]) || s.lock;
									}
								});
							} catch (e) { /* extracts unavailable */ }
							done();
						}, done);
					}, done);
				}
				done();
			}, finish);
		}, finish);
	}

	// ---------- backpack item scanning ----------
	// Looks for the wiki inventory icon of each required item in the game
	// screen (transparent icon pixels act as wildcards). Presence-only: it
	// cannot count quantities, and the backpack must be open and visible.

	var iconCache = {}; // item name -> ImageData | null (failed to load)

	function itemIconUrl(name) {
		return "https://runescape.wiki/w/Special:FilePath/" +
			encodeURIComponent(name.replace(/ /g, "_")) + ".png";
	}

	// Stack sizes render over the icon's top-left corner; mask that region
	// out so stackable items still match.
	function maskStackCorner(img) {
		for (var y = 0; y < Math.min(10, img.height); y++) {
			for (var x = 0; x < Math.min(16, img.width); x++) {
				img.data[(y * img.width + x) * 4 + 3] = 0;
			}
		}
		return img;
	}

	function getItemIcon(name) {
		if (name in iconCache) return Promise.resolve(iconCache[name]);
		return A1lib.ImageDetect.imageDataFromUrl(itemIconUrl(name)).then(function (img) {
			maskStackCorner(img);
			// Nearly-black icons (e.g. charcoal) match any dark screen area,
			// so their hits cannot be trusted.
			var opaque = 0, bright = 0;
			for (var i = 0; i < img.data.length; i += 4) {
				if (img.data[i + 3] > 200) {
					opaque++;
					if (img.data[i] + img.data[i + 1] + img.data[i + 2] > 150) bright++;
				}
			}
			iconCache[name] = { img: img, reliable: opaque >= 60 && bright >= 20 };
			return iconCache[name];
		}, function () {
			iconCache[name] = null;
			return null;
		});
	}

	// Stack sizes render in the small pixel font at the top-left of the
	// slot; read them to verify required amounts of stackable items. The
	// matched icon is trimmed, so the number can sit anywhere up-left of
	// the hit — search each stack colour over the whole area and at every
	// baseline (same approach as the alt1 buffs reader).
	function readStackNumber(imgref, pos) {
		try {
			var font = typeof Alt1Fonts !== "undefined" ? Alt1Fonts.pixel_8px_digits : null;
			if (font && font.default) font = font.default;
			if (!font || !OCR.findChar) return null;
			var cols = [[255, 255, 0], [255, 255, 255], [0, 255, 128], [255, 165, 0]];
			function tryRead(buf) {
				// Prefer the longest digit run over any first hit — icon
				// pixels (e.g. yellow fishing bait) can fake short digits.
				var best = "";
				for (var c = 0; c < cols.length; c++) {
					var chr = OCR.findChar(buf, font, cols[c], 0, 6, buf.width - 10, buf.height - 12);
					if (!chr) continue;
					var r = OCR.readLine(buf, font, cols[c], chr.x, chr.y, true, true);
					var digits = r && r.text ? r.text.replace(/[^0-9]/g, "") : "";
					if (digits.length > best.length) best = digits;
				}
				return best;
			}
			// Pass 1: the strip strictly above the icon, where the number
			// lives — this keeps the icon's own pixels out of the read.
			var d = tryRead(imgref.toData(Math.max(0, pos.x - 24), Math.max(0, pos.y - 26), 84, 30));
			// Pass 2 (fallback): a taller region in case the icon is
			// trimmed low in its slot.
			if (!d) d = tryRead(imgref.toData(Math.max(0, pos.x - 24), Math.max(0, pos.y - 26), 84, 44));
			return d ? parseInt(d, 10) : null;
		} catch (e) {
			return null;
		}
	}

	// Linked pages in Needed lines that are not scannable backpack items.
	var NON_ITEMS = ["backpack", "bank", "tool belt", "lodestone", "grand exchange", "combat", "quick guide"];

	function currentItemNames() {
		if (!guide) return [];
		var seen = {};
		var list = [];
		guide.sections.forEach(function (s) {
			(s.items || []).forEach(function (it) {
				var k = it.name.toLowerCase();
				if (NON_ITEMS.indexOf(k) !== -1) return;
				if (seen[k] === undefined) {
					seen[k] = list.length;
					list.push({ name: it.name, qty: it.qty || 1 });
				} else {
					list[seen[k]].qty = Math.max(list[seen[k]].qty, it.qty || 1);
				}
			});
		});
		return list;
	}

	function scanBackpack() {
		var items = currentItemNames();
		var status = document.getElementById("scan-status");
		if (!items.length) { status.textContent = "This guide lists no linked items."; return; }
		if (!inAlt1() || !alt1.permissionPixel) {
			status.textContent = "Scanning needs Alt1 with the pixel permission.";
			return;
		}
		status.textContent = "Loading icons…";
		Promise.all(items.map(function (it) { return getItemIcon(it.name); })).then(function (icons) {
			status.textContent = "Scanning…";
			var img;
			try {
				img = A1lib.captureHoldFullRs();
			} catch (e) {
				status.textContent = "Could not capture the game screen.";
				return;
			}
			var okCount = 0, total = 0, anyHit = false;
			items.forEach(function (it, i) {
				var mark = document.querySelector('[data-scan-item="' + i + '"]');
				var countEl = document.querySelector('[data-scan-count="' + i + '"]');
				function set(sym, cls, title, count) {
					if (mark) { mark.textContent = sym; mark.className = "scan-mark " + cls; mark.title = title; }
					if (countEl) countEl.textContent = count || "";
					// A confirmed requirement ticks the item's checkbox; a
					// failed scan never un-ticks a manual check (failsafe).
					if (cls === "ok") {
						setItemChecked(it.name, true);
						var box = document.querySelector('[data-scan-box="' + i + '"]');
						if (box) {
							box.checked = true;
							box.parentElement.classList.add("done");
						}
					}
				}
				if (!icons[i]) {
					set("?", "unknown", "Could not load this item's icon");
					return;
				}
				total++;
				var qty = it.qty || 1;
				var hits = [];
				try { hits = img.findSubimage(icons[i].img); } catch (e) { /* keep empty */ }
				if (hits.length) anyHit = true;

				if (!hits.length) {
					set("✗", "missing", "Not visible — check your bank", qty > 1 ? "0/" + qty : "");
				} else if (!icons[i].reliable) {
					// e.g. charcoal: an all-dark icon matches any dark area.
					set("~", "unknown", "Matched, but this icon is too dark/plain to detect reliably — check manually", "");
				} else if (hits.length >= qty) {
					okCount++;
					set("✓", "ok", qty > 1 ? hits.length + " separate ones spotted" : "Spotted on screen", qty > 1 ? hits.length + "/" + qty : "");
				} else {
					// Fewer matches than required — probably a stack; read
					// the stack size next to the first match.
					var n = readStackNumber(img, hits[0]);
					if (n === null) {
						set("~", "unknown", "Found, but the stack amount was unreadable", "?/" + qty);
					} else if (n >= qty) {
						okCount++;
						set("✓", "ok", n + " in stack", n + "/" + qty);
					} else {
						set("✗", "missing", "Stack too small: " + n + " of " + qty + " needed", n + "/" + qty);
					}
				}
			});
			var collected = 0;
			items.forEach(function (it) { if (itemChecked(it.name)) collected++; });
			status.textContent = collected + "/" + items.length + " collected (" + okCount +
				" confirmed by scan" + (collected > okCount ? ", " + (collected - okCount) + " ticked manually" : "") +
				"). Backpack must be open and visible." +
				// Zero matches across every icon points at a scaled interface
				// rather than an empty backpack.
				(total > 0 && !anyHit
					? " ⚠ Nothing matched at all — if your in-game interface scale isn't 100% (graphics settings), Alt1 can't recognise item icons."
					: "");
		});
	}

	// ---------- step logic ----------

	function stepKey(step) {
		return step.sectionIndex + ":" + step.stepIndex;
	}

	function subKey(step, k) {
		return stepKey(step) + ":" + k;
	}

	function isDone(step) {
		return !!questProgress().done[stepKey(step)];
	}

	function isSubDone(step, k) {
		return !!questProgress().done[subKey(step, k)];
	}

	// Whether finishing all sub-steps may auto-complete the parent step.
	function subCascadeAllowed(step) {
		return (step.subs || []).length >= 2 && !step.chat;
	}

	function setSubDone(step, k, done) {
		var p = questProgress();
		if (done) p.done[subKey(step, k)] = true;
		else delete p.done[subKey(step, k)];
		// Completing every sub-step completes the step itself — but only
		// when the sub-steps plausibly ARE the whole step. A single
		// sub-bullet is usually a side note (item preparation etc.), and a
		// parent with its own chat options still has its own conversation
		// to do, so neither cascades upward. Un-ticking a sub always
		// re-opens a step that had been completed.
		var subs = step.subs || [];
		var allDone = subs.length > 0;
		for (var i = 0; i < subs.length; i++) {
			if (!isSubDone(step, i)) { allDone = false; break; }
		}
		if (allDone && subCascadeAllowed(step)) p.done[stepKey(step)] = true;
		else if (!done) delete p.done[stepKey(step)];
		store(PROGRESS_KEY, progress);
		renderSteps();
		if (overlayTimer) paintOverlay();
	}

	function currentStep() {
		for (var i = 0; i < flatSteps.length; i++) {
			if (!isDone(flatSteps[i])) return flatSteps[i];
		}
		return null;
	}

	function setDone(step, done) {
		var p = questProgress();
		if (done) p.done[stepKey(step)] = true;
		else delete p.done[stepKey(step)];
		// Ticking a step cascades to its sub-steps either way.
		(step.subs || []).forEach(function (_, k) {
			if (done) p.done[subKey(step, k)] = true;
			else delete p.done[subKey(step, k)];
		});
		store(PROGRESS_KEY, progress);
		renderSteps();
		if (overlayTimer) paintOverlay();
	}

	// ---------- rendering ----------

	function el(tag, className, text) {
		var node = document.createElement(tag);
		if (className) node.className = className;
		if (text) node.textContent = text;
		return node;
	}

	function mapUrl(m) {
		return "https://mejrs.github.io/rs3?m=" + m.mapId + "&z=4&p=" + m.plane + "&x=" + m.x + "&y=" + m.y;
	}

	// Chip that opens the embedded world map panel at the step's spot.
	function mapChip(m) {
		var a = el("a", "chip chip-map", "Map " + m.x + "," + m.y);
		a.href = mapUrl(m);
		a.title = "Show this location on the world map";
		a.addEventListener("click", function (e) {
			e.preventDefault();
			e.stopPropagation();
			showMapPanel(m);
		});
		return a;
	}

	// Render text with its wiki-linked names (NPCs, places, items) as
	// clickable spans opening the entity popup.
	function appendLinkedText(container, text, links) {
		var remaining = text || "";
		(links || []).forEach(function (lk) {
			var idx = remaining.indexOf(lk.label);
			if (idx === -1) return;
			if (idx > 0) container.appendChild(document.createTextNode(remaining.slice(0, idx)));
			var span = el("span", "wiki-link", lk.label);
			span.title = "Show info from the wiki";
			span.addEventListener("click", function (e) {
				e.stopPropagation();
				showEntityInfo(lk.page);
			});
			container.appendChild(span);
			remaining = remaining.slice(idx + lk.label.length);
		});
		if (remaining) container.appendChild(document.createTextNode(remaining));
	}

	var entityInfoCache = {};

	// Popup for any wiki page: picture + intro (which states locations).
	function showEntityInfo(page) {
		var popup = document.getElementById("item-popup");
		document.getElementById("item-popup-title").textContent = page;
		document.getElementById("item-popup-link").href =
			"https://runescape.wiki/w/" + encodeURIComponent(page.replace(/ /g, "_"));
		var body = document.getElementById("item-popup-body");
		body.textContent = "Loading from the wiki…";
		popup.classList.remove("hidden");

		function render(info) {
			if (document.getElementById("item-popup-title").textContent !== page) return;
			body.innerHTML = "";
			if (info.image) {
				var img = document.createElement("img");
				img.src = info.image;
				img.alt = page;
				img.className = "entity-img";
				img.loading = "lazy";
				body.appendChild(img);
			}
			if (info.intro) body.appendChild(el("p", null, info.intro));
			if (!info.image && !info.intro) {
				body.appendChild(el("p", null, "No summary available — use the full wiki page link above."));
			}
		}

		if (entityInfoCache[page]) { render(entityInfoCache[page]); return; }
		wikiGet({
			action: "query", prop: "extracts|pageimages", exintro: "1", explaintext: "1",
			redirects: "1", pithumbsize: "260", titles: page
		}, function (d) {
			var info = { intro: "", image: null };
			try {
				var pages = d.query.pages;
				var p = pages[Object.keys(pages)[0]];
				info.intro = (p.extract || "").split("\n").slice(0, 2).join(" ");
				if (p.thumbnail && p.thumbnail.source) info.image = p.thumbnail.source;
			} catch (e) { /* keep defaults */ }
			entityInfoCache[page] = info;
			render(info);
		}, function () {
			render({ intro: "", image: null });
		});
	}

	function wikiImageUrl(file, width) {
		return "https://runescape.wiki/w/Special:FilePath/" +
			encodeURIComponent(file.replace(/ /g, "_")) + (width ? "?width=" + width : "");
	}

	// Guide image (puzzle solutions etc.): thumbnail, click to enlarge.
	function guideImage(im) {
		var fig = el("figure", "guide-img");
		var img = document.createElement("img");
		img.src = wikiImageUrl(im.file, 320);
		img.loading = "lazy";
		img.alt = im.caption || im.file;
		img.title = "Click to enlarge";
		img.addEventListener("click", function (e) {
			e.stopPropagation();
			var big = fig.classList.toggle("expanded");
			img.src = wikiImageUrl(im.file, big ? 1000 : 320);
		});
		fig.appendChild(img);
		if (im.caption) fig.appendChild(el("figcaption", null, im.caption));
		return fig;
	}

	function showMapPanel(m) {
		var url = mapUrl(m);
		document.getElementById("map-frame").src = url;
		document.getElementById("map-label").textContent =
			m.x + ", " + m.y + (m.plane ? " · floor " + m.plane : "");
		document.getElementById("map-external").href = url;
		show("map-panel", true);
	}

	function hideMapPanel() {
		document.getElementById("map-frame").src = "about:blank";
		show("map-panel", false);
	}

	function show(id, on) {
		document.getElementById(id).classList.toggle("hidden", !on);
	}

	function setStatus(id, msg) {
		var node = document.getElementById(id);
		node.textContent = msg || "";
		node.classList.toggle("hidden", !msg);
	}

	function doneCountFor(title) {
		var p = progress[title];
		return p ? Object.keys(p.done).length : 0;
	}

	function questStatus(q) {
		return rmStatuses ? rmStatuses[normName(q.name)] || null : null;
	}

	function sortedIndex() {
		var list = questIndex.slice();
		if (prefs.sort === "optimal" && optimalRank) {
			list.sort(function (a, b) {
				var ra = optimalRank[normName(a.name)], rb = optimalRank[normName(b.name)];
				if (ra === undefined && rb === undefined) return a.name.localeCompare(b.name);
				if (ra === undefined) return 1;
				if (rb === undefined) return -1;
				return ra - rb;
			});
		}
		return list;
	}

	function renderList() {
		var filter = document.getElementById("search").value.trim().toLowerCase();
		var main = document.getElementById("quest-list");
		main.innerHTML = "";
		var shown = 0, hidden = 0;
		var optimal = prefs.sort === "optimal" && optimalRank;
		sortedIndex().forEach(function (q) {
			if (filter && q.name.toLowerCase().indexOf(filter) === -1) return;
			var status = questStatus(q);
			if (prefs.hideDone && status === "COMPLETED") { hidden++; return; }
			shown++;
			var row = el("div", "quest-row");
			if (optimal) {
				var rank = optimalRank[normName(q.name)];
				row.appendChild(el("span", "quest-rank", rank === undefined ? "—" : "#" + (rank + 1)));
			}
			row.appendChild(el("span", "quest-name", q.name));
			if (status === "COMPLETED") {
				row.appendChild(el("span", "quest-status done", "✓ done"));
			} else if (status === "STARTED") {
				row.appendChild(el("span", "quest-status started", "▶ in progress"));
			} else {
				var startedCount = doneCountFor(q.title);
				if (startedCount) row.appendChild(el("span", "quest-progress", startedCount + " steps done"));
			}
			row.addEventListener("click", function () { openQuest(q.title); });
			main.appendChild(row);
		});
		if (!shown) {
			main.appendChild(el("div", "status", filter ? "No quests match \"" + filter + "\"." :
				(hidden ? "All " + hidden + " matching quests are completed — untick \"Hide done\" to see them." : "Quest list is empty.")));
		}
	}

	function renderMeta() {
		var info = document.getElementById("quest-info");
		info.innerHTML = "";
		var link = el("a", null, "Open wiki guide");
		link.href = "https://runescape.wiki/w/" + encodeURIComponent(guide.title.replace(/ /g, "_"));
		link.target = "_blank";
		info.appendChild(link);

		var allNeeded = [];
		guide.sections.forEach(function (s) {
			s.needed.forEach(function (n) { allNeeded.push(n); });
		});
		var items = document.getElementById("items-list");
		items.innerHTML = "";
		allNeeded.forEach(function (n) { items.appendChild(el("li", null, n)); });

		// Scannable items: exact wiki item names extracted from Needed lines,
		// with the required amount when the guide gives one.
		var scanList = document.getElementById("scan-list");
		scanList.innerHTML = "";
		var items = currentItemNames();
		items.forEach(function (it, i) {
			var li = el("li", "scan-item" + (itemChecked(it.name) ? " done" : ""));
			var box = document.createElement("input");
			box.type = "checkbox";
			box.checked = itemChecked(it.name);
			box.tabIndex = -1;
			box.setAttribute("data-scan-box", i);
			li.appendChild(box);
			var mark = el("span", "scan-mark", "·");
			mark.setAttribute("data-scan-item", i);
			li.appendChild(mark);
			li.appendChild(document.createTextNode(" " + (it.qty > 1 ? it.qty + "× " : "") + it.name + " "));
			var count = el("span", "scan-count");
			count.setAttribute("data-scan-count", i);
			li.appendChild(count);
			var infoChip = el("a", "chip chip-info", "ℹ");
			infoChip.href = "#";
			infoChip.title = "How to get this item (wiki summary)";
			infoChip.addEventListener("click", function (e) {
				e.preventDefault();
				e.stopPropagation();
				showItemInfo(it.name);
			});
			li.appendChild(infoChip);
			// Manual tick as a failsafe for anything the scanner gets wrong.
			li.addEventListener("click", function () {
				var now = !itemChecked(it.name);
				setItemChecked(it.name, now);
				box.checked = now;
				li.classList.toggle("done", now);
			});
			scanList.appendChild(li);
		});
		document.getElementById("scan-status").textContent = "";
		show("items-panel", allNeeded.length > 0 || items.length > 0);
		// Open by default on every quest so requirements are not missed;
		// the user can still collapse it.
		document.getElementById("items-panel").open = true;
	}

	function renderSteps() {
		var main = document.getElementById("steps");
		main.innerHTML = "";
		var cur = currentStep();
		var doneCount = 0;

		guide.sections.forEach(function (section, si) {
			main.appendChild(el("div", "section-title", section.title));
			section.needed.forEach(function (n) {
				main.appendChild(el("div", "section-needed", n));
			});
			(section.images || []).forEach(function (im) {
				main.appendChild(guideImage(im));
			});

			section.steps.forEach(function (stepData, ti) {
				var step = flatSteps.find(function (s) { return s.sectionIndex === si && s.stepIndex === ti; });
				var done = isDone(step);
				if (done) doneCount++;

				var row = el("div", "step" + (done ? " done" : "") + (step === cur ? " current" : ""));
				var box = document.createElement("input");
				box.type = "checkbox";
				box.checked = done;
				box.tabIndex = -1;
				row.appendChild(box);

				var body = el("div", "step-text");
				appendLinkedText(body, stepData.text, stepData.links);
				if (stepData.chat) body.appendChild(el("span", "chip", "Chat: " + stepData.chat));
				(stepData.maps || []).forEach(function (m) { body.appendChild(mapChip(m)); });
				if (stepData.note) body.appendChild(el("span", "step-note", stepData.note));
				(stepData.images || []).forEach(function (im) { body.appendChild(guideImage(im)); });
				if (stepData.sub && stepData.sub.length) {
					var ul = el("ul", "sub-list");
					stepData.sub.forEach(function (item, k) {
						var subDone = isSubDone(step, k);
						var li = el("li", "sub-step" + (subDone ? " done" : ""));
						var sbox = document.createElement("input");
						sbox.type = "checkbox";
						sbox.checked = subDone;
						sbox.tabIndex = -1;
						li.appendChild(sbox);
						li.appendChild(document.createTextNode(" "));
						appendLinkedText(li, item.text, item.links);
						if (item.chat) li.appendChild(el("span", "chip", "Chat: " + item.chat));
						(item.maps || []).forEach(function (m) { li.appendChild(mapChip(m)); });
						li.addEventListener("click", function (e) {
							e.stopPropagation();
							setSubDone(step, k, !isSubDone(step, k));
						});
						ul.appendChild(li);
					});
					body.appendChild(ul);
				}
				row.appendChild(body);

				row.addEventListener("click", function () { setDone(step, !isDone(step)); });
				main.appendChild(row);
			});
		});

		if (!cur && flatSteps.length) {
			main.appendChild(el("div", "complete-banner", "Quest complete! " + guide.name + " is done."));
		} else {
			var active = main.querySelector(".step.current");
			if (active && doneCount > 0) active.scrollIntoView({ block: "nearest" });
		}

		var total = flatSteps.length || 1;
		document.getElementById("progress-fill").style.width = Math.round((doneCount / total) * 100) + "%";
		document.getElementById("progress-label").textContent = doneCount + " / " + flatSteps.length;
	}

	// ---------- navigation ----------

	function renderQuestDetails() {
		var d = (guide && guide.details) || { items: [], recommended: [] };
		var itemsUl = document.getElementById("details-items");
		var recUl = document.getElementById("details-rec");
		itemsUl.innerHTML = "";
		recUl.innerHTML = "";
		d.items.forEach(function (l) {
			var li = el("li", null, l);
			// Surface the key annotation the quick guide leaves out.
			if (/obtain(ed|able)?\s+(during|in)\s+the\s+quest/i.test(l)) li.className = "obtainable";
			itemsUl.appendChild(li);
		});
		d.recommended.forEach(function (l) { recUl.appendChild(el("li", null, l)); });
		show("details-items-head", d.items.length > 0);
		show("details-rec-head", d.recommended.length > 0);
		show("details-req", d.items.length > 0 || d.recommended.length > 0);
		if (d.items.length || d.recommended.length) show("items-panel", true);
	}

	function openQuest(title) {
		show("view-home", false);
		show("view-guide", true);
		document.getElementById("guide-title").textContent = title.replace(/\/Quick guide$/, "");
		document.getElementById("steps").innerHTML = "";
		document.getElementById("quest-info").innerHTML = "";
		show("items-panel", false);
		setStatus("guide-status", "Loading guide from the wiki…");

		fetchGuide(title, function (parsed) {
			guide = parsed;
			flatSteps = [];
			guide.sections.forEach(function (section, si) {
				section.steps.forEach(function (stepData, ti) {
					flatSteps.push({
						sectionIndex: si,
						stepIndex: ti,
						text: stepData.text,
						chat: stepData.chat,
						subs: stepData.sub || []
					});
				});
			});
			setStatus("guide-status", flatSteps.length ? "" : "This guide has no parseable steps — use the wiki link above.");
			renderMeta();
			renderSteps();
			show("details-req", false);
			attachQuestDetails(renderQuestDetails);
			if (overlayTimer) paintOverlay();
		}, function (msg) {
			setStatus("guide-status", msg);
		});
	}

	function goHome() {
		guide = null;
		flatSteps = [];
		setOverlay(false);
		setAssist(false);
		hideMapPanel();
		show("view-guide", false);
		show("view-home", true);
		renderList();
		document.getElementById("search").focus();
	}

	// ---------- wiring ----------

	function applyRmStatuses(statuses, name, how) {
		rmStatuses = statuses;
		var done = 0;
		Object.keys(statuses).forEach(function (k) { if (statuses[k] === "COMPLETED") done++; });
		setStatus("sync-status", (how || "Synced") + ": " + done + " quests completed on " + name + ".");
		show("rm-import", false);
		renderList();
	}

	function syncRuneMetrics(force) {
		var name = document.getElementById("rsn").value.trim();
		if (!name) {
			setStatus("sync-status", "Enter your RuneScape name first.");
			return;
		}
		prefs.rsn = name;
		store(PREFS_KEY, prefs);
		setStatus("sync-status", "Fetching quest statuses for " + name + "…");
		fetchRuneMetrics(name, force, function (statuses) {
			applyRmStatuses(statuses, name);
		}, function (msg) {
			setStatus("sync-status", msg);
			// Offer the always-works manual path.
			document.getElementById("rm-open").href = RM_URL + encodeURIComponent(name);
			show("rm-import", true);
		});
	}

	// Startup sync: refresh quest completion for the saved name without
	// any clicking. Best-effort — on failure keep the cached statuses and
	// stay quiet instead of popping the manual-import panel (the Sync
	// button still offers that path).
	function autoSyncRuneMetrics() {
		var name = (prefs.rsn || "").trim();
		if (!name) return;
		setStatus("sync-status", "Syncing quest statuses for " + name + "…");
		fetchRuneMetrics(name, false, function (statuses) {
			applyRmStatuses(statuses, name, "Auto-synced");
		}, function () {
			setStatus("sync-status", rmStatuses
				? "Auto-sync failed — showing the last synced quest statuses."
				: "Auto-sync failed — click Sync to retry or import manually.");
		});
	}

	function loadOptimalOrder() {
		if (optimalRank) { renderList(); return; }
		setStatus("sync-status", "Loading optimal quest order from the wiki…");
		fetchOptimalOrder(function (rank) {
			optimalRank = rank;
			setStatus("sync-status", "");
			renderList();
		}, function (msg) {
			setStatus("sync-status", msg);
			prefs.sort = "az";
			document.getElementById("sort-mode").value = "az";
			store(PREFS_KEY, prefs);
		});
	}

	function init() {
		document.getElementById("search").addEventListener("input", renderList);
		document.getElementById("btn-home").addEventListener("click", goHome);

		var rsnInput = document.getElementById("rsn");
		var hideDone = document.getElementById("hide-done");
		var sortMode = document.getElementById("sort-mode");
		rsnInput.value = prefs.rsn || "";
		hideDone.checked = !!prefs.hideDone;
		sortMode.value = prefs.sort || "az";

		document.getElementById("btn-sync").addEventListener("click", function () { syncRuneMetrics(true); });
		rsnInput.addEventListener("keydown", function (e) {
			if (e.key === "Enter") syncRuneMetrics(true);
		});
		document.getElementById("btn-rm-import").addEventListener("click", function () {
			var name = rsnInput.value.trim() || prefs.rsn || "manual import";
			var statuses = parseRmPayload(document.getElementById("rm-json").value.trim());
			if (!statuses) {
				setStatus("sync-status", "That text does not look like RuneMetrics quest data — copy the whole page, starting with {\"quests\":[");
				return;
			}
			store(RM_CACHE_KEY, { ts: Date.now(), name: name, statuses: statuses });
			document.getElementById("rm-json").value = "";
			applyRmStatuses(statuses, name, "Imported");
		});
		document.getElementById("btn-rm-cancel").addEventListener("click", function () {
			show("rm-import", false);
		});
		hideDone.addEventListener("change", function () {
			prefs.hideDone = hideDone.checked;
			store(PREFS_KEY, prefs);
			renderList();
		});
		sortMode.addEventListener("change", function () {
			prefs.sort = sortMode.value;
			store(PREFS_KEY, prefs);
			if (prefs.sort === "optimal") loadOptimalOrder();
			else renderList();
		});

		document.getElementById("btn-next").addEventListener("click", function () {
			var cur = currentStep();
			if (cur) setDone(cur, true);
		});

		document.getElementById("btn-back").addEventListener("click", function () {
			for (var i = flatSteps.length - 1; i >= 0; i--) {
				if (isDone(flatSteps[i])) { setDone(flatSteps[i], false); break; }
			}
		});

		document.getElementById("btn-reset").addEventListener("click", function () {
			if (!guide || !confirm("Clear all progress for " + guide.name + "?")) return;
			progress[guide.title] = { done: {} };
			store(PROGRESS_KEY, progress);
			renderSteps();
			if (overlayTimer) paintOverlay();
		});

		document.getElementById("btn-overlay").addEventListener("click", function () {
			if (!inAlt1()) {
				alert("The overlay only works inside Alt1.");
				return;
			}
			if (!alt1.permissionOverlay) {
				alert("Overlay permission is not granted. Re-add the app or enable it in Alt1 settings.");
				return;
			}
			setOverlay(!overlayTimer);
		});

		document.getElementById("btn-assist").addEventListener("click", function () {
			if (!inAlt1()) {
				alert("Assist only works inside Alt1.");
				return;
			}
			if (!assistAvailable()) {
				alert("Assist needs the pixel and overlay permissions. Re-add the app (the permission request changed) or enable them in Alt1's app settings.");
				return;
			}
			setAssist(!assistTimer);
		});

		var autoBtn = document.getElementById("btn-auto");
		function refreshAutoBtn() {
			autoBtn.textContent = "Auto: " + (autoAdvance ? "on" : "off");
			autoBtn.classList.toggle("active", autoAdvance);
		}
		autoBtn.addEventListener("click", function () {
			if (!autoAdvance) {
				if (!inAlt1()) { alert("Auto-tick only works inside Alt1."); return; }
				if (!assistAvailable()) { alert("Auto-tick needs the pixel and overlay permissions."); return; }
				autoAdvance = true;
				if (!assistTimer) setAssist(true);
			} else {
				autoAdvance = false;
			}
			store(AUTO_KEY, autoAdvance);
			refreshAutoBtn();
		});
		refreshAutoBtn();

		document.getElementById("map-close").addEventListener("click", hideMapPanel);
		document.getElementById("btn-scan").addEventListener("click", scanBackpack);
		document.getElementById("item-popup-close").addEventListener("click", function () {
			document.getElementById("item-popup").classList.add("hidden");
		});
		document.getElementById("item-popup").addEventListener("click", function (e) {
			if (e.target === this) this.classList.add("hidden");
		});

		var overlayPos = document.getElementById("overlay-pos");
		var freePanel = document.getElementById("free-pos");
		var freeBox = document.getElementById("free-pos-box");
		var freeDot = document.getElementById("free-pos-dot");

		function refreshFreeDot() {
			freeDot.style.left = ((prefs.overlayFreeX === undefined ? 0.5 : prefs.overlayFreeX) * 100) + "%";
			freeDot.style.top = ((prefs.overlayFreeY === undefined ? 0.05 : prefs.overlayFreeY) * 100) + "%";
		}

		function placeFree(e) {
			var r = freeBox.getBoundingClientRect();
			prefs.overlayFreeX = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width));
			prefs.overlayFreeY = Math.min(1, Math.max(0, (e.clientY - r.top) / r.height));
			store(PREFS_KEY, prefs);
			refreshFreeDot();
			if (overlayTimer) paintOverlay();
		}

		var freeDragging = false;
		var freeHideTimer = null;
		freeBox.addEventListener("mousedown", function (e) {
			freeDragging = true;
			if (freeHideTimer) { clearTimeout(freeHideTimer); freeHideTimer = null; }
			placeFree(e);
		});
		window.addEventListener("mousemove", function (e) { if (freeDragging) placeFree(e); });
		window.addEventListener("mouseup", function () {
			if (!freeDragging) return;
			freeDragging = false;
			// Placement done — tuck the box away shortly after.
			freeHideTimer = setTimeout(function () { show("free-pos", false); }, 1200);
		});

		function openFreePanel(open) {
			if (open && freeHideTimer) { clearTimeout(freeHideTimer); freeHideTimer = null; }
			show("free-pos", open);
		}

		overlayPos.value = prefs.overlayPos || "tc";
		// On startup a saved free position is already in effect — keep the
		// placement box closed. Only auto-open it when "free" is selected
		// but no spot was ever picked (first use).
		openFreePanel(overlayPos.value === "free" && prefs.overlayFreeX === undefined);
		refreshFreeDot();
		overlayPos.addEventListener("change", function () {
			prefs.overlayPos = overlayPos.value;
			store(PREFS_KEY, prefs);
			openFreePanel(overlayPos.value === "free");
			if (overlayTimer) paintOverlay();
		});
		// Re-open the placement box by clicking the dropdown while "Free…"
		// is already selected.
		overlayPos.addEventListener("click", function () {
			if (overlayPos.value === "free") openFreePanel(true);
		});

		if (inAlt1()) {
			alt1.identifyAppUrl("./appconfig.json");
			// Wipe our overlays the moment the app window closes; painted
			// overlays would otherwise linger until their timer expires.
			window.addEventListener("unload", function () {
				clearOverlay();
				clearAssistOverlay();
			});
		} else {
			var banner = document.getElementById("alt1-banner");
			banner.classList.remove("hidden");
			document.getElementById("addtoalt1").href =
				"alt1://addapp/" + new URL("appconfig.json", location.href).href;
		}

		setStatus("index-status", "Loading quest list from the wiki…");
		fetchQuestIndex(function (list) {
			questIndex = list;
			setStatus("index-status", "");
			// Restore cached RuneMetrics statuses and preferred sort, then
			// refresh the statuses automatically for the saved name.
			var rmCached = load(RM_CACHE_KEY, null);
			if (rmCached && rmCached.name === prefs.rsn) rmStatuses = rmCached.statuses;
			if (prefs.sort === "optimal") loadOptimalOrder();
			renderList();
			autoSyncRuneMetrics();

			// Deep link (?quest=Title) — also used for automated testing.
			var qp = /[?&]quest=([^&]+)/.exec(location.search);
			if (qp) {
				var name = decodeURIComponent(qp[1].replace(/\+/g, " "));
				var match = null;
				questIndex.forEach(function (q) {
					if (q.name.toLowerCase() === name.toLowerCase() || q.title.toLowerCase() === name.toLowerCase()) match = q;
				});
				if (match) openQuest(match.title);
			}
		}, function (msg) {
			setStatus("index-status", msg + " — check your connection and reload.");
		});
	}

	// Debug/test hook (also handy in Alt1's dev console).
	window.__rs3qh = {
		matchOptions: matchOptions,
		parseQuickGuide: parseQuickGuide,
		convoObserve: convoObserve,
		countMatchedCandidates: countMatchedCandidates,
		normName: normName,
		parseRmPayload: parseRmPayload,
		testOverlayCard: function () {
			var gsave = guide, fsave = flatSteps;
			guide = { name: "Test Quest" };
			flatSteps = [
				{ text: "Talk to the very important test NPC in a place with quite a long description that should wrap onto several lines nicely.", chat: "1 Yes please. / Any" },
				{ text: "Then do the next thing." }
			];
			var img;
			try {
				img = renderOverlayCard(flatSteps[0], 0, 2);
			} finally {
				guide = gsave;
				flatSteps = fsave;
			}
			return img;
		},
		parseQuestDetails: parseQuestDetails,
		parseRecipe: parseRecipe,
		parseShopRows: parseShopRows,
		questLockNote: questLockNote,
		locationLockNote: locationLockNote,
		fetchRuneMetrics: fetchRuneMetrics,
		highlightShapes: highlightShapes,
		measureOptionButton: measureOptionButton,
		scaleHintText: scaleHintText,
		subCascadeAllowed: subCascadeAllowed,
		setAuto: function (v) { autoAdvance = v; }
	};

	init();
})();
