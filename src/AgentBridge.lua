-- Agent bridge: loopback line-delimited JSON-RPC polled from OnFrame. Read-only data access.
local json = require("dkjson")
local AgentData = LoadModule("AgentData")

local M = { port = 49090 }
local idx, idxKey

local function env()
	local b = launch and launch.main and launch.main.modes and launch.main.modes["BUILD"]
	if main == nil and launch then main = launch.main end
	return { build = b, data = data, main = launch and launch.main, tree = b and b.spec and b.spec.tree }
end

local function getIndex()
	local e = env()
	local key = tostring(e.tree)
	if not idx or idxKey ~= key then
		idx = AgentData.build(data, e.tree)
		idxKey = key
	end
	return idx
end

-- Bounded, cycle-safe projection of any Lua value into JSON-safe data.
local function project(v, depth, seen, cap)
	cap = cap or 80
	local t = type(v)
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
		return v
	elseif t == "string" or t == "boolean" then return v
	elseif t == "table" then
		if seen[v] then return "<cycle>" end
		if depth <= 0 then
			local n = 0
			for _ in pairs(v) do n = n + 1 end
			return "<table:" .. n .. " keys>"
		end
		seen[v] = true
		local out, isArr, n = {}, true, 0
		for k in pairs(v) do n = n + 1 end
		for i = 1, n do if v[i] == nil then isArr = false break end end
		local count = 0
		if isArr and n > 0 then
			for i = 1, math.min(n, 40) do out[i] = project(v[i], depth - 1, seen, cap) end
			if n > 40 then out[#out + 1] = "<+" .. (n - 40) .. " more>" end
		else
			local keys = {}
			for k in pairs(v) do keys[#keys + 1] = k end
			table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
			for _, k in ipairs(keys) do
				count = count + 1
				if count > cap then out["<truncated>"] = (#keys - cap) .. " more keys" break end
				local val = v[k]
				if type(val) ~= "function" then out[tostring(k)] = project(val, depth - 1, seen, cap) end
			end
		end
		seen[v] = nil
		return out
	end
	return "<" .. t .. ">"
end

local function resolve(path)
	local e = env()
	local cur
	for part in path:gmatch("[^%.]+") do
		if cur == nil then cur = e[part]
		else
			if type(cur) ~= "table" then return nil, "not a table at '" .. part .. "'" end
			local num = tonumber(part)
			if num and cur[num] ~= nil then cur = cur[num] else cur = cur[part] end
		end
		if cur == nil then return nil, "nil at '" .. part .. "'" end
	end
	return cur
end

local methods = {}
M.methods = methods

function methods.reload()
	local chunk, lerr = loadfile("AgentBridge.lua")
	if not chunk then return { error = tostring(lerr) } end
	local ok, fresh = pcall(chunk)
	if not ok or type(fresh) ~= "table" then return { error = tostring(fresh) } end
	for k in pairs(methods) do methods[k] = nil end
	for k, v in pairs(fresh.methods) do methods[k] = v end
	idx = nil
	local f = io.open("AgentBridge.lua", "r")
	local sz = f and #f:read("*a") or -1
	if f then f:close() end
	local names = {}
	for k in pairs(methods) do names[#names + 1] = k end
	table.sort(names)
	return { reloaded = true, fileBytes = sz, methods = names, cwd = GetWorkDir and GetWorkDir() }
end

function methods.ping() return { ok = true, buildLoaded = env().build ~= nil } end

function methods.list_sources()
	return { sources = AgentData.listSources(getIndex()) }
end

local function entryOut(e)
	return { src = e.src, id = e.id, name = e.name, kind = e.kind, level = e.level, group = e.group,
		lines = e.lines, tags = e.tags, spawnOn = e.spawnOn, ascendancy = e.ascendancy }
end

function methods.search(p)
	local res, total, by = AgentData.search(getIndex(), p.query or "", {
		sources = p.sources, slot = p.slot, limit = p.limit or 50, exact = p.exact })
	local out = {}
	for i, e in ipairs(res) do out[i] = entryOut(e) end
	local note
	if total > #out then note = "truncated: raise limit or add sources/slot filters" end
	return { total = total, bySource = by, results = out, note = note,
		hint = "Terms are ANDed; 'immune' matches immun/cannot be/unaffected by only. For partial avoidance also search 'avoid'. Use exact=true for literal substring." }
end

function methods.inspect(p)
	local v, err = resolve(p.path or "")
	if err then return { error = err, roots = { "build", "data", "main", "tree" } } end
	return { path = p.path, value = project(v, p.depth or 2, {}, p.maxKeys or 80) }
end

function methods.get_state()
	local b = env().build
	if not b then return { error = "no build loaded" } end
	return {
		class = b.spec and b.spec.curClassName, ascendancy = b.spec and b.spec.curAscendClassName,
		level = b.characterLevel, stats = project(b.calcsTab and b.calcsTab.mainOutput or {}, 1, {}, 2000),
	}
end

-- Export the equipped gear + gems of the loaded build for pricing (build_cost).
-- Returns { items = [{slot, name, base, rarity, raw, corrupted, sockets, links, ilvl, modLines}], gems = [{name, level, quality, support, enabled}] }
function methods.export_build()
	local b = env().build
	if not b then return { error = "no build loaded" } end
	local it = b.itemsTab
	local out, seen = { items = {}, gems = {} }, {}
	local function lines(list)
		local t = {}
		for _, l in ipairs(list or {}) do if l.line then t[#t + 1] = l.line end end
		return t
	end
	for _, slot in ipairs(it.orderedSlots) do
		local id = slot.selItemId
		local shown = true
		if slot.shown then local ok, v = pcall(slot.shown, slot) shown = (not ok) or v end
		local item = id and id ~= 0 and it.items[id]
		if item and shown and not seen[id] and not slot.inactive then
			seen[id] = true
			local maxLink, cur, prevGroup = 0, 0, nil
			for _, s in ipairs(item.sockets or {}) do
				if s.group == prevGroup then cur = cur + 1 else cur = 1 prevGroup = s.group end
				if cur > maxLink then maxLink = cur end
			end
			out.items[#out.items + 1] = {
				slot = slot.slotName, name = item.title or item.name, base = item.baseName,
				rarity = item.rarity, type = item.type, corrupted = item.corrupted or false,
				sockets = #(item.sockets or {}), links = maxLink, ilvl = item.itemLevel,
				quality = item.quality, influence = project(item.influence or {}, 1, {}, 20),
				implicitLines = lines(item.implicitModLines), explicitLines = lines(item.explicitModLines),
				enchantLines = lines(item.enchantModLines), craftedLines = (function()
					local t = {} for _, l in ipairs(item.explicitModLines or {}) do if l.crafted then t[#t + 1] = l.line end end return t end)(),
				raw = item:BuildRaw(),
			}
		end
	end
	for _, g in ipairs(b.skillsTab.socketGroupList or {}) do
		for _, gem in ipairs(g.gemList or {}) do
			local gd = gem.gemData
			if gd then
				out.gems[#out.gems + 1] = {
					name = gd.name or gem.nameSpec, level = gem.level, quality = gem.quality,
					support = gd.grantedEffect and gd.grantedEffect.support or false,
					enabled = gem.enabled ~= false and g.enabled ~= false, group = g.label or g.slot,
					corrupted = gem.corrupted or false,
					-- non-nil source = granted by an item/config (not a gem you buy)
					source = g.source and tostring(g.source) or nil,
				}
			end
		end
	end
	return out
end

-- Trade-site stat catalogue bundled with PoB (Data/TradeSiteStats.lua), flattened for mod-line -> stat-id matching.
function methods.trade_stats()
	local cats = LoadModule("Data/TradeSiteStats")
	local out = {}
	for _, cat in ipairs(cats or {}) do
		for _, e in ipairs(cat.entries or {}) do
			out[#out + 1] = { id = e.id, text = e.text, type = e.type, hasOptions = e.option ~= nil }
		end
	end
	return { count = #out, stats = out }
end

-- Per-mod build impact: remove each mod line from a copy of the item, recalc with PoB's misc calculator,
-- and report the relative loss in key outputs. Bigger loss = more "key" to the build = must be searched for.
local IMPACT_STATS = { "CombinedDPS", "TotalEHP", "Life", "EnergyShield", "Mana",
	"FireResist", "ColdResist", "LightningResist", "ChaosResist", "Str", "Dex", "Int", "EffectiveMovementSpeedMod" }
local function modImpacts(b, slotName, item)
	local calcFunc, base = b.calcsTab:GetMiscCalculator()
	local res = {}
	for _, listName in ipairs({ "implicitModLines", "explicitModLines" }) do
		for idx, ml in ipairs(item[listName] or {}) do
			if not ml.crafted then
				local copy = new("Item"):Item(item:BuildRaw())
				table.remove(copy[listName], idx)
				copy:BuildAndParseRaw()
				local ok, out = pcall(calcFunc, { repSlotName = slotName, repItem = copy }, false)
				if ok and out then
					local loss, worst = {}, 0
					for _, s in ipairs(IMPACT_STATS) do
						local bv, nv = tonumber(base[s]) or 0, tonumber(out[s]) or 0
						if bv ~= 0 and nv < bv then
							local frac = (bv - nv) / math.abs(bv)
							-- resist/attribute holes are worse than they look: dropping below cap/req breaks a build
							if s:match("Resist$") and (tonumber(out[s]) or 0) < 75 and bv >= 75 then frac = frac * 3 end
							if (s == "Str" or s == "Dex" or s == "Int") and out[s .. "RequiredMissing"] then frac = frac * 3 end
							loss[s] = math.floor(frac * 1000 + 0.5) / 10
							if frac > worst then worst = frac end
						end
					end
					local line = ml.range and itemLib.applyRange(ml.line, ml.range, ml.valueScalar) or ml.line
					res[line] = { score = math.floor(worst * 1000 + 0.5) / 10, loss = loss }
				end
			end
		end
	end
	return res
end

-- Uniques whose mods are picked from a pool (Watcher's Eye, Balance of Terror, Megalomaniac, Forbidden Flame/Flesh,
-- Impossible Escape, Voranas...): PoB models those as variants. Version variants ("Pre 3.19", "Current") are NOT mod pools.
local function isVersionName(n)
	n = tostring(n or "")
	return n:match("^Pre ") or n:match("^Current") or n:match("%d+%.%d+") or n:match("^None$") or n:match("Legacy")
end
local function variableUniqueLines(item)
	-- Equipped items are parsed from the character import (no variant metadata), so consult PoB's unique DB
	-- template: if the template's mod lines are gated by non-version variants, the unique rolls from a pool.
	if not (item.rarity == "UNIQUE" or item.rarity == "RELIC") then return nil end
	local db = main and main.uniqueDB and main.uniqueDB.byTitle
	local tpl = db and db[(item.title or ""):lower()]
	if not tpl or not tpl.variantList or #tpl.variantList < 2 then return nil end
	local pool = tpl.hasAltVariant
	if not pool then
		local n = 0
		for _, v in ipairs(tpl.variantList) do if not isVersionName(v) then n = n + 1 end end
		pool = n >= 3
	end
	if not pool then return nil end
	-- Mods that exist on every variant of the template are fixed; everything else on our item is a rolled pick.
	local fixed = {}
	for _, l in ipairs(tpl.explicitModLines or {}) do
		if not l.variantList then fixed[(l.line or ""):gsub("%(%-?[%d%.]+%-%-?[%d%.]+%)", "#"):gsub("%-?%d+%.?%d*", "#")] = true end
	end
	local lines = {}
	for _, l in ipairs(item.explicitModLines or {}) do
		local norm = (l.line or ""):gsub("%-?%d+%.?%d*", "#")
		if not fixed[norm] then lines[#lines + 1] = l end
	end
	return #lines > 0 and lines or nil, tpl
end

-- Debug/audit: which uniques in PoB's DB count as variable-mod (mod-pool) uniques?
function methods.variable_uniques()
	local db = main and main.uniqueDB and main.uniqueDB.list or {}
	local out = {}
	for _, tpl in pairs(db) do
		local fake = { rarity = "UNIQUE", title = tpl.title, explicitModLines = {} }
		local lines = variableUniqueLines(fake)
		-- variableUniqueLines returns nil with an empty item; detect via the template test directly
		local pool = false
		if tpl.variantList and #tpl.variantList >= 2 then
			if tpl.hasAltVariant then pool = true else
				local n = 0
				for _, v in ipairs(tpl.variantList) do if not isVersionName(v) then n = n + 1 end end
				pool = n >= 3
			end
		end
		if pool then out[#out + 1] = tpl.title .. " (" .. #tpl.variantList .. " variants" .. (tpl.hasAltVariant and ", pick-many" or "") .. ")" end
	end
	table.sort(out)
	return { count = #out, uniques = out }
end

-- Build "buy similar" trade-site queries for each equipped rare/magic item, reusing PoB's own
-- Compare-tab matcher (CompareBuySimilar.addModEntries -> trade stat ids). Mod minimums are scaled by
-- `looseness` (default 0.8) so the search finds "roughly as good" items.
-- params: { looseness = 0.8, maxMods = 6, slots = {"Gloves", ...} (optional) }
function methods.trade_queries(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	local loose = tonumber(p.looseness) or 0.8
	local maxMods = tonumber(p.maxMods) or 12
	local want
	if p.slots then want = {} for _, s in ipairs(p.slots) do want[s] = true end end
	local cbs = require("Classes.CompareBuySimilar")
	local tradeHelpers = require("Classes.TradeHelpers")
	local it = b.itemsTab
	local out, seen = {}, {}
	for _, slot in ipairs(it.orderedSlots) do
		local id = slot.selItemId
		local item = id and id ~= 0 and it.items[id]
		local shown = true
		if slot.shown then local ok, v = pcall(slot.shown, slot) shown = (not ok) or v end
		local varLines = item and variableUniqueLines(item)
		if item and shown and not seen[id] and (not want or want[slot.slotName])
			and (item.rarity == "RARE" or item.rarity == "MAGIC" or varLines) then
			seen[id] = true
			local entries = varLines and cbs.addModEntries(item, { { list = varLines, type = "explicit" } }) or cbs.addModEntries(item, {
				{ list = item.enchantModLines, type = "enchant" },
				{ list = item.implicitModLines, type = "implicit" },
				{ list = (function()
					-- bench-crafted mods are cheap to re-craft after buying: don't pay for them in the search
					local t = {} for _, l in ipairs(item.explicitModLines or {}) do if not l.crafted then t[#t + 1] = l end end return t end)(),
					type = "explicit" },
				{ list = item.scourgeModLines, type = "scourge" },
			})
			local impacts = (p.impact ~= false) and item.rarity == "RARE" and modImpacts(b, slot.slotName, item) or nil
			local cands, skipped = {}, {}
			for _, e in ipairs(entries) do
				local text = table.concat(e.formattedLines or {}, " / "):gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", "")
				if #e.tradeIds == 0 then
					skipped[#skipped + 1] = text
				else
					local raw = (e.formattedLines and #e.formattedLines == 1) and text or nil
					cands[#cands + 1] = { e = e, text = text, raw = raw, mag = math.abs(tonumber(e.value) or 0) }
				end
			end
			-- Prefer explicit mods (what you actually pay for), then larger magnitudes; keep up to maxMods.
			table.sort(cands, function(a, c)
				local ra, rc = (a.e.type == "explicit") and 0 or 1, (c.e.type == "explicit") and 0 or 1
				if ra ~= rc then return ra < rc end
				return a.mag > c.mag
			end)
			local stats = { { type = "and", filters = {} } }
			local used = {}
			for i, c in ipairs(cands) do
				if i > maxMods then skipped[#skipped + 1] = c.text .. " (over maxMods)" else
					local e = c.e
					local function filt(tid)
						local f = { id = tid }
						if e.isOption then
							f.value = tid:match("timeless") and { min = e.value, max = e.value } or { option = e.value }
						elseif e.value then
							local v = e.value * loose
							v = (v >= 0) and math.floor(v) or math.ceil(v)
							if e.invert then f.value = { max = -v } else f.value = { min = v } end
						end
						return f
					end
					if #e.tradeIds == 1 then
						table.insert(stats[1].filters, filt(e.tradeIds[1]))
					else
						local cf = { type = "count", value = { min = 1 }, filters = {} }
						for _, tid in ipairs(e.tradeIds) do table.insert(cf.filters, filt(tid)) end
						table.insert(stats, cf)
					end
					-- per-mod fragment so callers can search arbitrary mod subsets
					local frag
					if #e.tradeIds == 1 then frag = { kind = "and", filter = filt(e.tradeIds[1]) }
					else
						local fl = {} for _, tid in ipairs(e.tradeIds) do fl[#fl + 1] = filt(tid) end
						frag = { kind = "count", filters = fl }
					end
					local imp = impacts and (impacts[c.raw] or impacts[c.text]) or nil
					used[#used + 1] = { text = c.text, type = e.type, value = e.value, tradeIds = e.tradeIds,
						frag = frag, impact = imp and imp.score or 0, impactLoss = imp and imp.loss or nil }
				end
			end
			local cat = tradeHelpers.getTradeCategory(slot.slotName, item)
			local filters = { type_filters = { filters = { rarity = { option = "nonunique" } } } }
			if cat then filters.type_filters.filters.category = { option = cat } end
			local q = { query = { status = { option = "securable" }, stats = stats, filters = filters }, sort = { price = "asc" } }
			if varLines then
				-- variable-mod unique: search this exact unique with its rolled pool mods
				q.query.name = item.title or item.name
				q.query.type = item.baseName
				q.query.filters = { type_filters = { filters = { rarity = { option = "unique" } } } }
			end
			-- Cluster jewels: pin the base type (notables are only meaningful per size).
			if item.baseName and item.baseName:find("Cluster Jewel") then q.query.type = item.baseName end
			out[#out + 1] = { slot = slot.slotName, name = item.title or item.name, base = item.baseName,
				rarity = item.rarity, ilvl = item.itemLevel, query = q, mods = used, unmatched = skipped,
				variableUnique = varLines and true or nil }
		end
	end
	return { looseness = loose, items = out }
end

local function snapshot(out)
	local t = {}
	for k, v in pairs(out) do if type(v) == "number" then t[k] = v end end
	return t
end

local function recalc(b)
	b.configTab:BuildModList()
	b.calcsTab:BuildOutput()
	return snapshot(b.calcsTab.mainOutput)
end

-- Apply extra mod text as a temporary Config custom-mod block, diff stats, then remove it.
-- params: { mods = {"Cannot be Poisoned", ...}, stats = {"Life","TotalDPS"} (optional filter) }
function methods.what_if(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	local list = b.configTab.configSets[b.configTab.activeConfigSetId].customModsList
	local base = snapshot(b.calcsTab.mainOutput)
	local block = { title = "__agent_what_if", enabled = true, text = table.concat(p.mods or {}, "\n") }
	list[#list + 1] = block
	local ok, after = pcall(recalc, b)
	for i = #list, 1, -1 do if list[i] == block then table.remove(list, i) end end
	local ok2 = pcall(recalc, b)
	if not ok then return { error = tostring(after) } end
	local diff, want = {}, nil
	if p.stats then want = {} for _, k in ipairs(p.stats) do want[k] = true end end
	for k, v in pairs(after) do
		local o = base[k] or 0
		if (not want or want[k]) and math.abs(v - o) > 1e-9 then diff[k] = { before = o, after = v, delta = v - o } end
	end
	return { applied = p.mods, changed = diff, restored = ok2 }
end

local function resolveRanges(line, roll)
	return (line:gsub("%((%-?[%d%.]+)%-(%-?[%d%.]+)%)", function(a, b)
		a, b = tonumber(a), tonumber(b)
		local v = roll == "min" and a or roll == "mid" and (a + b) / 2 or b
		if v == math.floor(v) then return tostring(math.floor(v)) end
		return string.format("%.2f", v)
	end))
end

-- Evaluate every search hit as a what-if, rank by a goal.
-- params: search params + { goal = "TotalDPS" | {Life=1,TotalDPS=0.5}, roll = "max"|"mid"|"min",
--   max = 500, budget = 120 (seconds), top = 25, stats = {extra stats to show} }
-- Score = sum(weight * relative change of stat). With no goal, ranks by number of stats changed.
function methods.rank_options(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	local res, total = AgentData.search(getIndex(), p.query or "", {
		sources = p.sources, slot = p.slot, limit = 100000, exact = p.exact })
	local goal = {}
	if type(p.goal) == "string" then goal[p.goal] = 1
	elseif type(p.goal) == "table" then for k, w in pairs(p.goal) do goal[k] = w end end
	local show = {}
	for k in pairs(goal) do show[#show + 1] = k end
	for _, k in ipairs(p.stats or {}) do show[#show + 1] = k end

	local list = b.configTab.configSets[b.configTab.activeConfigSetId].customModsList
	local base = snapshot(b.calcsTab.mainOutput)
	local bestLvl = {}
	for _, e in ipairs(res) do
		if e.group then
			local k = e.src .. "|" .. e.group
			if (bestLvl[k] or -1) < (e.level or 0) then bestLvl[k] = e.level or 0 end
		end
	end
	local seen, rows, skipped = {}, {}, 0
	local t0, budget, cap = os.clock(), p.budget or 120, p.max or 500
	local evaluated, timedOut = 0, false
	for _, e in ipairs(res) do
		if evaluated >= cap then break end
		if os.clock() - t0 > budget then timedOut = true break end
		local mods = {}
		if e.group and (e.level or 0) < (bestLvl[e.src .. "|" .. e.group] or 0) and (p.roll or "max") == "max" then
			skipped = skipped + 1
		else
			for _, l in ipairs(e.lines) do mods[#mods + 1] = resolveRanges(l, p.roll or "max") end
		end
		local text = table.concat(mods, "\n")
		if #mods == 0 or seen[text] then skipped = skipped + 1
		else
			seen[text] = true
			evaluated = evaluated + 1
			local block = { title = "__agent_rank", enabled = true, text = text }
			list[#list + 1] = block
			local ok, after = pcall(recalc, b)
			for i = #list, 1, -1 do if list[i] == block then table.remove(list, i) end end
			if ok then
				local changed, score = 0, 0
				for k, v in pairs(after) do
					local o = base[k] or 0
					if math.abs(v - o) > 1e-9 then changed = changed + 1 end
				end
				for k, w in pairs(goal) do
					local o, v = base[k] or 0, after[k] or 0
					local rel = o ~= 0 and (v - o) / math.abs(o) or (v - o)
					score = score + w * rel
				end
				local deltas = {}
				for _, k in ipairs(show) do
					deltas[k] = { before = base[k] or 0, after = after[k] or 0 }
				end
				rows[#rows + 1] = { src = e.src, name = e.name or e.id, id = e.id, mods = mods,
					spawnOn = e.spawnOn, score = score, statsChanged = changed, stats = deltas }
			end
		end
	end
	pcall(recalc, b)
	local useGoal = next(goal) ~= nil
	table.sort(rows, function(x, y)
		if useGoal and x.score ~= y.score then return x.score > y.score end
		if x.statsChanged ~= y.statsChanged then return x.statsChanged > y.statsChanged end
		return x.name < y.name
	end)
	local top = {}
	for i = 1, math.min(#rows, p.top or 25) do top[i] = rows[i] end
	return { candidates = total, evaluated = evaluated, duplicatesSkipped = skipped, timedOut = timedOut,
		seconds = os.clock() - t0, roll = p.roll or "max", ranked = top }
end

local function normLine(l)
	return (l:gsub("%(%-?[%d%.]+%-%-?[%d%.]+%)", "#"):gsub("%-?%d+%.?%d*", "#"))
end

local CACHE = "agent_effects.json"
local effects, queue, qpos  -- effects[normLine] = { text=probedText, d={stat=delta}, n=changedCount }

local function loadEffects()
	if effects then return end
	effects = {}
	local f = io.open(CACHE, "r")
	if f then
		local ok, t = pcall(json.decode, f:read("*a"))
		f:close()
		if ok and type(t) == "table" then effects = t end
	end
end

local function saveEffects()
	local f = io.open(CACHE, "w")
	if f then f:write(json.encode(effects)) f:close() end
end

local function buildQueue()
	queue, qpos = {}, 1
	local seen = {}
	for _, e in ipairs(getIndex().list) do
		if not e.src:find("^gem") and not e.src:find("^enchant") then
			for _, l in ipairs(e.lines) do
				local k = normLine(l)
				if not seen[k] and not effects[k] and #l > 3 then
					seen[k] = true
					queue[#queue + 1] = { k = k, text = resolveRanges(l, "max") }
				end
			end
		end
	end
end

-- Probe distinct mod lines one at a time; resumable. params: { budget = seconds, reset = bool }
function methods.probe_batch(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	loadEffects()
	if p.reset then effects = {} queue = nil end
	if not queue then buildQueue() end
	local list = b.configTab.configSets[b.configTab.activeConfigSetId].customModsList
	local base = snapshot(b.calcsTab.mainOutput)
	local t0, done = os.clock(), 0
	while qpos <= #queue and os.clock() - t0 < (p.budget or 60) do
		local q = queue[qpos]
		qpos = qpos + 1
		local block = { title = "__agent_probe", enabled = true, text = q.text }
		list[#list + 1] = block
		local ok, after = pcall(recalc, b)
		for i = #list, 1, -1 do if list[i] == block then table.remove(list, i) end end
		local d, n = {}, 0
		if ok then
			for k, v in pairs(after) do
				local o = base[k] or 0
				if math.abs(v - o) > 1e-9 then d[k] = v - o n = n + 1 end
			end
		end
		effects[q.k] = { text = q.text, d = d, n = n, err = (not ok) or nil }
		done = done + 1
		if done % 25 == 0 then collectgarbage() end
	end
	collectgarbage()
	pcall(recalc, b)
	saveEffects()
	return { probed = done, remaining = #queue - qpos + 1, total = #queue, cached = (function() local c = 0 for _ in pairs(effects) do c = c + 1 end return c end)() }
end

-- Reverse lookup: which game-data entries move `stat`? params: { stat, direction = "up"|"down", min = 0,
--   sources = {...}, slot = "boots", limit = 40, text = optional extra substring filter }
function methods.find_by_effect(p)
	loadEffects()
	if not next(effects) then return { error = "effect index empty: run probe_batch first" } end
	local hits, total = {}, 0
	local dir = p.direction or "up"
	for _, e in ipairs(getIndex().list) do
		local ok = true
		if p.sources then
			ok = false
			for _, pre in ipairs(p.sources) do if e.src:sub(1, #pre) == pre then ok = true break end end
		end
		if ok and p.slot and e.spawnOn then
			ok = false
			for _, s in ipairs(e.spawnOn) do if s == p.slot then ok = true break end end
		end
		if ok then
			local best, via
			for _, l in ipairs(e.lines) do
				local fx = effects[normLine(l)]
				local d = fx and fx.d[p.stat]
				if d and ((dir == "up" and d > (p.min or 0)) or (dir == "down" and d < -(p.min or 0))) then
					-- re-resolve at the entry's own max roll would need a probe; report probed max-roll delta
					if not best or math.abs(d) > math.abs(best) then best, via = d, l end
				end
			end
			if best then
				total = total + 1
				hits[#hits + 1] = { src = e.src, name = e.name or e.id, delta = best, line = via, spawnOn = e.spawnOn,
					allLines = e.lines, level = e.level, group = e.group }
			end
		end
	end
	table.sort(hits, function(x, y) return math.abs(x.delta) > math.abs(y.delta) end)
	local out = {}
	for i = 1, math.min(#hits, p.limit or 40) do out[i] = hits[i] end
	local by = {}
	for _, h in ipairs(hits) do by[h.src] = (by[h.src] or 0) + 1 end
	return { stat = p.stat, direction = dir, total = total, bySource = by, results = out,
		note = "delta = change in stat when that mod line (max roll) is added to the current build; conditional mods may show 0 and be missing." }
end

function methods.effect_stats(p)
	loadEffects()
	local c, noeff, errs = 0, 0, 0
	local statCounts = {}
	for k, v in pairs(effects) do
		c = c + 1
		if v.n == 0 then noeff = noeff + 1 end
		if v.err then errs = errs + 1 end
		for s in pairs(v.d) do statCounts[s] = (statCounts[s] or 0) + 1 end
	end
	return { probed = c, noEffect = noeff, errors = errs, statsMoved = statCounts }
end

local function handle(line)
	local req = json.decode(line)
	if type(req) ~= "table" then return { error = "bad json" } end
	local fn = methods[req.method]
	if not fn then return { id = req.id, error = "unknown method: " .. tostring(req.method) } end
	local ok, res = pcall(fn, req.params or {})
	if not ok then return { id = req.id, error = tostring(res) } end
	return { id = req.id, result = res }
end
M.handle = handle

-- Hot-reload fix: the original module's `methods` (launch.agent.methods) is the table the socket
-- handler dispatches from. Older reloads copied into a stale fresh table, so on (re)load we always
-- sync our definitions into the live one.
do
	local live = launch and launch.agent and launch.agent.methods
	if live and live ~= methods then
		for k in pairs(live) do live[k] = nil end
		for k, v in pairs(methods) do live[k] = v end
	end
end

local server, clients = nil, {}
function M.start()
	local socket = require("socket")
	server = socket.tcp4()
	server:setoption("reuseaddr", true)
	local ok, err = server:bind("127.0.0.1", M.port)
	if not ok then ConPrintf("AgentBridge: bind failed: %s", tostring(err)) server = nil return end
	server:listen(4)
	server:settimeout(0)
	ConPrintf("AgentBridge listening on 127.0.0.1:%d", M.port)
end

function M.poll()
	if not server then return end
	local c = server:accept()
	if c then c:settimeout(0) clients[#clients + 1] = { sock = c, buf = "" } end
	for i = #clients, 1, -1 do
		local cl = clients[i]
		local data_, err, partial = cl.sock:receive(65536)
		local chunk = data_ or partial
		if chunk and #chunk > 0 then cl.buf = cl.buf .. chunk end
		while true do
			local nl = cl.buf:find("\n", 1, true)
			if not nl then break end
			local line = cl.buf:sub(1, nl - 1)
			cl.buf = cl.buf:sub(nl + 1)
			if #line > 0 then
				local ok, resp = pcall(handle, line)
				if not ok then resp = { error = tostring(resp) } end
				local okj, s = pcall(json.encode, resp)
				cl.sock:send((okj and s or '{"error":"encode failed"}') .. "\n")
			end
		end
		if err == "closed" then cl.sock:close() table.remove(clients, i) end
	end
end

return M
