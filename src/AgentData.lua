-- Agent data layer: flat, searchable index over every game-data source PoB holds.
local M = {}

local function lower(s) return (s or ""):lower() end
local m_max = math.max

local function addEntry(idx, e)
	e.hay = lower(table.concat(e.lines, "\n") .. "\n" .. (e.name or "") .. "\n" .. table.concat(e.tags or {}, " "))
	idx.list[#idx.list + 1] = e
	local s = idx.sources[e.src]
	if not s then
		s = { src = e.src, count = 0 }
		idx.sources[e.src] = s
		idx.order[#idx.order + 1] = e.src
	end
	s.count = s.count + 1
end

local function modLines(m)
	local out = {}
	for i = 1, #m do
		if type(m[i]) == "string" then out[#out + 1] = m[i] end
	end
	return out
end

local function eligibleSlots(m)
	local slots = {}
	if m.weightKey then
		for i, k in ipairs(m.weightKey) do
			if (m.weightVal[i] or 0) > 0 then slots[#slots + 1] = k end
		end
	end
	return slots
end

-- How an explicit/corrupted mod with no spawn weight anywhere can still be obtained. Tags it names (e.g.
-- "staff_elder") with weight 0 mean it no longer rolls there: legacy, unless Elevated (Maven's Orb) or an essence's.
local function zeroWeightOrigin(m, isEssence)
	if not m.weightKey or #m.weightKey == 0 then return nil end
	local tags = {}
	for i, k in ipairs(m.weightKey) do
		if (m.weightVal[i] or 0) > 0 then return nil end
		if k ~= "default" then tags[#tags + 1] = k end
	end
	if isEssence then
		return "essence only (see the essence entry for item classes)"
	elseif (m.affix or ""):find("Elevated") then
		return "Maven's Orb upgrade of the influenced mod", tags
	elseif #tags > 0 then
		return "legacy: no longer rolls", nil, true
	end
	return "does not roll randomly (special source such as an essence, Incursion or Bestiary)"
end

function M.build(data, tree)
	local idx = { list = {}, sources = {}, order = {} }

	-- Vestigial mods come from one unique and can roll on any unique of the same item type (PoB's
	-- AddImplicitPopup rule), so record the source unique and that type
	local uniqueType = {}
	for typeName, list in pairs(data.uniques or {}) do
		for _, raw in ipairs(list) do
			local name = raw:match("^%s*([^\r\n]+)")
			if name then uniqueType[name] = typeName end
		end
	end

	local essenceMod = {}
	for _, e in pairs(data.essences or {}) do
		for _, modId in pairs(type(e) == "table" and e.mods or {}) do essenceMod[modId] = true end
	end

	for srcName, mods in pairs(data.itemMods) do
		if srcName ~= "Item" then
			for id, m in pairs(mods) do
				if type(m) == "table" then
					local e = {
						src = "mod:" .. srcName, id = id, name = m.affix ~= "" and m.affix or nil,
						kind = m.type, level = m.level, lines = modLines(m),
						tags = m.modTags, spawnOn = eligibleSlots(m), group = m.group,
					}
					if srcName == "Explicit" or srcName == "Corrupted" then
						local obtain, tags, legacy = zeroWeightOrigin(m, essenceMod[id])
						e.obtain, e.legacy = obtain, legacy
						if tags then e.spawnOn = tags end
					end
					local from = srcName == "Vestigial" and data.vestigialModMappings and data.vestigialModMappings[id]
					if from then
						e.name = "Vestigial implicit from " .. from
						e.kind = "Vestigial"
						e.spawnOn = uniqueType[from] and { "any unique " .. uniqueType[from] } or nil
					end
					addEntry(idx, e)
				end
			end
		end
	end

	if tree and tree.nodes then
		local masteriesSeen = {}
		for id, n in pairs(tree.nodes) do
			if n.ascendancyName and n.sd and #n.sd > 0 then
				addEntry(idx, {
					src = "passive:ascendancy:" .. n.ascendancyName, id = tostring(id), name = n.dn,
					kind = n.type, lines = n.sd, ascendancy = n.ascendancyName,
				})
			elseif not n.group and (n.type == "Notable" or n.type == "Keystone") then
			elseif n.sd and #n.sd > 0 and n.type ~= "ClassStart" then
				addEntry(idx, {
					src = "passive:" .. (n.type or "Normal"):lower(), id = tostring(id), name = n.dn,
					kind = n.type, lines = n.sd,
				})
			end
			-- Mastery nodes carry no sd; their selectable effects live in tree.masteryEffects
			for _, fx in ipairs(n.masteryEffects or {}) do
				local effect = tree.masteryEffects and tree.masteryEffects[fx.effect]
				if effect and not masteriesSeen[fx.effect] then
					masteriesSeen[fx.effect] = true
					addEntry(idx, { src = "passive:mastery", id = tostring(fx.effect), name = n.dn, lines = effect.sd })
				end
			end
		end
		for _, n in pairs(tree.tattoo and tree.tattoo.nodes or {}) do
			if n.sd and #n.sd > 0 and n.dn and n.dn ~= "" then
				addEntry(idx, { src = "tattoo", id = n.id, name = n.dn, kind = n.targetType, lines = n.sd })
			end
		end
		for _, n in pairs(tree.legion and tree.legion.nodes or {}) do
			if n.sd and #n.sd > 0 then
				addEntry(idx, { src = "timeless", id = tostring(n.id), name = n.dn, kind = n.ks and "Keystone" or n["not"] and "Notable" or nil, lines = n.sd })
			end
		end
	end

	-- Notable mods are weighted by enchant tag, which several enchants can share (both block enchants are
	-- "affliction_chance_to_block"), so map tags rather than PoB's per-skill clusterJewelInfoForNotable.
	local enchantsByTag = {}
	for size, jewel in pairs(data.clusterJewels and data.clusterJewels.jewels or {}) do
		for key, skill in pairs(jewel.skills or {}) do
			local tag = skill.tag or key
			enchantsByTag[tag] = enchantsByTag[tag] or {}
			table.insert(enchantsByTag[tag], size .. ": " .. skill.name)
			addEntry(idx, { src = "cluster:enchant", id = key, name = size .. " - " .. skill.name, kind = "Enchant",
				lines = skill.stats or {}, spawnOn = { size } })
		end
	end
	for _, m in pairs(data.itemMods.JewelCluster or {}) do
		local name = type(m) == "table" and type(m[1]) == "string" and m[1]:match("^1 Added Passive Skill is (.+)$")
		local node = name and tree and tree.clusterNodeMap and tree.clusterNodeMap[name]
		if node and node.sd and #node.sd > 0 then
			local on, seen = {}, {}
			for i, tag in ipairs(m.weightKey or {}) do
				if (m.weightVal[i] or 0) > 0 then
					for _, enchant in ipairs(enchantsByTag[tag] or {}) do
						if not seen[enchant] then seen[enchant] = true on[#on + 1] = enchant end
					end
				end
			end
			table.sort(on)
			addEntry(idx, { src = "cluster:" .. (node.isKeystone and "keystone" or "notable"), id = name, name = name,
				kind = node.isKeystone and "Keystone" or "Notable", lines = node.sd, spawnOn = on })
		end
	end

	local metaPrefix = { "League:", "Source:", "Variant:", "Requires", "Implicits:", "LevelReq:", "Has Alt", "Selected Variant", "Selected Alt Variant", "Item Class:", "Rarity:", "Limited to:", "Radius:", "Upgrade:", "Sockets:", "Talisman Tier:" }
	local function isMeta(l)
		for _, p in ipairs(metaPrefix) do if l:sub(1, #p) == p then return true end end
		return false
	end
	local function maxRoll(l)
		return (l:gsub("%((%-?[%d%.]+)%-(%-?[%d%.]+)%)", "%2"))
	end
	local function parses(l)
		local mods, extra = modLib.parseMod(maxRoll(l))
		return mods ~= nil and not extra
	end
	for typeName, list in pairs(data.uniques or {}) do
		for _, raw in ipairs(list) do
			local all = {}
			for l in raw:gmatch("[^\r\n]+") do all[#all + 1] = l end
			local name = table.remove(all, 1)
			local base = table.remove(all, 1)
			if name and name:sub(1, 7) == "Rarity:" then
				name = base
				base = table.remove(all, 1)
			end
			-- Variants named "Pre x.y" are legacy versions; drop lines that only apply to those
			local legacy, variantCount = {}, 0
			for _, l in ipairs(all) do
				local v = l:match("^Variant: (.*)")
				if v then
					variantCount = variantCount + 1
					legacy[variantCount] = v:match("^Pre ") ~= nil
				end
			end
			local lines = {}
			for _, l in ipairs(all) do
				if not isMeta(l) then
					local variants = l:match("{variant:([%d,]+)}")
					local current = true
					if variants then
						current = false
						for v in variants:gmatch("%d+") do
							if not legacy[tonumber(v)] then current = true break end
						end
					end
					if current then
						local n
						repeat l, n = l:gsub("^{[^}]*}", "") until n == 0
						lines[#lines + 1] = l
					end
				end
			end
			-- Rejoin stat lines that wrap onto the next line, as PoB does when parsing items
			local joined, i = {}, 1
			while i <= #lines do
				local l = lines[i]
				if lines[i + 1] and not parses(l) and parses(l .. " " .. lines[i + 1]) then
					l = l .. " " .. lines[i + 1]
					i = i + 1
				end
				joined[#joined + 1] = l
				i = i + 1
			end
			if name and name ~= "" and name:sub(1, 11) ~= "Item Class:" then
				addEntry(idx, { src = "unique:" .. typeName, id = name, name = name, kind = base and base:gsub("^{[^}]*}", ""), lines = joined })
			end
		end
	end

	-- Enchant tables nest differently per slot (helmet: skill -> MERCILESS/ENDGAME -> lines; weapon: type -> list of
	-- {lines..., types = {weapon types}}). Walk only the source tables: Data.lua also copies the weapon table into one
	-- table per weapon type and aliases Flask, which would duplicate every weapon enchant ~17 times.
	local function walkEnchants(slot, kind, t, depth)
		if depth > 4 then return end
		if type(t[1]) == "string" then
			for i, text in ipairs(t) do
				addEntry(idx, { src = "enchant:" .. slot, id = (kind or "?") .. "#" .. i, name = kind, lines = { text } })
			end
			return
		end
		if type(t[1]) == "table" and type(t[1][1]) == "string" then
			for i, item in ipairs(t) do
				local lines, slots = {}, {}
				for _, l in ipairs(item) do lines[#lines + 1] = l end
				for ty in pairs(item.types or {}) do slots[#slots + 1] = ty end
				table.sort(slots)
				addEntry(idx, { src = "enchant:" .. slot, id = (kind or "?") .. "#" .. i, name = kind, lines = lines, spawnOn = #slots > 0 and slots or nil })
			end
			return
		end
		for k, v in pairs(t) do
			if type(v) == "table" then walkEnchants(slot, type(k) == "string" and (kind and kind .. " " .. k or k) or kind, v, depth + 1) end
		end
	end
	for _, slot in ipairs({ "Helmet", "Boots", "Gloves", "Belt", "Body Armour", "Weapon", "UtilityFlask" }) do
		local enchs = data.enchantments and data.enchantments[slot]
		if type(enchs) == "table" then walkEnchants(slot, nil, enchs, 0) end
	end

	for i, m in ipairs(data.masterMods or {}) do
		local slots = {}
		for slot in pairs(m.types or {}) do slots[#slots + 1] = slot end
		table.sort(slots)
		addEntry(idx, { src = "mod:Crafted", id = "craft#" .. i, name = m.affix, kind = m.type, level = m.level,
			lines = modLines(m), tags = m.modTags, spawnOn = slots, group = m.group })
	end

	for name, base in pairs(data.itemBases or {}) do
		local lines = {}
		if base.implicit then
			for l in base.implicit:gmatch("[^\n]+") do lines[#lines + 1] = l end
		end
		for _, l in ipairs(base.flask and base.flask.buff or {}) do lines[#lines + 1] = l end
		if #lines > 0 then
			addEntry(idx, { src = "base:" .. (base.type or "Other"):lower(), id = name, name = name, kind = base.subType, lines = lines })
		end
	end

	for godId, god in pairs(data.pantheons or {}) do
		for i, soul in ipairs(god.souls or {}) do
			local lines = {}
			for _, m in ipairs(soul.mods or {}) do lines[#lines + 1] = m.line end
			addEntry(idx, { src = "pantheon:" .. (god.isMajorGod and "major" or "minor"), id = godId .. "#" .. i,
				name = soul.name, kind = i == 1 and "Base" or "Upgrade", lines = lines })
		end
	end

	local allMods = data.itemMods.Item or {}
	for id, e in pairs(data.essences or {}) do
		if type(e) == "table" then
			local lines, slots, seen = {}, {}, {}
			for slot, modId in pairs(e.mods or {}) do
				local m = allMods[modId]
				for _, text in ipairs(m and modLines(m) or { tostring(modId) }) do
					if not seen[text] then
						seen[text] = true
						lines[#lines + 1] = text
						slots[text] = {}
					end
					table.insert(slots[text], slot)
				end
			end
			table.sort(lines)
			local spawnOn = {}
			for _, text in ipairs(lines) do
				table.sort(slots[text])
				spawnOn[#spawnOn + 1] = text .. " <- " .. table.concat(slots[text], ", ")
			end
			addEntry(idx, { src = "essence", id = tostring(id), name = e.name, lines = lines, essenceSlots = spawnOn })
		end
	end

	for id, g in pairs(data.gems or {}) do
		addEntry(idx, {
			src = "gem", id = id, name = g.name, kind = g.tagString,
			lines = { g.tagString or "", g.grantedEffect and g.grantedEffect.description or "" },
		})
	end

	return idx
end

function M.listSources(idx)
	local out = {}
	for _, s in ipairs(idx.order) do out[#out + 1] = idx.sources[s] end
	table.sort(out, function(a, b) return a.src < b.src end)
	return out
end

local SYN = {
	immune = { "immun", "cannot be", "unaffected by" },
	immunity = { "immun", "cannot be", "unaffected by" },
	avoid = { "avoid", "cannot be", "immun", "unaffected by" },
	resist = { "resistance" }, resistance = { "resistance" },
	life = { "maximum life", "life" },
	crit = { "critical strike" }, damage = { "damage" },
	speed = { "speed" }, regen = { "regenerat" }, leech = { "leech" },
	poison = { "poison" }, bleed = { "bleed" }, ignite = { "ignite", "burn" }, shock = { "shock" },
	freeze = { "freez", "frozen" }, chill = { "chill" }, stun = { "stun" }, curse = { "curse", "hex" },
	ms = { "movement speed" }, movespeed = { "movement speed" }, es = { "energy shield" },
	res = { "resistance" }, resists = { "resistance" }, resist = { "resist" }, phys = { "physical" },
	ele = { "elemental" }, regen = { "regenerat" }, suppression = { "suppress" }, pdr = { "physical damage reduction" },
	charges = { "charge" }, reservation = { "reserv" }, fortify = { "fortif" },
	pen = { "penetrat" }, penetration = { "penetrat" }, multi = { "multiplier" },
	aoe = { "area of effect" }, cdr = { "cooldown recovery" },
	dps = { "damage" }, aps = { "attack speed" }, cps = { "cast speed" }, inc = { "increased" },
	dot = { "damage over time" }, exposure = { "expos" }, conversion = { "converted to", "as extra" },
}
-- Short terms ("ms", "max") must start a word, otherwise they hit inside most words ("totems")
local function has(text, a)
	if #a <= 3 and a:match("^%w+$") then return text:find("%f[%w]" .. a) ~= nil end
	return text:find(a, 1, true) ~= nil
end

local function expand(term)
	local alts = SYN[term]
	if alts then return alts end
	if term:sub(-2) == "ed" and #term > 5 then return { term:sub(1, -3), term } end
	return { term }
end

function M.search(idx, query, opts)
	opts = opts or {}
	local terms = {}
	for t in lower(query):gmatch("%S+") do terms[#terms + 1] = opts.exact and { t } or expand(t) end
	local hits, total = {}, 0
	local bySource = {}
	local phrase = lower(query)
	local wantsMinion = phrase:find("minion", 1, true) ~= nil
	local wantsPresence = phrase:find("presence", 1, true) ~= nil
	for _, e in ipairs(idx.list) do
		local ok = opts.includeLegacy or not e.legacy
		if ok and opts.sources then
			ok = false
			for _, p in ipairs(opts.sources) do
				if e.src:sub(1, #p) == p then ok = true break end
			end
		end
		if ok and opts.slot and e.spawnOn then
			ok = false
			for _, s in ipairs(e.spawnOn) do
				if s == opts.slot then ok = true break end
			end
		end
		local function allTerms(text)
			for _, alts in ipairs(terms) do
				local hit = false
				for _, a in ipairs(alts) do
					if has(text, a) then hit = true break end
				end
				if not hit then return false end
			end
			return true
		end
		if ok then ok = allTerms(e.hay) end
		if ok and not allTerms(lower(e.name)) then
			ok = false
			for _, l in ipairs(e.lines) do
				if allTerms(l:lower()) then ok = true break end
			end
		end
		if ok then
			total = total + 1
			bySource[e.src] = (bySource[e.src] or 0) + 1
			local score = 0
			for _, l in ipairs(e.lines) do
				local ll = l:lower()
				if has(ll, phrase) then score = m_max(score, 3) end
				local n = 0
				for _, alts in ipairs(terms) do
					for _, a in ipairs(alts) do
						if has(ll, a) then n = n + 1 break end
					end
				end
				if n == #terms then score = m_max(score, 2) end
			end
			if not wantsMinion and e.hay:find("minion", 1, true) then score = score - 2 end
			if not wantsPresence and e.hay:find("in your presence", 1, true) then score = score - 2 end
			hits[#hits + 1] = { e = e, score = score, n = #e.lines, i = #hits }
		end
	end
	table.sort(hits, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		if a.n ~= b.n then return a.n < b.n end
		return a.i < b.i
	end)
	local res = {}
	for i = 1, math.min(#hits, opts.limit or 50) do res[i] = hits[i].e end
	return res, total, bySource, terms
end

function M.matchedLines(e, terms)
	local all, any = {}, {}
	for _, l in ipairs(e.lines) do
		local ll, n = l:lower(), 0
		for _, alts in ipairs(terms) do
			for _, a in ipairs(alts) do
				if has(ll, a) then n = n + 1 break end
			end
		end
		if n == #terms then all[#all + 1] = l end
		if n > 0 then any[#any + 1] = l end
	end
	return #all > 0 and all or any
end

return M
