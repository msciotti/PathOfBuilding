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
		notText = { "while you have fortify", "while fortified" }, gems = { "Fortify", "Vigilant Strike" } },
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
	local totalParts
	if baseComponents and afterComponents then
		totalParts = { combined = true, components = {} }
		for i, c in ipairs(baseComponents) do
			totalParts.components[i] = { part = c.part, name = c.name, before = c.dps, after = afterComponents[i].dps }
		end
	end
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

-- Rare item design: items are built from PoB's own mod pools (Item:CanHaveMod) and written back with BuildRaw, so the
-- text is what PoB's crafting UI produces and compare_variants' `equip` takes it as is.
local DEFAULT_ILVL = 86
local ROLLS = { max = 1, mid = 0.5, min = 0 }
local INFLUENCE_KEYS = { shaper = "Shaper", elder = "Elder", crusader = "Crusader", redeemer = "Redeemer", hunter = "Hunter", warlord = "Warlord" }
local INFLUENCE_TAGS = { redeemer = "eyrie", hunter = "basilisk", warlord = "adjudicator" }
-- Proposals assume what is common on trade: the second best tier, rolled 70% of the way up its range.
local PROPOSAL_TIER, PROPOSAL_ROLL = 2, 0.7
local RESIST_TEXT = { Fire = "+#% to Fire Resistance", Cold = "+#% to Cold Resistance", Lightning = "+#% to Lightning Resistance" }
local MAX_FILL_SLOTS = 6

local function lineTemplate(line)
	local t = line:gsub("%(%-?[%d%.]+%-%-?[%d%.]+%)", "#"):gsub("%-?%d+%.?%d*", "#"):gsub("^%+", "")
	return (t:lower():gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local function modTemplate(mod)
	local parts = {}
	for i, line in ipairs(mod) do parts[i] = lineTemplate(line) end
	return table.concat(parts, " / ")
end

local function requestTemplate(text)
	local parts = {}
	for part in (text .. " / "):gmatch("(.-) / ") do parts[#parts + 1] = lineTemplate(part) end
	return table.concat(parts, " / ")
end

local function ordinal(n)
	return n .. (n == 1 and "st" or n == 2 and "nd" or n == 3 and "rd" or "th")
end

local function rolledValue(mod, range)
	return tonumber(itemLib.applyRange(mod[1], range):match("%-?%d+%.?%d*"))
end

local function parseRoll(roll)
	if type(roll) == "number" and roll >= 0 and roll <= 1 then return roll end
	return ROLLS[roll or "mid"]
end

-- An unrolled rare of the given base with its normal implicit and no explicit mods, or nil and the reason.
local function newRare(spec, ilvl)
	local key = tostring(spec.base):lower()
	local baseName
	for name in pairs(data.itemBases) do
		if name:lower() == key then baseName = name break end
	end
	if not baseName then
		local close = {}
		for name in pairs(data.itemBases) do
			if name:lower():find(key, 1, true) then close[#close + 1] = name end
		end
		table.sort(close)
		return nil, "unknown base '" .. tostring(spec.base) .. "'" .. (#close > 0 and " (did you mean " .. table.concat(close, ", ", 1, math.min(#close, 5)) .. "?)" or "")
	end
	local entry = data.itemBases[baseName]
	if entry.flask or entry.tincture then return nil, baseName .. " can't be a rare item" end
	local lines = { "Rarity: RARE", "Agent Design", baseName }
	for _, name in ipairs(spec.influences or {}) do
		local display = INFLUENCE_KEYS[tostring(name):lower()]
		if not display then return nil, "unknown influence '" .. tostring(name) .. "'" end
		lines[#lines + 1] = display .. " Item"
	end
	lines[#lines + 1] = "Crafted: true"
	lines[#lines + 1] = "Item Level: " .. ilvl
	local implicits = {}
	for l in (spec.implicit or entry.implicit or ""):gmatch("[^\n]+") do implicits[#implicits + 1] = l end
	lines[#lines + 1] = "Implicits: " .. #implicits
	for _, l in ipairs(implicits) do lines[#lines + 1] = l end
	local item = new("Item"):Item(table.concat(lines, "\n"))
	if not item.base or not item.affixes then return nil, "can't build " .. baseName end
	return item
end

-- Implicit lines of the bases that differ only in implicit (Two-Stone Ring comes with three resist pairs)
local function implicitVariants(baseName)
	local entry, family = data.itemBases[baseName], baseName:gsub(" %(.-%)$", "")
	local out, seen = {}, {}
	for name, other in pairs(data.itemBases) do
		if name:gsub(" %(.-%)$", "") == family and other.subType == entry.subType and other.implicit and not seen[other.implicit] then
			seen[other.implicit] = true
			out[#out + 1] = other.implicit
		end
	end
	table.sort(out)
	return out
end

local function newContext(spec)
	local ilvl = tonumber(spec.ilvl) or DEFAULT_ILVL
	local item, err = newRare(spec, ilvl)
	if not item then return nil, err end
	local prefixLimit = item.prefixes.limit or item.affixLimit / 2
	local suffixLimit = item.suffixes.limit or item.affixLimit / 2
	return { item = item, spec = spec, ilvl = ilvl, limit = { Prefix = prefixLimit, Suffix = suffixLimit } }
end

-- Tiers of the one mod group matching `template`, best first, each marked `allowed` when the item level reaches it.
-- Returns nil and the reason when the item can't have the mod.
local function findTiers(ctx, template, crafted)
	local item = ctx.item
	local exact, partial = {}, {}
	local function consider(id, mod)
		if mod.type ~= "Prefix" and mod.type ~= "Suffix" then return end
		if modTemplate(mod) == template then
			exact[#exact + 1] = { id = id, mod = mod }
		elseif #mod > 1 then
			for _, line in ipairs(mod) do
				if lineTemplate(line) == template then partial[#partial + 1] = { id = id, mod = mod } break end
			end
		end
	end
	if crafted then
		for i, mod in ipairs(data.masterMods) do
			if mod.types[item.type] then consider(i, mod) end
		end
	else
		for id, mod in pairs(item.affixes) do
			if not item:CheckIfModIsDelve(mod) then consider(id, mod) end
		end
	end
	local found = #exact > 0 and exact or partial
	if #found == 0 then return nil, "no such modifier" end
	local fits = {}
	for _, c in ipairs(found) do
		if crafted or item:CanHaveMod(c.mod) then fits[#fits + 1] = c end
	end
	if #fits == 0 then
		for key, display in pairs(INFLUENCE_KEYS) do
			local tag = item.base.influenceTags and item.base.influenceTags[INFLUENCE_TAGS[key] or key]
			for _, c in ipairs(found) do
				if tag and item:CanHaveMod(c.mod, { [tag] = true }) then return nil, "needs " .. display .. " influence" end
			end
		end
		return nil, "can't roll on " .. item.type:lower()
	end
	local group = fits[1].mod.group
	for _, c in ipairs(fits) do
		if c.mod.group ~= group then return nil, "ambiguous: matches several mod groups, give the full mod text" end
	end
	table.sort(fits, function(a, b)
		if a.mod.level ~= b.mod.level then return a.mod.level > b.mod.level end
		return tostring(a.id) < tostring(b.id)
	end)
	for i, c in ipairs(fits) do
		c.tier, c.allowed, c.crafted = i, crafted or c.mod.level <= ctx.ilvl, crafted
	end
	return fits
end

local function allowedTiers(tiers)
	local list = {}
	for _, t in ipairs(tiers) do
		if t.allowed then list[#list + 1] = t end
	end
	return list
end

-- Turns one requested mod into a pick ({ id, mod, tier, tiers, range, crafted }), or nil and the rejection reason.
local function resolveRequest(ctx, req)
	local text = tostring(req.text or "")
	local tiers, why = findTiers(ctx, requestTemplate(text), req.crafted)
	if not tiers then return nil, why end
	local list = allowedTiers(tiers)
	if #list == 0 then return nil, "needs item level " .. tiers[#tiers].mod.level .. " (item level is " .. ctx.ilvl .. ")" end
	local chosen
	if req.tier then
		chosen = tiers[tonumber(req.tier)]
		if not chosen then return nil, "tier " .. tostring(req.tier) .. " doesn't exist (" .. #tiers .. " tiers)" end
		if not chosen.allowed then return nil, "tier " .. chosen.tier .. " needs item level " .. chosen.mod.level end
	end
	local range = parseRoll(req.roll or ctx.spec.roll)
	if not range then return nil, "roll must be max, mid, min or a number from 0 to 1" end
	-- A number in the text picks the tier whose range contains it, rolled to exactly that value
	local value = not text:find("%(") and #list[1].mod == 1 and tonumber(text:match("%-?%d+%.?%d*")) or nil
	if value then
		local found
		for _, t in ipairs(chosen and { chosen } or list) do
			local lo, hi = t.mod[1]:match("%((%-?[%d%.]+)%-(%-?[%d%.]+)%)")
			lo, hi = tonumber(lo), tonumber(hi)
			if lo and hi and value >= math.min(lo, hi) and value <= math.max(lo, hi) then
				found, range = t, hi == lo and 0.5 or math.floor((value - lo) / (hi - lo) * 10000 + 0.5) / 10000
				break
			end
		end
		if not found or rolledValue(found.mod, range) ~= value then return nil, "no tier rolls " .. value .. " on this base" end
		chosen = found
	end
	chosen = chosen or list[1]
	return { id = chosen.id, mod = chosen.mod, tier = chosen.tier, tiers = #tiers, range = range, crafted = req.crafted }
end

-- Trade stat text and the lowest value for each mod line: the tier's floor, so the query finds items like the design
-- rather than only ones rolled as high as it.
local function tradeMods(pick)
	local out = {}
	for _, line in ipairs(pick.mod) do
		local sum, n = 0, 0
		for lo, hi in line:gmatch("%((%-?[%d%.]+)%-(%-?[%d%.]+)%)") do sum, n = sum + math.min(tonumber(lo), tonumber(hi)), n + 1 end
		if n == 0 then
			for v in line:gmatch("%-?%d+%.?%d*") do sum, n = sum + tonumber(v), n + 1 end
		end
		local text = line:gsub("%(%-?[%d%.]+%-%-?[%d%.]+%)", "#"):gsub("%-?%d+%.?%d*", "#")
		out[#out + 1] = { text = text, min = n > 0 and sum / n or nil, type = pick.crafted and "crafted" or nil }
	end
	return out
end

local function buildDesign(ctx, picks)
	local item = newRare(ctx.spec, ctx.ilvl)
	local crafted
	local slots = { Prefix = item.prefixes, Suffix = item.suffixes }
	local filled = { Prefix = 0, Suffix = 0 }
	for _, pick in ipairs(picks) do
		if pick.crafted then
			crafted = pick
		else
			local kind = pick.mod.type
			filled[kind] = filled[kind] + 1
			slots[kind][filled[kind]] = { modId = pick.id, range = pick.range }
		end
	end
	item:Craft()
	if crafted then
		for _, line in ipairs(crafted.mod) do
			item.explicitModLines[#item.explicitModLines + 1] = { line = line, modTags = crafted.mod.modTags or {}, range = crafted.range,
				crafted = true, prefix = crafted.mod.type == "Prefix" or nil, suffix = crafted.mod.type == "Suffix" or nil }
		end
		item:BuildAndParseRaw()
	end
	local text = item:BuildRaw()
	if not new("Item"):Item(text).base then error("the built item doesn't parse", 0) end
	local influences = {}
	for _, name in ipairs(ctx.spec.influences or {}) do influences[#influences + 1] = tostring(name):lower() end
	-- The trade site knows "Two-Toned Boots", not PoB's "Two-Toned Boots (Armour/Energy Shield)"
	local query = { base = (item.baseName:gsub(" %(.-%)$", "")), influences = #influences > 0 and influences or nil, mods = {} }
	local mods, modLines = {}, {}
	for _, pick in ipairs(picks) do
		local lines = {}
		for i, line in ipairs(pick.mod) do
			lines[i] = itemLib.applyRange(line, pick.range)
			modLines[#modLines + 1] = lines[i]
		end
		mods[#mods + 1] = { affix = (pick.crafted and "crafted " or "") .. pick.mod.type:lower(), text = table.concat(lines, " / "),
			tier = not pick.crafted and ("T" .. pick.tier .. " of " .. pick.tiers) or nil, group = pick.mod.group }
		for _, m in ipairs(tradeMods(pick)) do query.mods[#query.mods + 1] = m end
	end
	return { item = text, base = item.baseName, ilvl = ctx.ilvl, influences = query.influences, mods = mods, modLines = modLines, tradeQuery = query }
end

local function slotCheck(b, slotName, ctx)
	local slot = b.itemsTab.slots[slotName]
	if not slot then return "unknown slot " .. tostring(slotName) end
	if not b.itemsTab:IsItemValidForSlot(ctx.item, slot.slotName) then return ctx.item.baseName .. " can't go in " .. slot.slotName end
end

function methods.design_rare(p)
	if type(p.base) ~= "string" then return { error = "base required" } end
	local b = env().build
	local ctx, err = newContext(p)
	if not ctx then return { error = err } end
	if p.implicit then
		local variants = implicitVariants(ctx.item.baseName)
		if not isValueInArray(variants, p.implicit) then return { error = "implicit must be one of: " .. table.concat(variants, "; ") } end
	end
	if p.slot then
		if not b then return { error = "no build loaded" } end
		local bad = slotCheck(b, p.slot, ctx)
		if bad then return { error = bad } end
	end
	local picks, rejected, used, count = {}, {}, {}, { Prefix = 0, Suffix = 0 }
	local craftedReqs = {}
	local function reject(req, reason) rejected[#rejected + 1] = { mod = req.text, reason = reason } end
	for _, entry in ipairs(p.mods or {}) do
		local req = type(entry) == "table" and entry or { text = entry }
		if req.crafted then
			craftedReqs[#craftedReqs + 1] = req
		else
			local pick, why = resolveRequest(ctx, req)
			if not pick then
				reject(req, why)
			elseif used[pick.mod.group] then
				reject(req, "same mod group as '" .. used[pick.mod.group] .. "' (one mod per group)")
			elseif count[pick.mod.type] >= ctx.limit[pick.mod.type] then
				reject(req, ordinal(count[pick.mod.type] + 1) .. " " .. pick.mod.type:lower() .. " (the item has " .. ctx.limit[pick.mod.type] .. ")")
			else
				used[pick.mod.group] = req.text
				count[pick.mod.type] = count[pick.mod.type] + 1
				picks[#picks + 1] = pick
			end
		end
	end
	for i, req in ipairs(craftedReqs) do
		local pick, why = resolveRequest(ctx, req)
		if i > 1 then
			reject(req, "only one crafted modifier per item")
		elseif not pick then
			reject(req, why)
		elseif used[pick.mod.group] then
			reject(req, "same mod group as '" .. used[pick.mod.group] .. "' (one mod per group)")
		elseif count[pick.mod.type] >= ctx.limit[pick.mod.type] then
			reject(req, "no open " .. pick.mod.type:lower() .. " for a crafted mod")
		else
			count[pick.mod.type] = count[pick.mod.type] + 1
			picks[#picks + 1] = pick
		end
	end
	if #rejected > 0 then return { rejected = rejected, note = "nothing was built; fix or drop the rejected mods" } end
	local ok, design = pcall(buildDesign, ctx, picks)
	if not ok then return { error = tostring(design) } end
	design.open = { prefixes = ctx.limit.Prefix - count.Prefix, suffixes = ctx.limit.Suffix - count.Suffix }
	if p.slot then design.change = { equip = { slot = p.slot, item = design.item } } end
	return design
end

local function equipChanges(items)
	local changes = {}
	for i, it in ipairs(items) do changes[i] = { equip = { slot = it.slot, item = it.item } } end
	return changes
end

local ELEMENTS = { "Fire", "Cold", "Lightning" }

-- Resistance an implicit line gives at its mid roll, per element.
local function implicitResists(line)
	local out = { Fire = 0, Cold = 0, Lightning = 0 }
	local value = tonumber(itemLib.applyRange(line, 0.5):match("%-?%d+%.?%d*"))
	if not value or not line:find("Resistance") then return out end
	for _, elem in ipairs(ELEMENTS) do
		if line:find(elem) or line:find("all Elemental") then out[elem] = value end
	end
	return out
end

local function spendFor(p, ctx)
	if p.spend then return p.spend end
	local spend = { "+# to maximum Life", "+# to Strength" }
	if ctx.item.type == "Boots" then table.insert(spend, 1, "#% increased Movement Speed") end
	return spend
end

-- Places resist suffixes across all states at once, most open slot first. `sparing` keeps each item's spend suffixes
-- free. Nothing in `states` is changed; returns the picks per state and the resistance left uncovered.
local function planResists(states, gaps, sparing)
	local plan, left = {}, {}
	for i, state in ipairs(states) do
		plan[i] = { picks = {}, used = {}, suffixes = 0 }
	end
	for elem, gap in pairs(gaps) do left[elem] = gap end
	for _, elem in ipairs(ELEMENTS) do
		while left[elem] > 0 do
			local best
			for i, state in ipairs(states) do
				local room = state.ctx.limit.Suffix - plan[i].suffixes - (sparing and state.reserve or 0)
				local tiers = room > 0 and state.tiers[elem] or nil
				if tiers and not plan[i].used[tiers[1].mod.group] and (not best or room > best.room) then best = { i = i, room = room, tiers = tiers } end
			end
			if not best then break end
			local list = allowedTiers(best.tiers)
			local pick = math.min(PROPOSAL_TIER, #list)
			-- Tier 2 unless only a small remainder is left, which a lower tier covers
			for i = pick, #list do
				if rolledValue(list[i].mod, PROPOSAL_ROLL) >= left[elem] then pick = i end
			end
			left[elem] = left[elem] - rolledValue(list[pick].mod, PROPOSAL_ROLL)
			local entry = plan[best.i]
			entry.picks[#entry.picks + 1] = { id = list[pick].id, mod = list[pick].mod, tier = list[pick].tier, tiers = #best.tiers, range = PROPOSAL_ROLL }
			entry.used[list[pick].mod.group] = true
			entry.suffixes = entry.suffixes + 1
		end
	end
	local short = 0
	for _, g in pairs(left) do short = short + math.max(g, 0) end
	return plan, short
end

function methods.fill_resists(p)
	local b = env().build
	if not b then return { error = "no build loaded" } end
	if type(p.slots) ~= "table" or #p.slots == 0 then return { error = "slots required" } end
	if #p.slots > MAX_FILL_SLOTS then return { error = "at most " .. MAX_FILL_SLOTS .. " slots" } end
	local states, bare = {}, {}
	for i, slotName in ipairs(p.slots) do
		local slot = b.itemsTab.slots[slotName]
		if not slot then return { error = "unknown slot " .. tostring(slotName) } end
		local current = b.itemsTab.items[slot.selItemId]
		local baseName = (p.bases or {})[slotName] or current and current.baseName
		if not baseName then return { error = slotName .. " is empty: give its base in `bases`" } end
		local ctx, err = newContext({ base = baseName, ilvl = p.ilvl })
		if not ctx then return { error = slotName .. ": " .. err } end
		local bad = slotCheck(b, slotName, ctx)
		if bad then return { error = bad } end
		local variants = implicitVariants(ctx.item.baseName)
		-- Start from the implicit the slot has now, if it is one of the base's variants
		local currentImplicit = current and current.baseName == ctx.item.baseName and current.implicitModLines[1] and current.implicitModLines[1].line
		for _, v in ipairs(variants) do
			if v == currentImplicit then ctx.spec.implicit = v end
		end
		ctx.spec.implicit = ctx.spec.implicit or variants[1]
		local state = { slot = slotName, ctx = ctx, variants = variants, spend = spendFor(p, ctx), tiers = {}, reserve = 0 }
		for _, elem in ipairs(ELEMENTS) do state.tiers[elem] = findTiers(ctx, requestTemplate(RESIST_TEXT[elem])) end
		for _, text in ipairs(state.spend) do
			local tiers = findTiers(ctx, requestTemplate(text))
			if tiers and tiers[1].mod.type == "Suffix" then state.reserve = state.reserve + 1 end
		end
		states[i] = state
		bare[i] = { slot = slotName, item = buildDesign(ctx, {}).item }
	end
	local want = p.stats or VARIANT_STATS
	local before = variantRow(b, { name = "current" }, want)
	local open = variantRow(b, { name = "bare bases", changes = equipChanges(bare) }, want)
	if before.error or open.error then return { error = before.error or open.error } end

	-- Resistance still needed with no implicit at all, so any combination of implicit variants can be tried
	local gaps = {}
	for _, elem in ipairs(ELEMENTS) do
		gaps[elem] = -open.raw[elem .. "ResistOverCap"] + (open.raw["Missing" .. elem .. "Resist"] or 0)
	end
	for _, state in ipairs(states) do
		for elem, v in pairs(implicitResists(state.ctx.spec.implicit)) do gaps[elem] = gaps[elem] + v end
	end
	-- Best implicit variants: no resist short, then no spend stat given up, then the fewest resist mods
	local best
	local choice = {}
	local function search(i)
		if i > #states then
			local g = {}
			for elem, v in pairs(gaps) do g[elem] = v end
			for _, line in ipairs(choice) do
				for elem, v in pairs(implicitResists(line)) do g[elem] = g[elem] - v end
			end
			for _, sparing in ipairs({ true, false }) do
				local plan, short = planResists(states, g, sparing)
				local used = 0
				for _, e in ipairs(plan) do used = used + #e.picks end
				local score = { short, sparing and 0 or 1, used }
				local better = not best
				if best then
					for k = 1, 3 do
						if score[k] ~= best.score[k] then better = score[k] < best.score[k] break end
					end
				end
				if better then best = { score = score, plan = plan, choice = { unpack(choice) } } end
				if short == 0 then break end
			end
			return
		end
		for _, line in ipairs(states[i].variants) do
			choice[i] = line
			search(i + 1)
		end
	end
	search(1)

	local warnings, notes = {}, {}
	if best.score[1] > 0 then warnings[#warnings + 1] = string.format("%d points of resistance can't be covered with the open suffixes", best.score[1]) end
	local items = {}
	for i, state in ipairs(states) do
		state.ctx.spec.implicit = best.choice[i]
		local picks, used, count = best.plan[i].picks, best.plan[i].used, { Prefix = 0, Suffix = #best.plan[i].picks }
		for _, text in ipairs(state.spend) do
			local tiers = findTiers(state.ctx, requestTemplate(text))
			local list = tiers and allowedTiers(tiers) or {}
			local first = list[1]
			if not first then
				notes[#notes + 1] = state.slot .. ": " .. text .. " can't roll here"
			elseif used[first.mod.group] or count[first.mod.type] >= state.ctx.limit[first.mod.type] then
				notes[#notes + 1] = state.slot .. ": no open " .. first.mod.type:lower() .. " for " .. text
			else
				local tier = list[math.min(PROPOSAL_TIER, #list)]
				picks[#picks + 1] = { id = tier.id, mod = tier.mod, tier = tier.tier, tiers = #tiers, range = PROPOSAL_ROLL }
				used[first.mod.group] = true
				count[first.mod.type] = count[first.mod.type] + 1
			end
		end
		local design = buildDesign(state.ctx, picks)
		design.slot = state.slot
		design.implicit = best.choice[i]
		design.change = { equip = { slot = state.slot, item = design.item } }
		design.open = { prefixes = state.ctx.limit.Prefix - count.Prefix, suffixes = state.ctx.limit.Suffix - count.Suffix }
		items[i] = design
	end
	local variant = { name = "fill_resists", changes = equipChanges(items) }
	local after = variantRow(b, variant, want)
	if after.error then return { error = after.error } end
	local resists = {}
	for _, elem in ipairs(ELEMENTS) do
		local missing = after.raw["Missing" .. elem .. "Resist"] or 0
		resists[elem] = { total = after.raw[elem .. "ResistTotal"], cap = after.raw[elem .. "ResistTotal"] - after.raw[elem .. "ResistOverCap"], capped = missing == 0 }
		if missing > 0 then warnings[#warnings + 1] = string.format("%s resistance ends %d below its cap", elem, missing) end
	end
	for _, w in ipairs(after.warnings or {}) do warnings[#warnings + 1] = w end
	local delta = {}
	for _, k in ipairs(want) do
		if type(before.raw[k]) == "number" and type(after.raw[k]) == "number" then delta[k] = jsonNumber(after.raw[k] - before.raw[k]) end
	end
	pcall(recalc, b)
	b:RefreshStatList()
	return { items = items, variant = variant, resists = resists, before = before.stats, after = after.stats, delta = delta,
		feasible = after.feasible, warnings = warnings, unsourcedConfig = after.unsourcedConfig, notes = #notes > 0 and notes or nil }
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
