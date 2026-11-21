-- Agent data layer: flat, searchable index over every game-data source PoB holds.
-- Pure data: no UI, no state mutation. Entries are { src, id, name, lines, ... }.
local M = {}

local function lower(s) return (s or ""):lower() end

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

function M.build(data, tree)
	local idx = { list = {}, sources = {}, order = {} }

	for srcName, mods in pairs(data.itemMods) do
		if srcName ~= "Item" then
			for id, m in pairs(mods) do
				if type(m) == "table" then
					addEntry(idx, {
						src = "mod:" .. srcName, id = id, name = m.affix ~= "" and m.affix or nil,
						kind = m.type, level = m.level, lines = modLines(m),
						tags = m.modTags, spawnOn = eligibleSlots(m), group = m.group,
					})
				end
			end
		end
	end

	if tree and tree.nodes then
		for id, n in pairs(tree.nodes) do
			if n.sd and #n.sd > 0 and n.type ~= "ClassStart" then
				addEntry(idx, {
					src = "passive:" .. (n.type or "Normal"):lower(), id = tostring(id), name = n.dn,
					kind = n.type, lines = n.sd, ascendancy = n.ascendancyName,
				})
			end
		end
	end

	local metaPrefix = { "League:", "Source:", "Variant:", "Requires", "Implicits:", "LevelReq:", "Has Alt", "Selected Variant", "Item Class:", "Rarity:", "Limited to:", "Radius:", "Upgrade:", "Sockets:", "Talisman Tier:" }
	local function isMeta(l)
		for _, p in ipairs(metaPrefix) do if l:sub(1, #p) == p then return true end end
		return false
	end
	for typeName, list in pairs(data.uniques or {}) do
		for _, raw in ipairs(list) do
			local all = {}
			for l in raw:gmatch("[^\r\n]+") do all[#all + 1] = l end
			local name = table.remove(all, 1)
			local base = table.remove(all, 1)
			local lines = {}
			for _, l in ipairs(all) do
				if not isMeta(l) then
					l = l:gsub("^{[^}]*}", ""):gsub("^{[^}]*}", "")
					lines[#lines + 1] = l
				end
			end
			if name and name ~= "" and name:sub(1, 11) ~= "Item Class:" then
				addEntry(idx, { src = "unique:" .. typeName, id = name, name = name, kind = base and base:gsub("^{[^}]*}", ""), lines = lines })
			end
		end
	end

	for slot, enchs in pairs(data.enchantments or {}) do
		for kind, lst in pairs(enchs) do
			if type(lst) == "table" then
				for i, e in ipairs(lst) do
					local text = type(e) == "table" and table.concat(e, "/") or tostring(e)
					addEntry(idx, { src = "enchant:" .. slot, id = kind .. "#" .. i, name = kind, lines = { text } })
				end
			end
		end
	end

	for id, e in pairs(data.essences or {}) do
		if type(e) == "table" then
			local lines = {}
			for slot, text in pairs(e.mods or {}) do lines[#lines + 1] = slot .. ": " .. tostring(text) end
			addEntry(idx, { src = "essence", id = tostring(id), name = e.name, lines = lines })
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

-- Each query term expands to alternatives (OR); terms are ANDed. Unknown terms match literally.
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
}
local function expand(term)
	local alts = SYN[term]
	if alts then return alts end
	if term:sub(-2) == "ed" and #term > 5 then return { term:sub(1, -3), term } end
	return { term }
end

-- opts: { sources = {"mod:Flask","passive"}, slot = "boots", limit = 50, exact = false }
function M.search(idx, query, opts)
	opts = opts or {}
	local terms = {}
	for t in lower(query):gmatch("%S+") do terms[#terms + 1] = opts.exact and { t } or expand(t) end
	local res, total = {}, 0
	local bySource = {}
	for _, e in ipairs(idx.list) do
		local ok = true
		if opts.sources then
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
		if ok then
			for _, alts in ipairs(terms) do
				local hit = false
				for _, a in ipairs(alts) do
					if e.hay:find(a, 1, true) then hit = true break end
				end
				if not hit then ok = false break end
			end
		end
		if ok then
			total = total + 1
			bySource[e.src] = (bySource[e.src] or 0) + 1
			if #res < (opts.limit or 50) then res[#res + 1] = e end
		end
	end
	return res, total, bySource
end

return M
