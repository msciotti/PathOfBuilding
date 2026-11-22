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
	if userIdle() then
		-- Block briefly instead of rendering at full rate; wakes immediately on a connection or data.
		local socks = { server }
		for _, cl in ipairs(clients) do socks[#socks + 1] = cl.sock end
		require("socket").select(socks, nil, 0.25)
	end
	local c = server:accept()
	if c then c:settimeout(0) clients[#clients + 1] = { sock = c, buf = "" } end
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
				cl.sock:send((okj and s or '{"error":"encode failed"}') .. "\n")
			end
		end
		if err == "closed" then cl.sock:close() table.remove(clients, i) end
	end
	chat().waiting = waiting
end

return M
