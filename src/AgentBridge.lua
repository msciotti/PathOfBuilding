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
	-- Update the table the running bridge dispatches from; after one reload this function belongs to a
	-- fresh module whose own `methods` is not the live one.
	local live = launch.agent and launch.agent.methods or methods
	for k in pairs(live) do live[k] = nil end
	for k, v in pairs(fresh.methods) do live[k] = v end
	idx = nil
	local f = io.open("AgentBridge.lua", "r")
	local sz = f and #f:read("*a") or -1
	if f then f:close() end
	local names = {}
	for k in pairs(live) do names[#names + 1] = k end
	table.sort(names)
	return { reloaded = true, fileBytes = sz, methods = names, cwd = GetWorkDir and GetWorkDir() }
end

function methods.ping() return { ok = true, buildLoaded = env().build ~= nil } end

-- Same as pressing F5 in dev mode: reloads all Lua in-process. Unsaved build changes are lost.
function methods.restart()
	if not (launch and launch.devMode) then return { error = "restart requires dev mode" } end
	launch.doRestart = "Restarting..."
	return { restarting = true }
end

function methods.list_sources()
	return { sources = AgentData.listSources(getIndex()) }
end

local function entryOut(e)
	return { src = e.src, id = e.id, name = e.name, kind = e.kind, level = e.level, group = e.group,
		lines = e.lines, tags = e.tags, spawnOn = e.spawnOn, ascendancy = e.ascendancy, essenceSlots = e.essenceSlots }
end

function methods.search(p)
	local res, total, by, terms = AgentData.search(getIndex(), p.query or "", {
		sources = p.sources, slot = p.slot, limit = p.limit or 50, exact = p.exact })
	local out = {}
	for i, e in ipairs(res) do
		out[i] = entryOut(e)
		if #e.lines > 3 then out[i].matched = AgentData.matchedLines(e, terms) end
	end
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

local function mainSkillInfo(b)
	local env_ = b.calcsTab and b.calcsTab.mainEnv
	local skill = env_ and env_.player and env_.player.mainSkill
	if not skill then return nil end
	local types = {}
	for id, on in pairs(skill.skillTypes or {}) do
		if on then
			for name, v in pairs(SkillType or {}) do
				if v == id then types[#types + 1] = name end
			end
		end
	end
	table.sort(types)
	return { name = skill.activeEffect and skill.activeEffect.grantedEffect and skill.activeEffect.grantedEffect.name,
		types = types }
end

function methods.get_state()
	local b = env().build
	if not b then return { error = "no build loaded" } end
	return {
		class = b.spec and b.spec.curClassName, ascendancy = b.spec and b.spec.curAscendClassName,
		level = b.characterLevel, mainSkill = mainSkillInfo(b),
		dpsHint = "Use CombinedDPS (or TotalDPS for hits only) as a DPS goal. FullDPS is only set when skills are marked for Full DPS; PoisonDPS/BleedDPS are per stack, so use WithPoisonDPS/WithBleedDPS or CombinedDPS.",
		stats = project(b.calcsTab and b.calcsTab.mainOutput or {}, 1, {}, 2000),
	}
end

function methods.list_stats(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	local labels = {}
	for _, ds in ipairs(b.displayStats or {}) do
		if ds.stat and ds.label and not labels[ds.stat] then labels[ds.stat] = ds.label end
	end
	local q = p.query and p.query:lower()
	local out = {}
	for k, v in pairs(b.calcsTab.mainOutput) do
		local t = type(v)
		if (t == "number" or t == "boolean") and (not q or k:lower():find(q, 1, true) or (labels[k] or ""):lower():find(q, 1, true)) then
			out[#out + 1] = { stat = k, label = labels[k], value = t == "boolean" and (v and 1 or 0) or v }
		end
	end
	table.sort(out, function(a, b) return a.stat < b.stat end)
	return { count = #out, stats = out, note = "Boolean outputs are shown as 0/1. Values are for the build as configured." }
end

local function snapshot(out)
	local t = {}
	for k, v in pairs(out) do
		if type(v) == "number" then t[k] = v
		elseif type(v) == "boolean" then t[k] = v and 1 or 0 end
	end
	return t
end

-- Item text writes rolls as "(12-14)"; PoB resolves them before parsing, so do the same.
local function resolveRanges(line, roll)
	return (line:gsub("%((%-?[%d%.]+)%-(%-?[%d%.]+)%)", function(a, b)
		a, b = tonumber(a), tonumber(b)
		local v = roll == "min" and a or roll == "mid" and (a + b) / 2 or b
		if v == math.floor(v) then return tostring(math.floor(v)) end
		return string.format("%.2f", v)
	end))
end

local function requirements(mods)
	local reqs, assume, unmet, seen = {}, {}, {}, {}
	local b = env().build
	local out = b and b.calcsTab.mainOutput or {}
	local mainEnv = b and b.calcsTab.mainEnv
	local db = mainEnv and mainEnv.player and mainEnv.player.modDB
	local function add(kind, desc, mod, noteOnly)
		if seen[desc] then return end
		seen[desc] = true
		local met
		if mod and mod.name and mod.type == "FLAG" and db then met = db:Flag(nil, mod.name) or false
		elseif mod and mod.clear and db then met = not db:Flag(nil, mod.clear) end
		reqs[#reqs + 1] = { kind = kind, desc = desc, metOnBuild = met }
		if mod then assume[#assume + 1] = mod elseif not noteOnly then unmet[#unmet + 1] = desc end
	end
	for _, m in ipairs(mods or {}) do
		-- Flask effect/duration mods only show while flasks are active
		if type(m.name) == "string" and m.name:match("^Flask") and not m.name:match("Charge") then
			add("flasks", "equipped flasks active", { flasks = true })
		end
		for _, t in ipairs(m) do
			if t.type == "Condition" and not t.neg then
				for _, var in ipairs(t.varList or { t.var }) do
					add("condition", var, { name = "Condition:" .. var, type = "FLAG", value = true })
					if var == "UsingFlask" then add("flasks", "equipped flasks active", { flasks = true }) end
					if t.varList then break end -- any one of the list satisfies it
				end
			elseif t.type == "Condition" and t.neg and t.var then
				add("condition", "not " .. t.var, { clear = "Condition:" .. t.var })
			elseif t.type == "Condition" and t.neg then
				add("condition", "not " .. table.concat(t.varList or {}, "/"))
			elseif t.type == "ItemCondition" then
				local parts = {}
				for k, v in pairs(t) do
					if k ~= "type" and k ~= "itemSlot" then parts[#parts + 1] = k .. "=" .. tostring(v) end
				end
				table.sort(parts)
				local slot = (t.itemSlot or "{SlotName}"):find("{SlotName}", 1, true) and "this item" or t.itemSlot
				add("item", "item condition on " .. slot .. ": " .. table.concat(parts, ", ") .. " (depends on the actual item; can't be forced)", nil, true)
			elseif t.type == "MultiplierThreshold" and not t.upper and t.var then
				add("multiplier", t.var .. " >= " .. tostring(t.threshold), { name = "Multiplier:" .. t.var, type = "BASE", value = tonumber(t.threshold) or 1 })
			elseif t.type == "MultiplierThreshold" then
				add("multiplier", tostring(t.var or "?") .. (t.upper and " <= " or " >= ") .. tostring(t.threshold))
			elseif t.type == "Multiplier" and t.var then
				-- "per Frenzy Charge" etc.: scales with a count. Charges can be assumed at their maximum.
				local maxCharges = t.var:match("Charge$") and tonumber(out[t.var .. "sMax"])
				if maxCharges and maxCharges > 0 then
					add("scales", "per " .. t.var .. " (assumed at max " .. maxCharges .. ")", { name = "Multiplier:" .. t.var, type = "BASE", value = maxCharges })
				else
					add("scales", "per " .. t.var, nil, true)
				end
			elseif t.type == "StatThreshold" then
				add("stat", tostring(t.stat) .. (t.upper and " <= " or " >= ") .. tostring(t.threshold or t.thresholdStat))
			elseif t.type == "ActorCondition" and (t.var or t.varList) then
				add("actor", tostring(t.actor) .. ": " .. tostring(t.var or table.concat(t.varList, "/")))
			end
		end
	end
	return reqs, assume, unmet
end

local function flagNames(mask, tbl)
	if not mask or mask == 0 or not tbl then return nil end
	local names = {}
	for name, v in pairs(tbl) do
		if type(v) == "number" and v > 0 and name ~= "SourceMask" and bit.band(mask, v) == v then names[#names + 1] = name end
	end
	table.sort(names)
	return #names > 0 and names or nil
end

local function parseLine(line, roll)
	local resolved = resolveRanges(StripEscapes(line), roll or "max"):match("^%s*(.-)%s*$")
	local mods, extra = modLib.parseMod(resolved)
	local out = {}
	for i, m in ipairs(mods or {}) do
		local tags = {}
		for _, t in ipairs(m) do
			local tag = {}
			for k, v in pairs(t) do if type(v) ~= "table" then tag[k] = v end end
			tags[#tags + 1] = tag
		end
		out[i] = { name = m.name, type = m.type, value = type(m.value) ~= "table" and m.value or project(m.value, 2, {}, 20), tags = tags,
			flags = flagNames(m.flags, ModFlag), keywordFlags = flagNames(m.keywordFlags, KeywordFlag) }
	end
	local reqs, assume, unmet = requirements(mods)
	return { line = line, resolved = resolved ~= line and resolved or nil, supported = mods ~= nil and not extra,
		extra = extra, mods = out, requires = #reqs > 0 and reqs or nil, _assume = assume, _unmet = unmet }
end

function methods.parse_mod(p)
	local res = {}
	for i, l in ipairs(p.lines or { p.line }) do
		local r = parseLine(l, p.roll)
		r._assume, r._unmet = nil, nil
		res[i] = r
	end
	return { results = res }
end

local function modTotals(b, names)
	local env_ = b.calcsTab.mainEnv
	local db = env_ and (env_.player and env_.player.modDB or env_.modDB)
	if not db or not names then return nil end
	local t = {}
	for name, ty in pairs(names) do
		if ty == "FLAG" then t[name] = db:Flag(nil, name) and 1 or 0
		elseif ty == "BASE" or ty == "INC" or ty == "MORE" then t[name .. ":" .. ty] = db:Sum(ty, nil, name) end
	end
	return t
end

local function recalc(b, extra, totalsFor)
	local input = b.configTab.configSets[b.configTab.activeConfigSetId].input
	local configSaved = {}
	for _, m in ipairs(extra or {}) do
		if m.config and configSaved[m.config] == nil then
			configSaved[m.config] = input[m.config] or false
			input[m.config] = true
		end
	end
	b.configTab:BuildModList()
	for var, old in pairs(configSaved) do input[var] = old or nil end
	local flaskSlots = {}
	for _, m in ipairs(extra or {}) do
		if m.config then
		elseif m.raw then
			b.configTab.modList:AddMod(m.raw)
		elseif m.clear then
			local list = b.configTab.modList
			for i = #list, 1, -1 do
				if list[i].name == m.clear then table.remove(list, i) end
			end
		elseif m.flasks then
			for _, slot in ipairs(b.itemsTab.orderedSlots or {}) do
				if slot.slotName:match("^Flask %d") and not slot.active then
					slot.active = true
					flaskSlots[#flaskSlots + 1] = slot
				end
			end
		else
			b.configTab.modList:NewMod(m.name, m.type, m.value, "Agent assumption")
		end
	end
	local ok, err = pcall(b.calcsTab.BuildOutput, b.calcsTab)
	for _, slot in ipairs(flaskSlots) do slot.active = false end
	if not ok then error(err, 0) end
	return snapshot(b.calcsTab.mainOutput), modTotals(b, totalsFor)
end

-- JSON can't carry inf/nan (dkjson writes null), so report them as strings.
local function jsonNumber(v)
	if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
	return v
end

local function diffStats(base, after, want)
	local diff = {}
	for k, v in pairs(after) do
		local o = base[k] or 0
		if (not want or want[k]) and v ~= o and not (math.abs(v - o) <= 1e-9) then
			diff[k] = { before = jsonNumber(o), after = jsonNumber(v), delta = jsonNumber(v - o) }
		end
	end
	return diff
end

local function evalMods(b, lines, extra, totalsFor)
	local list = b.configTab.configSets[b.configTab.activeConfigSetId].customModsList
	local block = { title = "__agent_what_if", enabled = true, text = table.concat(lines, "\n") }
	list[#list + 1] = block
	local ok, after, totals = pcall(recalc, b, extra, totalsFor)
	for i = #list, 1, -1 do if list[i] == block then table.remove(list, i) end end
	return ok, after, totals
end

local function mainSkill(b)
	local env_ = b.calcsTab and b.calcsTab.mainEnv
	return env_ and env_.player and env_.player.mainSkill
end

local configOptionList
local function configOptions()
	configOptionList = configOptionList or LoadModule("Modules/ConfigOptions")
	return configOptionList
end

local function mainSocketSlot(b)
	local s = mainSkill(b)
	local slot = s and s.socketGroup and s.socketGroup.slot
	return slot and slot:gsub(" Swap", "") or nil
end

local function mainIsSpell(b)
	local s = mainSkill(b)
	return s and s.skillTypes and s.skillTypes[SkillType.Spell] and not s.skillTypes[SkillType.Attack]
end

local function attackOnly(flags)
	for _, f in ipairs(flags) do if f == "Attack" or f == "Melee" then return true end end
	return false
end

local function assumedNames(assume)
	local names = {}
	for _, m in ipairs(assume) do
		names[#names + 1] = m.config and ("Config: " .. m.label) or m.raw and ("socketed in " .. tostring(m.raw[1] and m.raw[1].slotName or "slot")) or m.flasks and "equipped flasks active" or m.clear and ("not " .. m.clear)
			or (m.name .. (m.type == "BASE" and (" = " .. m.value) or ""))
	end
	return names
end

function methods.what_if(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	local base = snapshot(b.calcsTab.mainOutput)
	local lines, unsupported, reqs, assume, unmet, seen, names = {}, {}, {}, {}, {}, {}, {}
	local alreadyKeystone, socketedMods, socketedInfo, flagMismatch, hitOnly = {}, {}, {}, {}, {}
	for _, l in ipairs(p.mods or {}) do
		local r = parseLine(l, p.roll)
		local socketed = {}
		if r.supported then
			-- "+1 to Level of Socketed Gems" only applies to gems in the item's slot; a custom-mod block has no
			-- slot, so add these mods directly, bound to `slot` (default: the main skill's socket group slot)
			for _, m in ipairs(modLib.parseMod(r.resolved or l) or {}) do
				for _, t in ipairs(m) do
					if t.type == "SocketedIn" and t.slotName == "{SlotName}" then socketed[#socketed + 1] = m break end
				end
			end
		end
		if #socketed > 0 then
			local slot = p.slot or mainSocketSlot(b)
			if slot then
				for _, m in ipairs(socketed) do
					local c = copyTable(m)
					for _, t in ipairs(c) do if t.type == "SocketedIn" and t.slotName == "{SlotName}" then t.slotName = slot end end
					socketedMods[#socketedMods + 1] = { raw = c }
				end
				socketedInfo[#socketedInfo + 1] = { line = l, slot = slot }
			else
				unsupported[#unsupported + 1] = { line = l, extra = "socketed-gem mod: pass `slot` (main skill has no socket slot)" }
			end
		else
			lines[#lines + 1] = r.resolved or l
		end
		for _, m in ipairs(r.mods) do
			if ((m.flags and attackOnly(m.flags)) or (m.keywordFlags and attackOnly(m.keywordFlags))) and mainIsSpell(b) then flagMismatch[#flagMismatch + 1] = l break end
		end
		for _, m in ipairs(r.mods) do
			if m.type == "FLAG" and m.flags and m.name:match("^Condition:") then hitOnly[#hitOnly + 1] = l break end
		end
		for _, m in ipairs(r.mods) do
			names[m.name] = m.type
			if m.name == "Keystone" and type(m.value) == "string" and b.spec.allocNodes then
				for _, n in pairs(b.spec.allocNodes) do
					if n.dn == m.value then alreadyKeystone[#alreadyKeystone + 1] = m.value end
				end
			end
		end
		if not r.supported then unsupported[#unsupported + 1] = { line = l, extra = r.extra } end
		for _, q in ipairs(r.requires or {}) do
			if not seen[q.desc] then seen[q.desc] = true reqs[#reqs + 1] = q end
		end
		for _, m in ipairs(r._assume) do assume[#assume + 1] = m end
		for _, u in ipairs(r._unmet) do unmet[#unmet + 1] = u end
	end
	local want
	if p.stats then want = {} for _, k in ipairs(p.stats) do want[k] = true end end

	local totalsBefore = modTotals(b, names)
	local flagsBefore = copyTable((mainSkill(b) or {}).skillFlags or {}, true)
	local ok, after, totalsAfter = evalMods(b, lines, socketedMods, names)
	for _, m in ipairs(socketedMods) do table.insert(assume, 1, m) end
	if ok then
		local flagsAfter = (mainSkill(b) or {}).skillFlags or {}
		local input = b.configTab.configSets[b.configTab.activeConfigSetId].input
		for _, opt in ipairs(configOptions()) do
			local gates = type(opt.ifFlag) == "table" and opt.ifFlag or { opt.ifFlag }
			for _, f in ipairs(opt.ifFlag and gates or {}) do
				if opt.type == "check" and flagsAfter[f] and not flagsBefore[f] and not input[opt.var] then
					local label = StripEscapes(opt.label or opt.var)
					reqs[#reqs + 1] = { kind = "config", desc = "Config: " .. label, metOnBuild = false }
					assume[#assume + 1] = { config = opt.var, label = label }
					break
				end
			end
		end
	end
	local met
	local needsAssume = false
	for _, q in ipairs(reqs) do if q.metOnBuild ~= true then needsAssume = true end end
	if ok and #assume > 0 and p.assume ~= false and needsAssume then
		local ok3, afterMet = evalMods(b, lines, assume)
		if ok3 then
			met = { assumed = assumedNames(assume), cannotForce = #unmet > 0 and unmet or nil, changed = diffStats(base, afterMet, want) }
		end
	end
	local ok2 = pcall(recalc, b)
	if not ok then return { error = tostring(after) } end

	local diff = diffStats(base, after, want)
	local current, changedOther
	if want then
		current = {}
		for k in pairs(want) do current[k] = base[k] end
		-- The stats filter must not hide that something else moved (e.g. FireResist capped, FireResistOverCap up)
		if next(diff) == nil then
			for k, v in pairs(diffStats(base, after)) do
				changedOther = changedOther or {}
				changedOther[k] = v
			end
		end
	end
	local capped = {}
	for k in pairs(want or diff) do
		local v, cap = base[k], base[k .. "Max"]
		if type(v) == "number" and type(cap) == "number" and v >= cap then capped[#capped + 1] = k .. " at cap " .. cap end
	end
	for k in pairs(changedOther or diff) do
		local stem = k:match("^(.-)OverCap") or k:match("^(.-)Overcap")
		if stem and not (diff[stem] or (changedOther and changedOther[stem])) then capped[#capped + 1] = stem .. " is capped; only " .. k .. " moved" end
	end
	table.sort(capped)
	local totals
	if totalsBefore and totalsAfter then
		for k, v in pairs(totalsAfter) do
			local o = totalsBefore[k] or 0
			if v ~= o then totals = totals or {} totals[k] = { before = o, after = v } end
		end
	end
	local note
	if #alreadyKeystone > 0 then
		note = "Keystone already allocated on this build: " .. table.concat(alreadyKeystone, ", ")
	elseif #hitOnly > 0 and next(diff) == nil then
		note = "These grant a buff/condition only in a Hit/attack context, which PoB doesn't model as a static effect; enable the matching Config option (e.g. Onslaught) to see it: " .. table.concat(hitOnly, "; ")
	elseif #flagMismatch > 0 and next(diff) == nil then
		note = "Attack-only mod(s) and the main skill is a spell: " .. table.concat(flagMismatch, "; ")
	elseif #capped > 0 and next(diff) == nil then
		note = "Capped: " .. table.concat(capped, "; ")
	elseif changedOther then
		note = "None of the requested stats changed, but other stats did: see changedOther."
	elseif next(diff) == nil and #unsupported == 0 then
		if met and next(met.changed) then
			note = "No effect as the build is configured; see ifConditionsMet for the effect once its requirements hold."
		elseif totals then
			note = "No output stat shows this, but the mod totals in `modTotals` changed."
		elseif #reqs > 0 then
			note = "No effect even with requirements forced on; it may need something that can't be forced (see requires) or the build already has the effect."
		else
			note = "Parsed but no output stat changed: the build may already have this effect (check `current` via stats) or it isn't shown in calc output."
		end
	end
	return { applied = lines, changed = diff, current = current, requires = #reqs > 0 and reqs or nil,
		ifConditionsMet = met, modTotals = totals, socketedAppliedTo = #socketedInfo > 0 and socketedInfo or nil, changedOther = changedOther, capped = #capped > 0 and capped or nil, unsupported = #unsupported > 0 and unsupported or nil, restored = ok2, note = note }
end

function methods.rank_options(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	local res, total, _, terms = AgentData.search(getIndex(), p.query or "", {
		sources = p.sources, slot = p.slot, limit = 100000, exact = p.exact })
	local goal = {}
	if type(p.goal) == "string" then goal[p.goal] = 1
	elseif type(p.goal) == "table" then for k, w in pairs(p.goal) do goal[k] = w end end
	local show = {}
	for k in pairs(goal) do show[#show + 1] = k end
	for _, k in ipairs(p.stats or {}) do show[#show + 1] = k end

	local base = snapshot(b.calcsTab.mainOutput)
	local bestLvl = {}
	for _, e in ipairs(res) do
		if e.group then
			local k = e.src .. "|" .. e.group
			if (bestLvl[k] or -1) < (e.level or 0) then bestLvl[k] = e.level or 0 end
		end
	end
	local function measure(after)
		local changed, score = 0, 0
		for k, v in pairs(after) do
			if math.abs(v - (base[k] or 0)) > 1e-9 then changed = changed + 1 end
		end
		for k, w in pairs(goal) do
			local o, v = base[k] or 0, after[k] or 0
			-- (after-before)/max(|before|,|after|): one bounded scale (-1..1) even when before is 0
			local d = math.max(math.abs(o), math.abs(v))
			if d > 0 and v == v and o == o and d ~= math.huge then score = score + w * (v - o) / d end
		end
		return changed, score
	end
	local seen, rows, skipped = {}, {}, 0
	local t0, budget, cap = os.clock(), p.budget or 120, p.max or 500
	local evaluated, timedOut = 0, false
	for _, e in ipairs(res) do
		if evaluated >= cap then break end
		if os.clock() - t0 > budget then timedOut = true break end
		local mods, partial = {}, nil
		if e.group and (e.level or 0) < (bestLvl[e.src .. "|" .. e.group] or 0) and (p.roll or "max") == "max" then
			skipped = skipped + 1
		else
			-- Uniques carry every variant's lines; score only the lines that match the query
			local lines = e.lines
			if e.src:find("^unique") and #lines > 3 then
				lines, partial = AgentData.matchedLines(e, terms), true
			end
			for _, l in ipairs(lines) do mods[#mods + 1] = resolveRanges(l, p.roll or "max") end
		end
		local text = table.concat(mods, "\n")
		if #mods == 0 or seen[text] then skipped = skipped + 1
		else
			seen[text] = true
			evaluated = evaluated + 1
			local ok, after = evalMods(b, mods)
			if ok then
				local changed, score = measure(after)
				local assumed
				if (changed == 0 or score == 0) and p.assume ~= false then
					local assume, names, seenName = {}, {}, {}
					for _, l in ipairs(mods) do
						for _, m in ipairs(parseLine(l)._assume) do
							local name = assumedNames({ m })[1]
							if not seenName[name] then
								seenName[name] = true
								assume[#assume + 1] = m
								names[#names + 1] = name
							end
						end
					end
					if #assume > 0 then
						local ok2, afterMet = evalMods(b, mods, assume)
						if ok2 then
							local c2, s2 = measure(afterMet)
							if c2 > changed or s2 > score then
								after, changed, score, assumed = afterMet, c2, s2, names
							end
						end
					end
				end
				local deltas = {}
				for _, k in ipairs(show) do
					deltas[k] = { before = base[k] or 0, after = after[k] or 0 }
				end
				local unsupported, requires
				for _, l in ipairs(mods) do
					local r = parseLine(l)
					if not r.supported then unsupported = unsupported or {} unsupported[#unsupported + 1] = l end
					for _, q in ipairs(r.requires or {}) do
						requires = requires or {}
						requires[#requires + 1] = q.desc .. (q.metOnBuild and " (met)" or q.metOnBuild == false and " (not met)" or "")
					end
				end
				rows[#rows + 1] = { src = e.src, name = e.name or e.id, id = e.id, mods = mods, matchedLinesOnly = partial, unsupported = unsupported, requires = requires,
					spawnOn = e.spawnOn, score = score, statsChanged = changed, stats = deltas, assumed = assumed }
			end
		end
	end
	pcall(recalc, b)
	local useGoal = next(goal) ~= nil
	table.sort(rows, function(x, y)
		if useGoal and x.score ~= y.score then return x.score > y.score end
		if (x.assumed == nil) ~= (y.assumed == nil) then return x.assumed == nil end
		if x.statsChanged ~= y.statsChanged then return x.statsChanged > y.statsChanged end
		return x.name < y.name
	end)
	local top, noEffect = {}, 0
	for _, r in ipairs(rows) do
		if useGoal and r.score == 0 then noEffect = noEffect + 1
		elseif #top < (p.top or 25) then top[#top + 1] = r end
	end
	return { candidates = total, evaluated = evaluated, duplicatesSkipped = skipped, timedOut = timedOut, noEffect = noEffect,
		seconds = os.clock() - t0, roll = p.roll or "max", ranked = top,
		note = "Rows with `assumed` only score that way once those conditions hold (flask active, aura on, threshold reached...)." }
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

function methods.probe_batch(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	loadEffects()
	if p.reset then effects = {} queue = nil end
	if not queue then buildQueue() end
	local base = snapshot(b.calcsTab.mainOutput)
	local function deltas(after)
		local d, n = {}, 0
		for k, v in pairs(after) do
			local o = base[k] or 0
			if math.abs(v - o) > 1e-9 then d[k] = v - o n = n + 1 end
		end
		return d, n
	end
	local t0, done = os.clock(), 0
	while qpos <= #queue and os.clock() - t0 < (p.budget or 60) do
		local q = queue[qpos]
		qpos = qpos + 1
		local parsed = parseLine(q.text)
		local fx = { text = q.text }
		if not parsed.supported then
			fx.d, fx.n, fx.unsupported = {}, 0, true
		else
			local ok, after = evalMods(b, { q.text })
			if ok then fx.d, fx.n = deltas(after) else fx.d, fx.n, fx.err = {}, 0, true end
			if #parsed._assume > 0 then
				local okm, afterMet = evalMods(b, { q.text }, parsed._assume)
				if okm then fx.dm, fx.nm = deltas(afterMet) end
				fx.req = {}
				for _, r in ipairs(parsed.requires) do fx.req[#fx.req + 1] = r.desc end
			end
		end
		effects[q.k] = fx
		done = done + 1
		if done % 25 == 0 then collectgarbage() end
	end
	collectgarbage()
	pcall(recalc, b)
	saveEffects()
	return { probed = done, remaining = #queue - qpos + 1, total = #queue, cached = (function() local c = 0 for _ in pairs(effects) do c = c + 1 end return c end)() }
end

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
			local best, via, req, metNow
			local function consider(d, l, r, met)
				if d and ((dir == "up" and d > (p.min or 0)) or (dir == "down" and d < -(p.min or 0))) then
					if not best or math.abs(d) > math.abs(best) or (math.abs(d) == math.abs(best) and not metNow and met) then
						best, via, req, metNow = d, l, r, met
					end
				end
			end
			for _, l in ipairs(e.lines) do
				local fx = effects[normLine(l)]
				if fx then
					consider(fx.d and fx.d[p.stat], l, fx.req, true)
					if p.conditional ~= false and fx.dm then consider(fx.dm[p.stat], l, fx.req, false) end
				end
			end
			if best then
				total = total + 1
				hits[#hits + 1] = { src = e.src, name = e.name or e.id, delta = best, line = via, requires = req,
					requirementsMetOnBuild = req and metNow or nil,
					spawnOn = e.spawnOn, allLines = e.lines, level = e.level, group = e.group }
			end
		end
	end
	local function rankKey(h)
		if not h.requires then return 0 end
		return h.requirementsMetOnBuild and 1 or 2
	end
	table.sort(hits, function(x, y)
		if math.abs(x.delta) ~= math.abs(y.delta) then return math.abs(x.delta) > math.abs(y.delta) end
		return rankKey(x) < rankKey(y)
	end)
	local out = {}
	for i = 1, math.min(#hits, p.limit or 40) do out[i] = hits[i] end
	local by = {}
	for _, h in ipairs(hits) do by[h.src] = (by[h.src] or 0) + 1 end
	return { stat = p.stat, direction = dir, total = total, bySource = by, results = out,
		note = "delta = change in stat when that mod line (max roll) is added to the current build. Hits with `requires` need those conditions: requirementsMetOnBuild=true means they already hold on this build as configured, otherwise the delta assumes them (pass conditional=false to exclude those). Lines PoB can't parse are never found here; use search for those." }
end

function methods.effect_stats(p)
	loadEffects()
	local c, noeff, errs, unsupported, conditional = 0, 0, 0, 0, 0
	local statCounts = {}
	for k, v in pairs(effects) do
		c = c + 1
		if v.unsupported then unsupported = unsupported + 1
		elseif v.n == 0 and (v.nm or 0) == 0 then noeff = noeff + 1 end
		if v.err then errs = errs + 1 end
		if v.dm then conditional = conditional + 1 end
		local moved = {}
		for s in pairs(v.d or {}) do moved[s] = true end
		for s in pairs(v.dm or {}) do moved[s] = true end
		for s in pairs(moved) do statCounts[s] = (statCounts[s] or 0) + 1 end
	end
	return { probed = c, unsupportedByParser = unsupported, conditional = conditional, noEffect = noeff, errors = errs,
		statsMoved = statCounts }
end

-- Chat: the in-app Agent tab queues user messages here; an external agent long-polls chat_wait and answers
-- with chat_reply. State lives on `launch` so it survives `reload` (which swaps this module's upvalues).
local function chat()
	if not launch.agentChat then
		launch.agentChat = { messages = {}, delivered = 0, lastSeen = 0, waiting = 0 }
	end
	return launch.agentChat
end
M.chat = chat

function M.chatSend(text)
	local c = chat()
	c.messages[#c.messages + 1] = { role = "user", text = text, time = os.time() }
end

local function undelivered()
	local c, out = chat(), {}
	for i = c.delivered + 1, #c.messages do
		if c.messages[i].role == "user" then out[#out + 1] = c.messages[i].text end
	end
	return out
end

local function buildName()
	local b = env().build
	return b and b.buildName
end

function methods.chat_wait(p)
	local c = chat()
	c.lastSeen = GetTime()
	local deadline = GetTime() + math.min(tonumber(p.timeout) or 50, 290) * 1000
	return { _defer = function()
		local msgs = undelivered()
		if #msgs == 0 and GetTime() < deadline then return nil end
		c.lastSeen = GetTime()
		c.delivered = #c.messages
		if #msgs == 0 then return { messages = {}, timedOut = true, hint = "No message yet; call chat_wait again." } end
		c.status = "Thinking..."
		return { messages = msgs, build = buildName(), hint = "Answer with chat_reply (use chat_status for progress), then call chat_wait again." }
	end }
end

function methods.chat_reply(p)
	local c = chat()
	if type(p.text) ~= "string" or p.text == "" then return { error = "text required" } end
	c.lastSeen = GetTime()
	c.messages[#c.messages + 1] = { role = "agent", text = p.text, time = os.time() }
	c.delivered = #c.messages
	c.status = nil
	return { ok = true }
end

function methods.chat_status(p)
	local c = chat()
	c.lastSeen = GetTime()
	c.status = (type(p.text) == "string" and p.text ~= "") and p.text or nil
	return { ok = true }
end

function methods.chat_history()
	return { messages = chat().messages, build = buildName() }
end

local function handle(line)
	local req = json.decode(line)
	if type(req) ~= "table" then return { error = "bad json" } end
	local fn = methods[req.method]
	if not fn then return { id = req.id, error = "unknown method: " .. tostring(req.method) } end
	local ok, res = pcall(fn, req.params or {})
	if not ok then return { id = req.id, error = tostring(res) } end
	-- A method can defer its answer: _defer is polled each frame until it returns a result.
	if type(res) == "table" and type(res._defer) == "function" then return { id = req.id, defer = res._defer } end
	return { id = req.id, result = res }
end
M.handle = handle

local server, clients = nil, {}
local keepAlive, lastInput = nil, 0

-- SimpleGraphic skips OnFrame while the window is unfocused and the cursor is elsewhere, unless a
-- coroutine is suspended. Keep one suspended so requests are served in the background.
local function keepAwake()
	if not keepAlive or coroutine.status(keepAlive) == "dead" then
		keepAlive = coroutine.create(function() while true do coroutine.yield() end end)
		coroutine.resume(keepAlive)
	end
end

function M.start()
	-- Must exist before the first frame, or a restart while PoB is in the background never gets one
	keepAwake()
	local socket = require("socket")
	server = socket.tcp4()
	server:setoption("reuseaddr", true)
	local ok, err = server:bind("127.0.0.1", M.port)
	if not ok then ConPrintf("AgentBridge: bind failed: %s", tostring(err)) server = nil return end
	server:listen(4)
	server:settimeout(0)
	for _, name in ipairs({ "OnKeyDown", "OnKeyUp", "OnChar" }) do
		local orig = launch[name]
		launch[name] = function(...) lastInput = GetTime() return orig(...) end
	end
	ConPrintf("AgentBridge listening on 127.0.0.1:%d", M.port)
end

local function userIdle()
	local x, y = GetCursorPos()
	local w, h = GetScreenSize()
	local over = x >= 0 and y >= 0 and x < w and y < h
	return not over and GetTime() - lastInput > 2000
end

function M.poll()
	if not server then return end
	keepAwake()
	local flushing = false
	for _, cl in ipairs(clients) do if #cl.out > 0 then flushing = true end end
	if userIdle() and not flushing then
		-- Block briefly instead of rendering at full rate; wakes immediately on a connection or data.
		local socks = { server }
		for _, cl in ipairs(clients) do socks[#socks + 1] = cl.sock end
		require("socket").select(socks, nil, 0.25)
	end
	local c = server:accept()
	if c then c:settimeout(0) clients[#clients + 1] = { sock = c, buf = "", out = "" } end
	local waiting = 0
	for i = #clients, 1, -1 do
		local cl = clients[i]
		local data_, err, partial = cl.sock:receive(65536)
		local chunk = data_ or partial
		if chunk and #chunk > 0 then cl.buf = cl.buf .. chunk end
		-- Drop closed connections first so a deferred chat_wait can't consume messages for a dead client.
		while err ~= "closed" do
			local resp
			if cl.pending then
				-- Requests on a connection are answered in order, so later lines wait behind a deferred one.
				local ok, res = pcall(cl.pending.defer)
				if not ok then resp = { id = cl.pending.id, error = tostring(res) }
				elseif res ~= nil then resp = { id = cl.pending.id, result = res } end
				if not resp then waiting = waiting + 1 break end
				cl.pending = nil
			else
				local nl = cl.buf:find("\n", 1, true)
				if not nl then break end
				local line = cl.buf:sub(1, nl - 1)
				cl.buf = cl.buf:sub(nl + 1)
				if #line > 0 then
					local ok
					ok, resp = pcall(handle, line)
					if not ok then resp = { error = tostring(resp) } end
					if resp.defer then cl.pending = resp resp = nil end
				end
			end
			if resp then
				local okj, s = pcall(json.encode, resp)
				cl.out = cl.out .. (okj and s or '{"error":"encode failed"}') .. "\n"
			end
		end
		-- Non-blocking send may write only part of a large response; keep the rest for the next frame
		if #cl.out > 0 and err ~= "closed" then
			local sent, serr, lastSent = cl.sock:send(cl.out)
			cl.out = cl.out:sub((sent or lastSent or 0) + 1)
			if serr == "closed" then err = "closed" end
		end
		if err == "closed" then cl.sock:close() table.remove(clients, i) end
	end
	chat().waiting = waiting
end

return M
