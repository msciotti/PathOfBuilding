-- Agent bridge: loopback line-delimited JSON-RPC polled from OnFrame. Read-only data access.
local json = require("dkjson")
local AgentData = LoadModule("AgentData")

local M = { port = tonumber(os.getenv("POB_AGENT_PORT")) or 49090 }
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

-- Dev mode only: run a Lua chunk with `build`, `main`, `data` in scope and return its (JSON-able) result.
function methods.eval(p)
	if not (launch and launch.devMode) then return { error = "eval requires dev mode" } end
	local fn, err = loadstring(p.code or "", "eval")
	if not fn then return { error = err } end
	local e = env()
	setfenv(fn, setmetatable({ build = e.build, main = e.main, data = e.data, json = json }, { __index = _G }))
	local ok, res = pcall(fn)
	if not ok then return { error = tostring(res) } end
	return { value = project(res, tonumber(p.depth) or 6, {}, tonumber(p.maxKeys) or 5000) }
end

function methods.list_sources()
	return { sources = AgentData.listSources(getIndex()) }
end

local function entryOut(e)
	return { src = e.src, id = e.id, name = e.name, kind = e.kind, level = e.level, group = e.group,
		lines = e.lines, tags = e.tags, spawnOn = e.spawnOn, ascendancy = e.ascendancy, essenceSlots = e.essenceSlots,
		obtain = e.obtain, legacy = e.legacy }
end

local passiveStatus

function methods.search(p)
	local res, total, by, terms = AgentData.search(getIndex(), p.query or "", {
		sources = p.sources, slot = p.slot, limit = p.limit or 50, exact = p.exact, includeLegacy = p.includeLegacy })
	local b = env().build
	local out = {}
	for i, e in ipairs(res) do
		out[i] = entryOut(e)
		local status = b and (e.src:find("^passive:") or e.src:find("^cluster:")) and passiveStatus(b, e)
		if status then out[i].allocated, out[i].pathDist = status.allocated, status.pathDist end
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

-- Derived 0/1 stats: an ailment is effectively immune when it can't be applied (avoid chance 100) or it does
-- nothing to you (Self<X>Effect or Self<X>Duration 0, e.g. "Unaffected by Poison"). Lets agents rank
local IMMUNE_AILMENTS = { "Poison", "Bleed", "Ignite", "Chill", "Freeze", "Shock", "Scorch", "Brittle", "Sap" }
local function addDerived(out, t)
	for _, a in ipairs(IMMUNE_AILMENTS) do
		local avoid, effect, duration = out[a .. "AvoidChance"], out["Self" .. a .. "Effect"], out["Self" .. a .. "Duration"]
		if avoid or effect then
			local immune = (tonumber(avoid) or 0) >= 100 or tonumber(effect) == 0 or tonumber(duration) == 0
			t[a .. "ImmuneEffective"] = immune and 1 or 0
		end
	end
	return t
end

local function snapshot(out)
	local t = {}
	for k, v in pairs(out) do
		if type(v) == "number" then t[k] = v
		elseif type(v) == "boolean" then t[k] = v and 1 or 0 end
	end
	return addDerived(out, t)
end

-- Skills whose parts all happen on one use and so add up (skill name -> part indices). Other multi-part skills have
-- alternative parts (one projectile vs all, trap placement...) and report the selected part only.
local COMBINED_PARTS = {
	["Molten Strike"] = { 1, 3 }, -- melee hit + average balls hitting (part 2 is a single ball, an alternative to 3)
	["Molten Strike of the Zenith"] = { 1, 6 }, -- melee hit + weighted average of normal and 5th-attack balls
}

-- CombinedDPS of the main skill summed over its COMBINED_PARTS, for the build as last calculated. The selected
-- part comes from mainOutput; each other part costs one calculation with the part switched, then restored.
local function skillTotal(b)
	local calcs_ = b.calcsTab.calcs
	local out = b.calcsTab.mainOutput
	local skill = b.calcsTab.mainEnv.player.mainSkill
	local effect = skill and skill.activeEffect
	local parts = effect and effect.srcInstance and COMBINED_PARTS[effect.grantedEffect.name]
	if not parts then return out.CombinedDPS or 0 end
	local src = effect.srcInstance
	local selected = src.skillPart
	local total, components = 0, {}
	for _, part in ipairs(parts) do
		local dps = out.CombinedDPS or 0
		if part ~= selected then
			src.skillPart = part
			local ok, res = pcall(function()
				local env_ = calcs_.initEnv(b, "CALCULATOR")
				calcs_.perform(env_)
				return env_.player.output.CombinedDPS or 0
			end)
			src.skillPart = selected
			if not ok then error(res, 0) end
			dps = res
		end
		total = total + dps
		components[#components + 1] = { part = part, name = effect.grantedEffect.parts[part].name, dps = dps }
	end
	return total, components
end

local function currentStats(b)
	local t = snapshot(b.calcsTab.mainOutput)
	local total, components = skillTotal(b)
	t.SkillTotalDPS = total
	return t, components
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

local setupWarnings, unsourcedConfig, addConfigWarnings

function methods.get_state()
	local b = env().build
	if not b then return { error = "no build loaded" } end
	local stats, components = currentStats(b)
	local unsourced = unsourcedConfig(b, stats)
	local warnings, feasible = setupWarnings(b, stats)
	addConfigWarnings(warnings, unsourced)
	return {
		class = b.spec and b.spec.curClassName, ascendancy = b.spec and b.spec.curAscendClassName,
		level = b.characterLevel, mainSkill = mainSkillInfo(b),
		dpsHint = "Use SkillTotalDPS as the DPS goal: it adds up the parts of a multi-part skill that happen on one use (Molten Strike) and equals CombinedDPS otherwise. CombinedDPS is only the selected skill part; TotalDPS is hits only. FullDPS is only set when skills are marked for Full DPS; PoisonDPS/BleedDPS are per stack, so use WithPoisonDPS/WithBleedDPS or CombinedDPS.",
		skillTotal = { combined = components ~= nil, components = components },
		warnings = warnings, feasible = feasible, unsourcedConfig = unsourced,
		stats = stats,
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
	for k, v in pairs((currentStats(b))) do
		if not q or k:lower():find(q, 1, true) or (labels[k] or ""):lower():find(q, 1, true) then
			out[#out + 1] = { stat = k, label = labels[k], value = v }
		end
	end
	table.sort(out, function(a, b) return a.stat < b.stat end)
	return { count = #out, stats = out, note = "Boolean outputs are shown as 0/1. <Ailment>ImmuneEffective (agent-derived) is 1 when the ailment can't be applied (AvoidChance 100) or does nothing to you (Self<Ailment>Effect/Duration 0, e.g. Unaffected by Poison). Values are for the build as configured." }
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
		elseif m.configOff and configSaved[m.configOff] == nil then
			configSaved[m.configOff] = input[m.configOff] or false
			input[m.configOff] = nil
		end
	end
	b.configTab:BuildModList()
	for var, old in pairs(configSaved) do input[var] = old or nil end
	local flaskSlots = {}
	for _, m in ipairs(extra or {}) do
		if m.config or m.configOff then
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
	local components
	if ok then
		local okT, total, comps = pcall(skillTotal, b)
		if okT then after.SkillTotalDPS, components = total, comps else ok, after = false, total end
	end
	return ok, after, totals, components
end

local function partsDiff(before, after)
	if not (before and after) then return nil end
	local parts = { combined = true, components = {} }
	for i, c in ipairs(before) do
		parts.components[i] = { part = c.part, name = c.name, before = c.dps, after = after[i].dps }
	end
	return parts
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

local function assumedBaseline(b, assume)
	local only = {}
	for _, m in ipairs(assume) do
		if not m.raw then only[#only + 1] = m end
	end
	return evalMods(b, {}, only)
end

local function assumedNames(assume)
	local names = {}
	for _, m in ipairs(assume) do
		names[#names + 1] = m.config and ("Config: " .. m.label) or m.raw and ("socketed in " .. tostring(m.raw[1] and m.raw[1].slotName or "slot")) or m.flasks and "equipped flasks active" or m.clear and ("not " .. m.clear)
			or (m.name .. (m.type == "BASE" and (" = " .. m.value) or ""))
	end
	return names
end

local function chargeSource(charge)
	return {
		text = { "gain[^%.]-" .. charge .. "[%a, ]-charge", "steal[^%.]-" .. charge .. "[%a, ]-charge" },
		notText = { "per ", "cannot gain", "when you gain", "would gain", "instead gain", "minion", "enemies", "while you have" },
		gemStat = { "gain_" .. charge .. "_charge", "grant_" .. charge .. "_charge", "add_" .. charge .. "_charge", "grants_x_additional_" .. charge .. "_charge" },
	}
end

local function ailmentSource(ailment)
	return {
		text = { "chance to " .. ailment, ailment .. " enem", "always " .. ailment, "inflicts? " .. ailment, "can " .. ailment },
		notText = { "cannot", "avoid" },
		gemStat = { "chance_to_" .. ailment, "always_" .. ailment },
	}
end

-- Config options that only mean something when the build can produce the effect. `text` and `notText` are Lua
-- patterns on the lowercased mod lines of equipped items and allocated nodes (masteries included), `gems` are gem
-- names and `gemStat` patterns on stat ids of the socketed gems. `flags` are the skill flags PoB itself sets for such
-- a source (the same test the Config tab uses to show an option),
-- `skillTypes` and `skillsFromOption` (the option's own ifSkill list) match active skills.
local CONFIG_SOURCES = {
	buffFortification = { text = { "fortify%f[%A]", "gain %d+ fortification", "you have your maximum fortification" },
		notText = { "while you have fortify", "while fortified", "kill" }, gems = { "Fortify", "Vigilant Strike" } },
	useEnduranceCharges = chargeSource("endurance"),
	useFrenzyCharges = chargeSource("frenzy"),
	usePowerCharges = chargeSource("power"),
	buffOnslaught = { text = { "gain[^%.]-onslaught", "grants? onslaught", "you have onslaught" },
		notText = { "minion", "effect of onslaught", "while you have onslaught", "during onslaught" }, gems = { "Manifest Dancing Dervishes" } },
	multiplierRage = { flags = { "Condition:CanGainRage" } },
	bloodSandStance = { skillsFromOption = true },
	conditionEnemyShocked = ailmentSource("shock"),
	conditionEnemyChilled = ailmentSource("chill"),
	conditionEnemyIgnited = ailmentSource("ignite"),
	conditionEnemyIntimidated = { text = { "intimidate enem", "are intimidated", "chance to intimidate" },
		gems = { "Intimidating Cry" }, gemStat = { "chance_to_intimidate" } },
	conditionEnemyUnnerved = { text = { "unnerve enem", "are unnerved", "chance to unnerve" }, gemStat = { "chance_to_unnerve" } },
	conditionEnemyCoveredInAsh = { text = { "in ash" }, gemStat = { "cover_in_ash" } },
	conditionEnemyFireExposure = { flags = { "applyFireExposure" } },
	conditionEnemyColdExposure = { flags = { "applyColdExposure" } },
	conditionEnemyLightningExposure = { flags = { "applyLightningExposure" } },
	buffElusive = { flags = { "Condition:CanBeElusive" } },
	buffTailwind = { text = { "gain tailwind", "grants? tailwind", "have tailwind" }, notText = { "while you have tailwind", "effect of tailwind" } },
	buffAdrenaline = { text = { "gain adrenaline", "grants? adrenaline", "have adrenaline" },
		notText = { "when you gain adrenaline", "while you have" }, gems = { "Fresh Meat" } },
	buffArcaneSurge = { text = { "gain arcane surge", "grants? arcane surge", "have arcane surge" },
		notText = { "while you have", "arcane surge also" }, gems = { "Arcane Surge" } },
	buffPhasing = { text = { "gain phasing", "grants? phasing", "you have phasing" }, notText = { "while you have phasing" }, gems = { "Phase Run" } },
	buffUnholyMight = { text = { "gain unholy might", "grants? unholy might", "have unholy might" }, notText = { "minion" } },
	conditionEnemyCursed = { text = { "curse enem" }, gems = { "Hextouch" }, skillTypes = { "Hex", "Mark", "AppliesCurse" } },
}

local function anyFind(patterns, s)
	for _, pat in ipairs(patterns or {}) do
		if s:find(pat) then return true end
	end
	return false
end

-- What the build provides: mod lines of equipped items and allocated nodes (and any hypothetical `lines`), plus gem
-- names and stat ids.
local function buildSources(b, lines)
	local env_ = b.calcsTab.mainEnv
	local src = { lines = {}, gems = {}, stats = {} }
	for _, line in ipairs(lines or {}) do src.lines[#src.lines + 1] = StripEscapes(line):lower() end
	for _, item in pairs(env_.player.itemList) do
		for key, list in pairs(item) do
			if type(key) == "string" and key:match("ModLines$") then
				for _, modLine in ipairs(list) do
					if item:CheckModLineVariant(modLine) then src.lines[#src.lines + 1] = StripEscapes(modLine.line):lower() end
				end
			end
		end
	end
	for _, node in pairs(env_.allocNodes) do
		for _, line in ipairs(node.sd or {}) do src.lines[#src.lines + 1] = StripEscapes(line):lower() end
	end
	local function addGem(effect)
		local ge = effect.grantedEffect
		src.gems[ge.name] = true
		for _, id in ipairs(ge.stats or {}) do src.stats[#src.stats + 1] = id end
		for _, stat in ipairs(ge.constantStats or {}) do src.stats[#src.stats + 1] = stat[1] end
	end
	for _, skill in ipairs(env_.player.activeSkillList) do
		addGem(skill.activeEffect)
		for _, support in ipairs(skill.supportList or {}) do addGem(support) end
	end
	return src
end

local function hasSource(b, opt, def, have)
	local env_ = b.calcsTab.mainEnv
	local main = env_.player.mainSkill
	for _, line in ipairs(have.lines) do
		if anyFind(def.text, line) and not anyFind(def.notText, line) then return true end
	end
	for _, name in ipairs(def.gems or {}) do
		if have.gems[name] then return true end
	end
	for _, id in ipairs(have.stats) do
		if anyFind(def.gemStat, id) then return true end
	end
	for _, flag in ipairs(def.flags or {}) do
		if main.skillFlags[flag] or main.skillModList:Flag(nil, flag) then return true end
	end
	for _, name in ipairs(def.skillsFromOption and opt.ifSkill or {}) do
		if env_.skillsUsed[name] then return true end
	end
	for _, skill in ipairs(env_.player.activeSkillList) do
		for _, typeName in ipairs(def.skillTypes or {}) do
			if skill.skillTypes[SkillType[typeName]] then return true end
		end
	end
	return false
end

-- Config options that are switched on while nothing in the build provides them, with DPS and EHP as if each were
-- off. `on` is the stats of the state being checked; `lines`/`extra` re-create that state for each recalculation.
function unsourcedConfig(b, on, lines, extra)
	local input = b.configTab.configSets[b.configTab.activeConfigSetId].input
	local have
	local out = {}
	for _, opt in ipairs(configOptions()) do
		local def = opt.var and CONFIG_SOURCES[opt.var]
		local value = input[opt.var]
		if def and value and value ~= 0 then
			have = have or buildSources(b, lines)
			if not hasSource(b, opt, def, have) then
				local entries = {}
				for i, m in ipairs(extra or {}) do entries[i] = m end
				entries[#entries + 1] = { configOff = opt.var }
				local ok, after = evalMods(b, lines or {}, entries)
				out[#out + 1] = { option = StripEscapes(opt.label):gsub(":$", ""), var = opt.var,
					dps = on.SkillTotalDPS, dpsOff = ok and after.SkillTotalDPS or nil,
					ehp = on.TotalEHP, ehpOff = ok and after.TotalEHP or nil }
			end
		end
	end
	if #out > 0 then pcall(recalc, b) end
	return out
end

function addConfigWarnings(warnings, unsourced)
	for _, u in ipairs(unsourced) do
		warnings[#warnings + 1] = string.format("Config option '%s' is on but nothing in the build provides it", u.option)
	end
end

-- Costs the main skill can't pay: mana (energy shield included where it pays for mana) and life.
local function unpayable(stats)
	local out = {}
	if (stats.ManaCost or 0) > (stats.ManaCostPayablePool or stats.ManaUnreserved or 0) then
		out[#out + 1] = string.format("The main skill costs %d Mana per use but only %d Mana is unreserved", stats.ManaCost, stats.ManaCostPayablePool or stats.ManaUnreserved or 0)
	end
	if (stats.LifeCost or 0) > (stats.LifeUnreserved or 0) then
		out[#out + 1] = string.format("The main skill costs %d Life per use but only %d Life is unreserved", stats.LifeCost, stats.LifeUnreserved or 0)
	end
	return out
end

-- PoB's own sidebar warnings for the state as last calculated (refreshing the sidebar), then ours.
function setupWarnings(b, stats)
	b:RefreshStatList()
	local warnings = {}
	for _, line in ipairs(b.controls.warnings.lines) do warnings[#warnings + 1] = StripEscapes(line) end
	local costs = unpayable(stats)
	for _, line in ipairs(costs) do warnings[#warnings + 1] = line end
	return warnings, #costs == 0
end

function methods.what_if(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	local base, baseComponents = currentStats(b)
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
	local ok, after, totalsAfter, afterComponents = evalMods(b, lines, socketedMods, names)
	local warnings, feasible
	if ok then warnings, feasible = setupWarnings(b, after) end
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
		-- Measure against the build with the same assumptions but without these mods, so forcing a condition
		-- (e.g. activating the equipped flasks) isn't credited to the mod being tested
		local okB, baseMet = assumedBaseline(b, assume)
		if ok3 and okB then
			met = { assumed = assumedNames(assume), cannotForce = #unmet > 0 and unmet or nil, changed = diffStats(baseMet, afterMet, want),
				note = "before = the build with the assumptions applied but without these mods" }
			local fromAssume = diffStats(base, baseMet, want)
			if next(met.changed) == nil and next(fromAssume) ~= nil then
				met.alreadyFromAssumptions = fromAssume
				met.note = met.note .. "; the assumptions by themselves already change alreadyFromAssumptions (e.g. an equipped flask that has this effect)"
			end
		end
	end
	local ok2 = pcall(recalc, b)
	b:RefreshStatList()
	if not ok then return { error = tostring(after) } end
	local unsourced = unsourcedConfig(b, after, lines, socketedMods)
	addConfigWarnings(warnings, unsourced)

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
	local totalParts = partsDiff(baseComponents, afterComponents)
	return { applied = lines, changed = diff, warnings = warnings, feasible = feasible, unsourcedConfig = unsourced, skillTotal = totalParts, current = current, requires = #reqs > 0 and reqs or nil,
		ifConditionsMet = met, modTotals = totals, socketedAppliedTo = #socketedInfo > 0 and socketedInfo or nil, changedOther = changedOther, capped = #capped > 0 and capped or nil, unsupported = #unsupported > 0 and unsupported or nil, restored = ok2, note = note }
end

function passiveStatus(b, e)
	local spec = b.spec
	if e.src == "passive:mastery" then
		local effect = tonumber(e.id)
		for _, sel in pairs(spec.masterySelections or {}) do
			if sel == effect then return { allocated = true } end
		end
		local best
		for _, node in pairs(spec.nodes) do
			if not node.alloc and node.type == "Mastery" and node.pathDist and node.pathDist < 1000 then
				for _, fx in ipairs(node.masteryEffects or {}) do
					if fx.effect == effect and (not best or node.pathDist < best) then best = node.pathDist end
				end
			end
		end
		return { allocated = false, pathDist = best }
	elseif e.src:find("^passive:") then
		local node = spec.nodes[tonumber(e.id)]
		if not node then return nil end
		return { allocated = node.alloc and true or false, pathDist = not node.alloc and node.pathDist < 1000 and node.pathDist or nil }
	elseif e.src == "cluster:notable" or e.src == "cluster:keystone" then
		for _, node in pairs(spec.allocNodes) do
			if node.dn == e.name then return { allocated = true } end
		end
		return { allocated = false }
	end
end

function methods.path_cost(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	local spec = b.spec
	local targets, unknown = {}, {}
	for _, want in ipairs(p.nodes or {}) do
		local group = {}
		local id = tonumber(want)
		if id and spec.nodes[id] then
			group[1] = spec.nodes[id]
		else
			for _, node in pairs(spec.nodes) do
				if node.dn and node.dn:lower() == tostring(want):lower() then group[#group + 1] = node end
			end
		end
		if #group == 0 then unknown[#unknown + 1] = want else targets[#targets + 1] = { want = want, nodes = group } end
	end
	local taken = {}
	for id, node in pairs(spec.allocNodes) do taken[node] = true end
	local total, steps = 0, {}
	while #targets > 0 do
		local dist, parent, queue, qs = {}, {}, {}, 1
		for node in pairs(taken) do dist[node] = 0 queue[#queue + 1] = node end
		while qs <= #queue do
			local node = queue[qs]
			qs = qs + 1
			for _, other in ipairs(node.linked or {}) do
				local w = taken[other] and 0 or 1
				local d = dist[node] + w
				local canTraverse = node.type ~= "Mastery" and other.type ~= "ClassStart" and other.type ~= "AscendClassStart"
					and (node.ascendancyName == other.ascendancyName or (dist[node] == 0 and not other.ascendancyName))
				if canTraverse and d < (dist[other] or math.huge) then
					dist[other], parent[other] = d, node
					if w == 0 then qs = qs - 1 queue[qs] = other else queue[#queue + 1] = other end
				end
			end
		end
		local bestT, bestNode, bestI
		for i, t in ipairs(targets) do
			for _, node in ipairs(t.nodes) do
				if dist[node] and (not bestNode or dist[node] < dist[bestNode]) then bestT, bestNode, bestI = t, node, i end
			end
		end
		if not bestNode then
			for _, t in ipairs(targets) do unknown[#unknown + 1] = tostring(t.want) .. " (unreachable)" end
			break
		end
		local path, node = {}, bestNode
		while node and not taken[node] do
			table.insert(path, 1, node.dn or tostring(node.id))
			taken[node] = true
			node = parent[node]
		end
		total = total + #path
		steps[#steps + 1] = { target = bestT.want, id = bestNode.id, points = #path, path = path }
		table.remove(targets, bestI)
	end
	return { points = total, steps = steps, notFound = #unknown > 0 and unknown or nil,
		note = "Greedy over the targets: an exact optimum can occasionally be a point or two lower. Cluster jewel nodes only count if their jewel is socketed." }
end

function methods.rank_options(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	local res, total, _, terms = AgentData.search(getIndex(), p.query or "", {
		sources = p.sources, slot = p.slot, limit = 100000, exact = p.exact, includeLegacy = p.includeLegacy })
	local goal = {}
	if type(p.goal) == "string" then goal[p.goal] = 1
	elseif type(p.goal) == "table" then for k, w in pairs(p.goal) do goal[k] = w end end
	local show = {}
	for k in pairs(goal) do show[#show + 1] = k end
	for _, k in ipairs(p.stats or {}) do show[#show + 1] = k end

	local base = currentStats(b)
	local unsourced = unsourcedConfig(b, base)
	local warnings, feasible = setupWarnings(b, base)
	addConfigWarnings(warnings, unsourced)
	local infeasible, infeasibleCount = {}, 0
	local bestLvl = {}
	for _, e in ipairs(res) do
		if e.group then
			local k = e.src .. "|" .. e.group
			if (bestLvl[k] or -1) < (e.level or 0) then bestLvl[k] = e.level or 0 end
		end
	end
	local function measure(after, from)
		from = from or base
		local changed, score = 0, 0
		for k, v in pairs(after) do
			if math.abs(v - (from[k] or 0)) > 1e-9 then changed = changed + 1 end
		end
		for k, w in pairs(goal) do
			local o, v = from[k] or 0, after[k] or 0
			-- (after-before)/max(|before|,|after|): one bounded scale (-1..1) even when before is 0
			local d = math.max(math.abs(o), math.abs(v))
			if d > 0 and v == v and o == o and d ~= math.huge then score = score + w * (v - o) / d end
		end
		return changed, score
	end
	local baselines, fromAssumptionsAlone = {}, {}
	local function baselineFor(names, assume, via)
		local key = table.concat(names, "|")
		if baselines[key] == nil then
			local ok, snap = assumedBaseline(b, assume)
			baselines[key] = ok and snap or false
			if ok and next(goal) then
				local _, s0 = measure(snap)
				if s0 > 0 then
					fromAssumptionsAlone[#fromAssumptionsAlone + 1] = { assumed = names, score = s0, via = via }
				end
			end
		end
		return baselines[key] or nil
	end
	local seen, rows, skipped, allocatedSkipped = {}, {}, 0, {}
	local t0, budget, cap = os.clock(), p.budget or 120, p.max or 500
	local evaluated, timedOut = 0, false
	for _, e in ipairs(res) do
		if evaluated >= cap then break end
		if os.clock() - t0 > budget then timedOut = true break end
		local mods, partial = {}, nil
		local status = (e.src:find("^passive:") or e.src:find("^cluster:")) and passiveStatus(b, e) or nil
		if e.group and (e.level or 0) < (bestLvl[e.src .. "|" .. e.group] or 0) and (p.roll or "max") == "max" then
			skipped = skipped + 1
		elseif status and status.allocated and e.src:find("^passive:") then
			-- Already on the tree: adding it again would double-count it. Its conditions still matter: an allocated
			-- node waiting on a Config toggle (e.g. "if you've used a Retaliation Skill Recently") shows in alreadyOnBuildIf
			allocatedSkipped[#allocatedSkipped + 1] = e.name or e.id
			if p.assume ~= false then
				local assume, names, seenName = {}, {}, {}
				for _, l in ipairs(e.lines) do
					for _, m in ipairs(parseLine(resolveRanges(l, p.roll or "max"))._assume) do
						local name = assumedNames({ m })[1]
						if not seenName[name] then
							seenName[name] = true
							assume[#assume + 1] = m
							names[#names + 1] = name
						end
					end
				end
				if #assume > 0 then baselineFor(names, assume, e.name) end
			end
		else
			-- Uniques carry every variant's lines; score only the lines that match the query
			local lines = e.lines
			if e.src:find("^unique") and #lines > 3 then
				lines, partial = AgentData.matchedLines(e, terms), true
			end
			for _, l in ipairs(lines) do mods[#mods + 1] = resolveRanges(l, p.roll or "max") end
		end
		local text = table.concat(mods, "\n")
		if #mods == 0 then skipped = skipped + 1
		elseif seen[text] then
			-- Same mod text from another source (e.g. a unique's line that also exists as a vestigial or explicit
			-- mod): score once, but list every source on that row
			skipped = skipped + 1
			local also = seen[text]
			also[#also + 1] = { src = e.src, name = e.name or e.id, spawnOn = e.spawnOn }
		else
			seen[text] = {}
			evaluated = evaluated + 1
			local ok, after, _, components = evalMods(b, mods)
			if ok then
				local changed, score = measure(after)
				local rowBase
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
						local ok2, afterMet, _, componentsMet = evalMods(b, mods, assume)
						local from = baselineFor(names, assume)
						if ok2 and from then
							local c2, s2 = measure(afterMet, from)
							if c2 > changed or s2 > score then
								after, changed, score, assumed, rowBase, components = afterMet, c2, s2, names, from, componentsMet
							end
						end
					end
				end
				local deltas = {}
				for _, k in ipairs(show) do
					deltas[k] = { before = (rowBase or base)[k] or 0, after = after[k] or 0 }
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
				local problems = unpayable(after)
				if #problems == 0 then
					rows[#rows + 1] = { src = e.src, name = e.name or e.id, id = e.id, mods = mods, matchedLinesOnly = partial, unsupported = unsupported, requires = requires,
						spawnOn = e.spawnOn, score = score, statsChanged = changed, stats = deltas, skillParts = components, assumed = assumed,
						alsoFrom = seen[text], obtain = e.obtain, pathDist = status and status.pathDist,
						alreadyOnBuild = status and status.allocated or nil }
				elseif changed > 0 then
					infeasibleCount = infeasibleCount + 1
					if #infeasible < 10 then infeasible[#infeasible + 1] = { src = e.src, name = e.name or e.id, warnings = problems } end
				end
			end
		end
	end
	pcall(recalc, b)
	b:RefreshStatList()
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
		warnings = warnings, feasible = feasible, unsourcedConfig = unsourced,
		infeasible = infeasibleCount > 0 and { count = infeasibleCount, examples = infeasible } or nil,
		alreadyOnBuildIf = #fromAssumptionsAlone > 0 and fromAssumptionsAlone or nil,
		alreadyAllocated = #allocatedSkipped > 0 and allocatedSkipped or nil,
		note = "Rows with `assumed` only score that way once those conditions hold (flask active, aura on, threshold reached...). "
			.. "Passive rows carry pathDist (points from the current tree); use path_cost for several nodes together. "
			.. "Passives already allocated are left out (alreadyAllocated); legacy mods that no longer roll are left out unless includeLegacy." }
end

-- Index key: the line at its max roll. Exact text, not the number-stripped shape, so "100% chance to Avoid being
-- Frozen" and "(21-25)% chance to Avoid being Frozen" each get their own probed delta.
local function normLine(l)
	return (resolveRanges(l, "max"):gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local CACHE = "agent_effects.json"
local EFFECTS_VERSION = 3 -- bump when the key or probe logic changes; older caches are discarded
local effects, queue, qpos  -- effects[normLine] = { text=probedText, d={stat=delta}, n=changedCount }

local function loadEffects()
	if effects then return end
	effects = {}
	local f = io.open(CACHE, "r")
	if f then
		local ok, t = pcall(json.decode, f:read("*a"))
		f:close()
		if ok and type(t) == "table" and t._version == EFFECTS_VERSION then effects = t end
	end
end

local function saveEffects()
	local f = io.open(CACHE, "w")
	effects._version = EFFECTS_VERSION
	if f then f:write(json.encode(effects)) f:close() end
end

local function buildQueue()
	queue, qpos = {}, 1
	local seen = {}
	for _, e in ipairs(getIndex().list) do
		if not e.src:find("^gem") then
			for _, l in ipairs(e.lines) do
				local k = normLine(l)
				if not seen[k] and not effects[k] and #l > 3 then
					seen[k] = true
					queue[#queue + 1] = { k = k, text = k }
				end
			end
		end
	end
end

function methods.probe_batch(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	loadEffects()
	if p.reset then effects = { _version = EFFECTS_VERSION } queue = nil end
	if not queue then buildQueue() end
	local base = snapshot(b.calcsTab.mainOutput)
	local probeBaselines = {}
	local function deltas(after, from)
		local d, n = {}, 0
		for k, v in pairs(after) do
			local o = (from or base)[k] or 0
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
				local key = table.concat(assumedNames(parsed._assume), "|")
				if probeBaselines[key] == nil then
					local okB, snap = assumedBaseline(b, parsed._assume)
					probeBaselines[key] = okB and snap or false
				end
				if okm and probeBaselines[key] then fx.dm, fx.nm = deltas(afterMet, probeBaselines[key]) end
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
		local ok = p.includeLegacy or not e.legacy
		if ok and p.sources then
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
					spawnOn = e.spawnOn, allLines = e.lines, level = e.level, group = e.group, obtain = e.obtain }
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
		if type(v) ~= "table" then goto continue end
		c = c + 1
		if v.unsupported then unsupported = unsupported + 1
		elseif v.n == 0 and (v.nm or 0) == 0 then noeff = noeff + 1 end
		if v.err then errs = errs + 1 end
		if v.dm then conditional = conditional + 1 end
		local moved = {}
		for s in pairs(v.d or {}) do moved[s] = true end
		for s in pairs(v.dm or {}) do moved[s] = true end
		for s in pairs(moved) do statCounts[s] = (statCounts[s] or 0) + 1 end
		::continue::
	end
	return { probed = c, unsupportedByParser = unsupported, conditional = conditional, noEffect = noeff, errors = errs,
		statsMoved = statCounts }
end

function methods.gem_what_if(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	local group = b.skillsTab.socketGroupList[p.group or b.mainSocketGroup]
	if not group then return { error = "no such socket group" } end
	local base, baseComponents = currentStats(b)
	local want
	if p.stats then want = {} for _, k in ipairs(p.stats) do want[k] = true end end
	local original, saved, used = {}, {}, {}
	for i, g in ipairs(group.gemList) do
		original[i] = g
		saved[g] = { level = g.level, quality = g.quality }
	end
	local function restore()
		group.gemList = {}
		for i, g in ipairs(original) do
			group.gemList[i] = g
			g.level, g.quality = saved[g].level, saved[g].quality
		end
		b.skillsTab:ProcessSocketGroup(group)
	end
	local function find(name)
		for i, g in ipairs(group.gemList) do
			if g.nameSpec:lower() == name:lower() then return g, i end
		end
	end
	for _, c in ipairs(p.gems or {}) do
		local gem, at = find(c.name)
		local was = gem and { level = gem.level, quality = gem.quality }
		local action = gem and "set" or "added"
		local replaced
		if c.replace then
			local old, oldAt = find(c.replace)
			if not old then
				restore()
				return { error = c.replace .. " is not in the socket group" }
			end
			replaced = old.nameSpec
			gem = { nameSpec = c.name, enabled = old.enabled, enableGlobal1 = true, enableGlobal2 = true, count = 1, qualityId = "Default" }
			group.gemList[oldAt] = gem
			was, action = nil, "replaced"
		elseif not gem then
			gem = { nameSpec = c.name, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, qualityId = "Default" }
			table.insert(group.gemList, gem)
		end
		gem.level, gem.quality = c.level or 1, c.quality or 20
		used[#used + 1] = { gem = gem, was = was, action = action, replaced = replaced }
		b.skillsTab:ProcessSocketGroup(group)
		if gem.errMsg then
			local err = gem.errMsg
			restore()
			return { error = c.name .. ": " .. err }
		end
		if not c.level then
			gem.level = gem.gemData.naturalMaxLevel
			b.skillsTab:ProcessSocketGroup(group)
		end
	end
	local ok, after, _, components = evalMods(b, {})
	local gems = {}
	for _, u in ipairs(used) do
		local max = u.gem.gemData.naturalMaxLevel
		gems[#gems + 1] = { name = u.gem.nameSpec, action = u.action, replaced = u.replaced, level = u.gem.level, quality = u.gem.quality,
			naturalMaxLevel = max, needsCorruption = (u.gem.level > max or u.gem.quality > 20) or nil, was = u.was }
	end
	restore()
	local restored = pcall(recalc, b)
	if not ok then return { error = tostring(after) } end
	return { gems = gems, changed = diffStats(base, after, want), skillTotal = partsDiff(baseComponents, components), restored = restored }
end

function methods.import_character(p)
	local main = env().main
	if not main then return { error = "PoB not ready" } end
	if type(p.account) ~= "string" or type(p.character) ~= "string" then return { error = "account and character required" } end
	local realm = p.realm or "pc"
	local host = "https://www.pathofexile.com/character-window/"
	local acct = p.account:gsub("#", "%%23")
	local name = p.name or (p.account:gsub("#%d+$", "") .. " - " .. p.character)
	local fetched, err = {}, nil
	local function fetch(key, url)
		launch:DownloadPage(url, function(response, errMsg)
			if errMsg then err = key .. ": " .. errMsg
			elseif not response.body or response.body == "false" then err = key .. ": no data (profile private or character not found?)"
			else fetched[key] = json.decode(response.body) end
		end)
	end
	fetch("list", host .. "get-characters?accountName=" .. acct .. "&realm=" .. realm)
	fetch("passives", host .. "get-passive-skills?accountName=" .. acct .. "&character=" .. urlEncode(p.character) .. "&realm=" .. realm)
	fetch("items", host .. "get-items?accountName=" .. acct .. "&character=" .. urlEncode(p.character) .. "&realm=" .. realm)
	local oldImportTab = env().build and env().build.importTab
	local deadline = GetTime() + 60000
	local switched = false
	return { _defer = function()
		if err then return { error = err } end
		if GetTime() > deadline then return { error = "timed out" } end
		if not (fetched.list and fetched.passives and fetched.items) then return nil end
		local charInfo
		for _, c in ipairs(fetched.list) do
			if c.name == p.character then charInfo = c end
		end
		if not charInfo then return { error = "character not found on account" } end
		if not switched then
			main:SetMode("BUILD", false, "Unnamed build")
			switched = true
			return nil
		end
		local b = env().build
		if main.newMode or not b or b.importTab == oldImportTab then return nil end
		local tab = b.importTab
		-- Account-name imports omit quest choices, so keep the new build's defaults (as the Import tab does)
		local passives = fetched.passives
		passives.bandit_choice = passives.bandit_choice or b.configTab.input.bandit
		passives.pantheon_major = passives.pantheon_major or b.configTab.input.pantheonMajorGod
		passives.pantheon_minor = passives.pantheon_minor or b.configTab.input.pantheonMinorGod
		local charData = copyTable(charInfo)
		charData.passives = passives
		charData.jewels = fetched.passives.items
		tab:ImportPassiveTreeAndJewels(charData, true)
		local itemData = copyTable(charInfo)
		itemData.equipment = fetched.items.items
		itemData.guardian = fetched.items.guardian
		tab:ImportItemsAndSkills(itemData, true, true, false)
		b.buildName = name
		b.dbFileName = main.buildPath .. name:gsub("[\\/:%*%?\"<>|%c]", "-") .. ".xml"
		b:SaveDBFile()
		b.spec:SetWindowTitleWithBuildClass()
		return { imported = true, file = b.dbFileName, class = charInfo.class, league = charInfo.league, level = charInfo.level }
	end }
end

local VARIANT_STATS = { "SkillTotalDPS", "TotalEHP", "Life", "LifeUnreserved", "ManaUnreserved", "FireResist", "ColdResist",
	"LightningResist", "ChaosResist", "PhysicalMaximumHitTaken", "FireMaximumHitTaken", "ColdMaximumHitTaken",
	"LightningMaximumHitTaken", "ChaosMaximumHitTaken" }
local MAX_VARIANTS = 40

local function findNodes(spec, want)
	local id = tonumber(want)
	if id then return { spec.nodes[id] } end
	local found = {}
	for _, n in pairs(spec.nodes) do
		if n.dn and n.dn:lower() == tostring(want):lower() and not n.isProxy and n.group then found[#found + 1] = n end
	end
	return found
end

-- Without a level the gem gets its natural max level once processGroup has looked it up.
local function newGem(spec, level, quality)
	local name, lvl, q = tostring(spec):match("^([^:]+):?(%d*):?(%d*)$")
	local explicit = tonumber(lvl) or level
	return { nameSpec = name, level = explicit or 1, quality = tonumber(q) or quality or 20, enabled = true,
		enableGlobal1 = true, enableGlobal2 = true, count = 1, qualityId = "Default" }, not explicit
end

-- `touched` lists the new gems ({ gem, auto }); processGroup fills in their levels and reports what was used.
local function processGroup(b, group, touched, used)
	b.skillsTab:ProcessSocketGroup(group)
	for _, t in ipairs(touched) do
		if t.gem.errMsg then error(t.gem.nameSpec .. ": " .. t.gem.errMsg, 0) end
		if t.auto and t.gem.gemData then t.gem.level = t.gem.gemData.naturalMaxLevel end
	end
	b.skillsTab:ProcessSocketGroup(group)
	for _, t in ipairs(touched) do
		local max = t.gem.gemData and t.gem.gemData.naturalMaxLevel
		used[#used + 1] = { name = t.gem.nameSpec, level = t.gem.level, quality = t.gem.quality,
			needsCorruption = max and t.gem.level > max or nil }
	end
end

local function socketGroup(b, n)
	local group = b.skillsTab.socketGroupList[tonumber(n) or 0]
	if not group then error("no socket group " .. tostring(n), 0) end
	return group
end

-- Applies one change to the build and pushes its undo onto `undo`; mod lines go to `lines` for evalMods.
local function applyChange(b, change, undo, lines, unsupported, roll, used)
	local items, spec = b.itemsTab, b.spec
	local function saveTree()
		if not undo.tree then
			local state = spec:CreateUndoState()
			undo.tree = true
			undo[#undo + 1] = function() spec:RestoreUndoState(state) end
		end
	end
	if change.equip then
		local slot = items.slots[change.equip.slot]
		if not slot then error("unknown slot " .. tostring(change.equip.slot), 0) end
		local item = new("Item"):Item(tostring(change.equip.item))
		if not item.base then error("unknown item base in the item text", 0) end
		if not items:IsItemValidForSlot(item, slot.slotName) then error(item.baseName .. " can't go in " .. slot.slotName, 0) end
		items:AddItem(item, true)
		local prev = slot.selItemId
		undo[#undo + 1] = function()
			slot:SetSelItemId(prev)
			items:DeleteItem(item, true)
			items:PopulateSlots()
		end
		slot:SetSelItemId(item.id)
		items:PopulateSlots()
	elseif change.unequip then
		local slot = items.slots[change.unequip]
		if not slot then error("unknown slot " .. tostring(change.unequip), 0) end
		local prev = slot.selItemId
		undo[#undo + 1] = function() slot:SetSelItemId(prev) items:PopulateSlots() end
		slot:SetSelItemId(0)
		items:PopulateSlots()
	elseif change.gems then
		local group = socketGroup(b, change.gems.group)
		local prev = group.gemList
		undo[#undo + 1] = function() group.gemList = prev end
		group.gemList = {}
		local touched = {}
		for _, g in ipairs(change.gems.gems or {}) do
			local gem, auto = newGem(g)
			group.gemList[#group.gemList + 1] = gem
			touched[#touched + 1] = { gem = gem, auto = auto }
		end
		processGroup(b, group, touched, used)
	elseif change.swapGem then
		local c = change.swapGem
		local group = socketGroup(b, c.group)
		local prev = group.gemList
		undo[#undo + 1] = function() group.gemList = prev end
		local at
		for i, gem in ipairs(prev) do
			if c.from and gem.nameSpec:lower() == tostring(c.from):lower() then at = i break end
		end
		if c.from and not at then error("no gem '" .. c.from .. "' in socket group " .. c.group, 0) end
		group.gemList = {}
		for i, gem in ipairs(prev) do group.gemList[i] = gem end
		local touched = {}
		if c.to then
			local gem, auto = newGem(c.to, c.level, c.quality)
			group.gemList[at or #group.gemList + 1] = gem
			touched[1] = { gem = gem, auto = auto }
		elseif at then
			table.remove(group.gemList, at)
		else
			error("swapGem needs `from` or `to`", 0)
		end
		processGroup(b, group, touched, used)
	elseif change.allocate then
		saveTree()
		for _, want in ipairs(change.allocate) do
			local nodes = findNodes(spec, want)
			if #nodes == 0 then error("unknown node " .. tostring(want), 0) end
			local best
			for _, n in ipairs(nodes) do
				if n.alloc then best = nil break end
				if n.path and (not best or #n.path < #best.path) then best = n end
			end
			if best then
				if best.type == "Mastery" then error("mastery nodes need an effect choice, which compare_variants can't set", 0) end
				spec:AllocNode(best)
			elseif not nodes[1].alloc then
				error("no path to " .. tostring(want), 0)
			end
		end
	elseif change.deallocate then
		saveTree()
		for _, want in ipairs(change.deallocate) do
			local nodes = findNodes(spec, want)
			if #nodes == 0 then error("unknown node " .. tostring(want), 0) end
			for _, n in ipairs(nodes) do
				if n.alloc then spec:DeallocNode(n) end
			end
		end
		spec:BuildAllDependsAndPaths()
	elseif change.config then
		local input = b.configTab.configSets[b.configTab.activeConfigSetId].input
		for var, value in pairs(change.config) do
			local opt
			for _, o in ipairs(configOptions()) do
				if o.var == var then opt = o break end
			end
			if not opt then error("unknown config option " .. tostring(var), 0) end
			if opt.type == "check" then
				value = value and value ~= 0 or false
			elseif opt.type == "list" then
				local known
				for _, entry in ipairs(opt.list) do
					if entry.val == value then known = true end
				end
				if not known then error("invalid value for config option " .. var, 0) end
			elseif type(value) ~= "number" and opt.type ~= "text" then
				error("config option " .. var .. " takes a number", 0)
			end
			local prev = input[var]
			undo[#undo + 1] = function() input[var] = prev end
			input[var] = value
		end
	elseif change.mods then
		for _, l in ipairs(change.mods) do
			local r = parseLine(l, roll)
			lines[#lines + 1] = r.resolved or l
			if not r.supported then unsupported[#unsupported + 1] = l end
		end
	else
		error("unknown change type", 0)
	end
end

-- The variant's changes are applied, evaluated and undone again; `raw` carries the unrounded stats for the deltas.
local function variantRow(b, variant, want, roll)
	local undo, lines, unsupported, used = {}, {}, {}, {}
	local ok, err = pcall(function()
		for _, change in ipairs(variant.changes or {}) do
			applyChange(b, change, undo, lines, unsupported, roll, used)
		end
	end)
	local row
	if ok then
		local okEval, after, _, components = evalMods(b, lines)
		if okEval then
			local warnings, feasible = setupWarnings(b, after)
			local unsourced = unsourcedConfig(b, after, lines)
			addConfigWarnings(warnings, unsourced)
			local stats = {}
			for _, k in ipairs(want) do stats[k] = jsonNumber(after[k]) end
			row = { stats = stats, skillTotal = components, gems = #used > 0 and used or nil, warnings = warnings, feasible = feasible, unsourcedConfig = unsourced,
				unsupported = #unsupported > 0 and unsupported or nil, raw = after }
		else
			err = after
		end
	end
	for i = #undo, 1, -1 do
		local okU, errU = pcall(undo[i])
		if not okU then err = (err and tostring(err) .. "; " or "") .. "restore failed: " .. tostring(errU) end
	end
	if not row then row = { error = tostring(err) } end
	row.name = variant.name
	return row
end

function methods.compare_variants(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	if type(p.variants) ~= "table" or #p.variants == 0 then return { error = "variants required" } end
	if #p.variants > MAX_VARIANTS then return { error = "at most " .. MAX_VARIANTS .. " variants per call" } end
	local want = p.stats or VARIANT_STATS
	local base = variantRow(b, { name = "baseline" }, want, p.roll)
	if base.error then return { error = base.error } end
	local rows = {}
	for i, v in ipairs(p.variants) do
		v.name = v.name or ("variant " .. i)
		local row = variantRow(b, v, want, p.roll)
		if row.raw then
			row.delta = {}
			for _, k in ipairs(want) do
				if type(base.raw[k]) == "number" and type(row.raw[k]) == "number" then row.delta[k] = jsonNumber(row.raw[k] - base.raw[k]) end
			end
		end
		row.raw = nil
		rows[i] = row
	end
	base.raw = nil
	pcall(recalc, b)
	b:RefreshStatList()
	return { baseline = base, variants = rows }
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
		c.thinking = { steps = {}, since = GetTime() }
		return { messages = msgs, build = buildName(), hint = "Answer with chat_reply (use chat_status for progress), then call chat_wait again." }
	end }
end

function methods.chat_reply(p)
	local c = chat()
	if type(p.text) ~= "string" or p.text == "" then return { error = "text required" } end
	c.lastSeen = GetTime()
	c.messages[#c.messages + 1] = { role = "agent", text = p.text, time = os.time(), revealAt = GetTime(),
		thoughts = c.thinking and #c.thinking.steps > 0 and c.thinking.steps or nil }
	c.delivered = #c.messages
	c.thinking = nil
	return { ok = true }
end

function methods.chat_status(p)
	local c = chat()
	c.lastSeen = GetTime()
	if type(p.text) ~= "string" or not p.text:match("%S") then return { ok = true } end
	c.thinking = c.thinking or { steps = {}, since = GetTime() }
	local steps = c.thinking.steps
	if steps[#steps] ~= p.text then steps[#steps + 1] = p.text end
	return { ok = true }
end

function methods.chat_history()
	return { messages = chat().messages, build = buildName() }
end

-- Passive tree optimiser: a greedy add/swap search on a copy of the active tree. Candidates are scored with the misc
-- calculator's addNodes/removeNodes overrides, so the spec is only rebuilt when a move is kept. The search runs in
-- slices from a deferred result so PoB keeps drawing and the chat panel can show its progress.
local OPT_SLICE = 0.4
local OPT_TIME = 20
local OPT_MOVE_ADDS = 6
local OPT_BREADTH = 15

local function nodeTypes(node)
	local types = {}
	for _, m in ipairs(node.modList or {}) do types[m.name] = true end
	return types
end

local function nodeProvides(def, node)
	for _, line in ipairs(node.sd or {}) do
		line = StripEscapes(line):lower()
		if anyFind(def.text, line) and not anyFind(def.notText, line) then return true end
	end
	return false
end

-- Config options that are on while no item or gem provides them, so only an allocated node can justify them.
local function treeConfigOptions(b)
	local input = b.configTab.configSets[b.configTab.activeConfigSetId].input
	local have = buildSources(b)
	local treeLines = {}
	for _, node in pairs(b.calcsTab.mainEnv.allocNodes) do
		for _, line in ipairs(node.sd or {}) do
			line = StripEscapes(line):lower()
			treeLines[line] = (treeLines[line] or 0) + 1
		end
	end
	local kept = {}
	for _, line in ipairs(have.lines) do
		if (treeLines[line] or 0) > 0 then treeLines[line] = treeLines[line] - 1 else kept[#kept + 1] = line end
	end
	have.lines = kept
	local out = {}
	for _, opt in ipairs(configOptions()) do
		local def = opt.var and CONFIG_SOURCES[opt.var]
		local value = input[opt.var]
		if def and def.text and value and value ~= 0 and not hasSource(b, opt, def, have) then
			out[#out + 1] = { var = opt.var, def = def }
		end
	end
	return out
end

local function optimizeTree(b, p, progress, pace)
	local calcs_ = b.calcsTab.calcs
	local tab = b.treeTab
	local origSpec, origIndex = b.spec, tab.activeSpec
	local tree = origSpec.tree
	local weights = type(p.weights) == "table" and p.weights or {}
	local wEhp, wDps = tonumber(weights.ehp) or 1, tonumber(weights.dps) or 1
	local floor = tonumber(p.dpsFloor) or 0
	local hops = tonumber(p.hops) or 4
	local allowKeystones = p.allowKeystones == true
	local budget = tonumber(p.budget) or origSpec:CountAllocNodes()
	local t0 = os.clock()

	local function score(dps, ehp)
		local s = wEhp * math.log(math.max(ehp, 1)) + wDps * math.log(math.max(dps, 1))
		if dps < floor then s = s - 10 - (floor - dps) / floor end
		return s
	end

	local before = recalc(b)
	before.SkillTotalDPS = skillTotal(b)
	local skill = mainSkill(b)
	local src = skill and skill.activeEffect and skill.activeEffect.srcInstance
	local parts = src and COMBINED_PARTS[skill.activeEffect.grantedEffect.name]
	local selectedPart = src and src.skillPart
	local treeOptions = treeConfigOptions(b)
	local input = b.configTab.configSets[b.configTab.activeConfigSetId].input
	local inputSaved = {}
	for _, opt in ipairs(treeOptions) do inputSaved[opt.var] = input[opt.var] end
	-- Mod names that equipment and gems already provide; allocated nodes add theirs each round
	local ownedBase = {}
	for name, list in pairs(b.calcsTab.mainEnv.player.modDB.mods) do
		for _, m in ipairs(list) do
			local kind = tostring(m.source):match("^[^:]*")
			if kind == "Item" or kind == "Skill" then ownedBase[name] = true break end
		end
	end

	local spec = new("PassiveSpec"):PassiveSpec(b, origSpec.treeVersion)
	spec.title = string.format("Optimized W=%.2g", wDps / wEhp)
	spec.jewels = copyTable(origSpec.jewels)
	spec:RestoreUndoState(origSpec:CreateUndoState())
	spec:BuildClusterJewelGraphs()
	table.insert(tab.specList, spec)
	tab:SetActiveSpec(#tab.specList)

	local moves, rounds, ncalcs = 0, 0, 0
	local ok, err = pcall(function()
		-- Nodes within `hops` of the starting tree
		local region, frontier = {}, {}
		for id, node in pairs(spec.allocNodes) do
			if not node.ascendancyName and node.type ~= "ClassStart" then region[id] = true frontier[#frontier + 1] = node end
		end
		for _ = 1, hops do
			local nextFrontier = {}
			for _, node in ipairs(frontier) do
				for _, other in ipairs(node.linked) do
					if not region[other.id] and not other.ascendancyName and other.type ~= "ClassStart" and other.type ~= "Mastery" then
						region[other.id] = true
						nextFrontier[#nextFrontier + 1] = other
					end
				end
			end
			frontier = nextFrontier
		end

		local calcFunc
		local function rebase() calcFunc = calcs_.getMiscCalculator(b) end
		rebase()
		local optionState = {}
		local providesCache = setmetatable({}, { __mode = "k" })
		local function provides(opt, node)
			local cached = providesCache[node]
			if not cached then cached = {} providesCache[node] = cached end
			if cached[opt.var] == nil then cached[opt.var] = nodeProvides(opt.def, node) end
			return cached[opt.var]
		end
		local function applyOptions(override)
			local changed = false
			for _, opt in ipairs(treeOptions) do
				local on = false
				for _, node in pairs(spec.allocNodes) do
					if provides(opt, node) and not (override.removeNodes and override.removeNodes[node]) then on = true break end
				end
				for node in pairs(override.addNodes or {}) do
					if provides(opt, node) then on = true end
				end
				if optionState[opt.var] ~= on then
					optionState[opt.var] = on
					input[opt.var] = on or nil
					changed = true
				end
			end
			if changed then
				b.configTab:BuildModList()
				rebase()
			end
		end

		local function runPart(override, part)
			if part then src.skillPart = part end
			ncalcs = ncalcs + 1
			pace()
			return calcFunc(override, false)
		end
		-- Candidates are screened on the biggest part of a combined skill, scaled by its share of the total
		local topPart, topShare = nil, 1
		if parts then
			applyOptions({})
			local byPart, total = {}, 0
			for _, part in ipairs(parts) do
				byPart[part] = runPart({}, part).CombinedDPS or 0
				total = total + byPart[part]
				if not topPart or byPart[part] > byPart[topPart] then topPart = part end
			end
			topShare = total > 0 and byPart[topPart] / total or 1
		end
		local function evaluate(override, full)
			applyOptions(override)
			local out = runPart(override, topPart)
			local dps = out.CombinedDPS or 0
			if parts then
				if full then
					for _, part in ipairs(parts) do
						if part ~= topPart then dps = dps + (runPart(override, part).CombinedDPS or 0) end
					end
				else
					dps = dps / topShare
				end
			end
			if #unpayable(out) > 0 then return -1e9, 0, out.TotalEHP or 0 end
			return score(dps, out.TotalEHP or 1), dps, out.TotalEHP or 1
		end

		local function usedPoints() return (spec:CountAllocNodes()) end
		local function removable(node)
			return not (node.ascendancyName or node.type == "ClassStart" or node.type == "AscendClassStart" or node.type == "Socket"
				or node.expansionJewel or node.type == "Keystone" and not allowKeystones)
		end
		local function masteryNode(node, effectId)
			local pseudo = { id = node.id, type = node.type, name = node.name, sd = { }, group = node.group, pseudoEffect = effectId }
			for i, line in ipairs(tree.masteryEffects[effectId].sd or { }) do pseudo.sd[i] = line end
			tree:ProcessStats(pseudo)
			return pseudo
		end

		-- Single additions (with the path to them), and for each mod name the build has none of, every addition with it
		local function candidates(owned)
			local singles, groups = {}, {}
			local groupAllocated, effectTaken = {}, {}
			for id, node in pairs(spec.allocNodes) do
				if node.type == "Mastery" then effectTaken[spec.masterySelections[id]] = id
				elseif node.group then groupAllocated[node.group] = true end
			end
			for id, node in pairs(spec.nodes) do
				if node.type == "Mastery" then
					if node.masteryEffects and groupAllocated[node.group] and not node.ascendancyName then
						for _, me in ipairs(node.masteryEffects) do
							if not effectTaken[me.effect] then
								singles[#singles + 1] = { nodes = { [masteryNode(node, me.effect)] = true }, remove = node.alloc and { [node] = true } or nil,
									cost = node.alloc and 0 or 1, label = node.dn }
							end
						end
					end
				elseif not node.alloc and node.path and #node.path > 0 and #node.path <= hops and region[id] and node.group
					and node.type ~= "Socket" and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
					and not node.ascendancyName and not node.expansionJewel and (node.type ~= "Keystone" or allowKeystones) then
					local set, cost, inRegion = {}, 0, true
					for _, step in ipairs(node.path) do
						if not region[step.id] or step.expansionJewel then inRegion = false end
						set[step] = true
						cost = cost + 1
					end
					local types = nodeTypes(node)
					local isNew = false
					for name in pairs(types) do
						if not owned[name] then
							isNew = true
							groups[name] = groups[name] or { name = name, nodes = {} }
							for step in pairs(set) do groups[name].nodes[step] = true end
						end
					end
					if inRegion and not isNew and next(types) then
						singles[#singles + 1] = { nodes = set, cost = cost, label = node.dn }
					end
				end
			end
			return singles, groups
		end

		-- Whether the tree left by a move is legal: within budget, connected, each mastery effect taken at most once,
		-- and every mastery in a group that still has an allocated node
		local function legal(addSet, remSet)
			local final, net, masteries = {}, 0, {}
			for _, node in pairs(spec.allocNodes) do
				if not remSet[node] then final[node.id] = node end
			end
			for _ in pairs(remSet) do net = net - 1 end
			for node in pairs(addSet) do
				net = net + 1
				if node.pseudoEffect then masteries[#masteries + 1] = node else final[node.id] = node end
			end
			if usedPoints() + net > budget then return false end
			local groupAllocated, needed = {}, 0
			for id, node in pairs(final) do
				if node.type == "Mastery" then masteries[#masteries + 1] = node
				elseif node.group then groupAllocated[node.group] = true end
				if node.type ~= "Mastery" and node.type ~= "ClassStart" and not node.ascendancyName and id < 65536 then needed = needed + 1 end
			end
			local effects = {}
			for _, node in ipairs(masteries) do
				local effect = node.pseudoEffect or spec.masterySelections[node.id]
				if effects[effect] or not groupAllocated[node.group] then return false end
				effects[effect] = true
			end
			local start = spec.nodes[spec.curClass.startNodeId]
			local seen, queue, reached, qi = { [start.id] = true }, { start }, 0, 1
			while queue[qi] do
				for _, other in ipairs(queue[qi].linked) do
					if not seen[other.id] and final[other.id] and not other.ascendancyName and other.type ~= "Mastery" then
						seen[other.id] = true
						queue[#queue + 1] = other
						if other.id < 65536 then reached = reached + 1 end
					end
				end
				qi = qi + 1
			end
			return reached == needed
		end

		local function commit(adds, remSet)
			local state = spec:CreateUndoState()
			local hash, removed = {}, {}
			for node in pairs(remSet) do removed[node.id] = true end
			for _, id in ipairs(state.hashList) do
				if not removed[id] then hash[#hash + 1] = id end
			end
			for id in pairs(removed) do
				state.masteryEffects[id] = nil
				state.hashOverrides[id] = nil
			end
			for _, a in ipairs(adds) do
				for node in pairs(a.nodes) do
					if node.pseudoEffect then
						state.masteryEffects[node.id] = node.pseudoEffect
						hash[#hash + 1] = node.id
					else
						hash[#hash + 1] = node.id
					end
				end
			end
			state.hashList = hash
			spec:RestoreUndoState(state)
			rebase()
			optionState = {}
		end

		local function union(a, b_)
			local t = {}
			for k in pairs(a or {}) do t[k] = true end
			for k in pairs(b_ or {}) do t[k] = true end
			return t
		end

		local bestScore, bestDps, bestEhp = evaluate({}, true)
		progress(string.format("Optimizing the tree: starting at %.0f DPS, %.0f EHP with %d of %d points", bestDps, bestEhp, usedPoints(), budget))
		local deadline = t0 + OPT_TIME
		while os.clock() < deadline do
			rounds = rounds + 1
			local owned = {}
			for name in pairs(ownedBase) do owned[name] = true end
			for _, node in pairs(spec.allocNodes) do
				for name in pairs(nodeTypes(node)) do owned[name] = true end
			end
			local roundBase = evaluate({}, false)
			local singles, groups = candidates(owned)
			local bestRatio = 0
			for _, c in ipairs(singles) do
				c.gain = evaluate({ addNodes = c.nodes, removeNodes = c.remove }, false) - roundBase
				c.ratio = c.cost > 0 and c.gain / c.cost or c.gain * 1e9
				if c.cost > 0 and c.ratio > bestRatio then bestRatio = c.ratio end
			end
			table.sort(singles, function(x, y) return x.ratio > y.ratio end)
			-- A stat the build has none of is only worth taking all together, and only if that beats the best single use of the points
			local packages = {}
			for _, g in ipairs(groups) do
				local cost = 0
				for _ in pairs(g.nodes) do cost = cost + 1 end
				local gain = evaluate({ addNodes = g.nodes }, false) - roundBase
				if gain > 0 and gain / cost > bestRatio then
					packages[#packages + 1] = { nodes = g.nodes, cost = cost, ratio = gain / cost, gain = gain, label = g.name }
				end
			end
			table.sort(packages, function(x, y) return x.ratio > y.ratio end)

			local drops = {}
			for _, node in pairs(spec.allocNodes) do
				if removable(node) then
					local set, count, whole = {}, 0, true
					for _, dep in ipairs(node.depends or { node }) do
						if dep.alloc and not set[dep] then
							set[dep] = true
							count = count + 1
							whole = whole and removable(dep)
						end
					end
					if whole and count > 0 then
						local loss = roundBase - evaluate({ removeNodes = set }, false)
						drops[#drops + 1] = { nodes = set, freed = count, ratio = loss / count }
					end
				end
			end
			table.sort(drops, function(x, y) return x.ratio < y.ratio end)

			local free = budget - usedPoints()
			local best
			local function try(adds, remSet, label)
				local addSet, remAll = {}, union(remSet)
				for _, a in ipairs(adds) do
					addSet = union(addSet, a.nodes)
					remAll = union(remAll, a.remove)
				end
				for node in pairs(addSet) do
					if remAll[node] then return end
				end
				if not legal(addSet, remAll) then return end
				local s, dps, ehp = evaluate({ addNodes = addSet, removeNodes = remAll }, true)
				if not best or s > best.score then best = { score = s, dps = dps, ehp = ehp, adds = adds, rem = remAll, label = label } end
			end
			local function pack(points, remSet, lead)
				local picked, taken, cost = {}, {}, 0
				local function take(c)
					picked[#picked + 1] = c
					for node in pairs(c.nodes) do taken[node] = true end
					cost = cost + c.cost
				end
				if lead then take(lead) end
				for _, c in ipairs(singles) do
					if #picked >= OPT_MOVE_ADDS or c.gain <= 0 then break end
					if cost + c.cost <= points then
						local clash = false
						for node in pairs(c.nodes) do
							if taken[node] or remSet and remSet[node] then clash = true end
						end
						if not clash then take(c) end
					end
				end
				return picked
			end

			if free > 0 then
				local picked = pack(free, nil)
				if #picked > 0 then try(picked, nil, "fill") end
			end
			for i = 1, math.min(OPT_BREADTH, #drops) do
				local picked = pack(free + drops[i].freed, drops[i].nodes)
				if #picked > 0 then try(picked, drops[i].nodes, singles[1].label) end
			end
			local leads = {}
			for i = 1, math.min(OPT_BREADTH, #singles) do
				if singles[i].gain > 0 then leads[#leads + 1] = singles[i] end
			end
			for i = 1, math.min(3, #packages) do leads[#leads + 1] = packages[i] end
			for _, lead in ipairs(leads) do
				local need = lead.cost - free
				local remSet, freed = {}, 0
				for _, d in ipairs(drops) do
					if freed >= need then break end
					local clash = false
					for node in pairs(d.nodes) do
						if lead.nodes[node] or remSet[node] then clash = true end
					end
					if not clash then
						remSet = union(remSet, d.nodes)
						freed = freed + d.freed
					end
				end
				if freed >= need then try(pack(free + freed, remSet, lead), remSet, lead.label) end
			end

			if not best or best.score <= bestScore + 1e-4 then break end
			bestScore = best.score
			moves = moves + 1
			commit(best.adds, best.rem)
			progress(string.format("Optimizing the tree, round %d: %s, now %.0f DPS, %.0f EHP with %d of %d points", rounds, best.label, best.dps, best.ehp, usedPoints(), budget))
		end
	end)
	for var, value in pairs(inputSaved) do input[var] = value end
	if src then src.skillPart = selectedPart end
	b.configTab:BuildModList()
	local function discard()
		for i = #tab.specList, 1, -1 do
			if tab.specList[i] == spec then table.remove(tab.specList, i) end
		end
		tab:SetActiveSpec(origIndex)
	end
	if not ok then
		discard()
		error(err, 0)
	end
	if moves == 0 then
		discard()
		recalc(b)
		return { improved = false, rounds = rounds, seconds = os.clock() - t0, note = "No legal change beat the current tree under these weights, floor and budget, so no tree was added." }
	end

	local after = recalc(b)
	local components
	after.SkillTotalDPS, components = skillTotal(b)
	local unsourced = unsourcedConfig(b, after)
	local warnings, feasible = setupWarnings(b, after)
	addConfigWarnings(warnings, unsourced)
	local function summary(stats)
		return { dps = jsonNumber(stats.SkillTotalDPS), ehp = jsonNumber(stats.TotalEHP), life = jsonNumber(stats.Life),
			score = jsonNumber(score(stats.SkillTotalDPS or 0, stats.TotalEHP or 1)) }
	end
	local added, removed, masteryChanges = {}, {}, {}
	for id, node in pairs(spec.allocNodes) do
		if not origSpec.allocNodes[id] and node.type ~= "Mastery" then added[#added + 1] = node.dn end
	end
	for id, node in pairs(origSpec.allocNodes) do
		if not spec.allocNodes[id] and node.type ~= "Mastery" then removed[#removed + 1] = node.dn end
	end
	table.sort(added)
	table.sort(removed)
	local function effectText(effectId)
		local effect = effectId and tree.masteryEffects[effectId]
		return effect and table.concat(effect.sd or {}, " / ")
	end
	local seenMastery = {}
	for _, selections in ipairs({ spec.masterySelections, origSpec.masterySelections }) do
		for id, effectId in pairs(selections) do
			if not seenMastery[id] then
				seenMastery[id] = true
				local was, now = origSpec.masterySelections[id], spec.masterySelections[id]
				if was ~= now then
					masteryChanges[#masteryChanges + 1] = { mastery = spec.nodes[id].name, from = effectText(was), to = effectText(now) }
				end
			end
		end
	end
	local used = spec:CountAllocNodes()
	return { improved = true, spec = spec.title, specIndex = #tab.specList, originalSpec = origSpec.title or "Default",
		pointsUsed = used, budget = budget, added = added, removed = removed, masteryChanges = masteryChanges,
		before = summary(before), after = summary(after), dpsFloorMet = (after.SkillTotalDPS or 0) >= floor,
		skillTotal = { combined = components ~= nil, components = components },
		warnings = warnings, feasible = feasible, unsourcedConfig = unsourced,
		rounds = rounds, calcs = ncalcs, seconds = os.clock() - t0 }
end

function methods.optimize_tree(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	local c = chat()
	local sliceEnd = 0
	local function pace() if os.clock() >= sliceEnd then coroutine.yield() end end
	local function progress(text)
		if c.thinking then c.thinking.steps[#c.thinking.steps + 1] = text end
	end
	local co = coroutine.create(function() return optimizeTree(b, p, progress, pace) end)
	return { _defer = function()
		sliceEnd = os.clock() + OPT_SLICE
		local ok, res = coroutine.resume(co)
		if not ok then error(res, 0) end
		if coroutine.status(co) == "dead" then return res end
	end }
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
