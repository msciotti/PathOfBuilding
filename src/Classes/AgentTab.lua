-- Path of Building
--
-- Module: Agent Tab
-- Chat panel docked beside the current tab, talking to an external agent through the AgentBridge.
--
local t_insert = table.insert
local m_max = math.max
local m_floor = math.floor
local m_min = math.min

local TEXT_HEIGHT = 16
local PAD = 6
local HEADER = 28
local FOOTER = 34
local PANEL_LAYER = 50 -- above tree art (sublayers up to 30), below tooltips (100)
local REVEAL_CPS = 400 -- reply "typing" speed in chars per second, capped so long replies finish within REVEAL_MAX ms
local REVEAL_MAX = 3000

---@class AgentTab: ControlHost, Control
local AgentTabClass = newClass("AgentTab", "ControlHost", "Control")

---@param build Build
function AgentTabClass:AgentTab(build)
	self:ControlHost()
	self:Control()

	self.build = build
	self.wrapped = { }

	self.controls.connection = new("LabelControl"):LabelControl({"TOPLEFT",self,"TOPLEFT"}, {PAD + 2, PAD + 2, 0, 16}, function()
		return self:ConnectionText()
	end)
	self.controls.clear = new("ButtonControl"):ButtonControl({"TOPRIGHT",self,"TOPRIGHT"}, {-PAD, PAD, 50, 18}, "Clear", function()
		local chat = self:Chat()
		if chat then
			chat.messages = { }
			chat.delivered = 0
			chat.thinking = nil
		end
	end)
	self.controls.clear.tooltipText = "Clear the chat transcript."
	self.controls.scrollBar = new("ScrollBarControl"):ScrollBarControl({"TOPRIGHT",self,"TOPRIGHT"}, {-PAD, HEADER, 16, 0}, TEXT_HEIGHT * 3, "VERTICAL", true)
	self.controls.scrollBar.height = function()
		return self:TranscriptHeight()
	end
	self.controls.input = new("EditControl"):EditControl({"BOTTOMLEFT",self,"BOTTOMLEFT"}, {PAD + 2, -PAD, 0, 22}, "", nil, nil, 2000)
	self.controls.input.placeholder = "Ask about this build..."
	self.controls.input.width = function()
		return self.width - PAD * 3 - 2 - 56
	end
	self.controls.input.enterFunc = function()
		self:Send()
	end
	self.controls.send = new("ButtonControl"):ButtonControl({"LEFT",self.controls.input,"RIGHT"}, {PAD, 0, 56, 22}, "Send", function()
		self:Send()
	end)
	self.controls.send.enabled = function()
		return self.controls.input.buf:match("%S") ~= nil and self:Chat() ~= nil
	end
	return self
end

function AgentTabClass:Chat()
	return launch.agent and launch.agent.chat and launch.agent.chat()
end

function AgentTabClass:ConnectionText()
	local chat = self:Chat()
	if not chat then
		return "^1Agent bridge not running"
	elseif chat.waiting > 0 then
		return colorCodes.POSITIVE.."Agent connected ^7- listening"
	elseif GetTime() - chat.lastSeen < 120000 then
		return colorCodes.POSITIVE.."Agent connected ^7- working"
	end
	return "^8No agent connected (see agent/NOTES.md)"
end

function AgentTabClass:Send()
	local text = self.controls.input.buf:gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" or not self:Chat() then
		return
	end
	launch.agent.chatSend(text)
	self.controls.input:SetText("")
	self.stickToBottom = true
	self.refocusInput = true
end

function AgentTabClass:TranscriptHeight()
	return self.height - HEADER - FOOTER
end

local function wrapParagraph(lines, str, width, prefix)
	local lineStart, pos = 1, 1
	if str == "" then
		t_insert(lines, prefix)
		return
	end
	while pos <= #str do
		local ws, we = str:find("%s+", pos)
		local wordEnd = ws and (ws - 1) or #str
		if lineStart < pos and DrawStringWidth(TEXT_HEIGHT, "VAR", str:sub(lineStart, wordEnd)) > width then
			t_insert(lines, prefix..str:sub(lineStart, pos - 1):gsub("%s+$", ""))
			lineStart = pos
		end
		if not ws then
			t_insert(lines, prefix..str:sub(lineStart))
			break
		end
		pos = we + 1
	end
end

local function revealed(msg)
	if msg.role ~= "agent" or not msg.revealAt then
		return #msg.text
	end
	local elapsed = GetTime() - msg.revealAt
	local duration = m_min(REVEAL_MAX, #msg.text / REVEAL_CPS * 1000)
	if duration <= 0 or elapsed >= duration then
		msg.revealAt = nil
		return #msg.text
	end
	return m_floor(#msg.text * elapsed / duration)
end

local function wrapMessage(lines, msg, width, shown)
	if msg.role == "user" then
		t_insert(lines, colorCodes.MAGIC.."You")
	else
		t_insert(lines, colorCodes.UNIQUE.."Agent")
	end
	for _, step in ipairs(msg.thoughts or { }) do
		wrapParagraph(lines, step, width, "^8  ")
	end
	if msg.thoughts then
		t_insert(lines, "")
	end
	for para in (msg.text:sub(1, shown).."\n"):gmatch("(.-)\r?\n") do
		wrapParagraph(lines, para, width, "^7")
	end
	t_insert(lines, "")
end

function AgentTabClass:WrapTranscript(chat, width)
	local count = #chat.messages
	local last = chat.messages[count]
	local typing = last and last.revealAt ~= nil
	local settled = typing and count - 1 or count
	local key = settled..":"..width
	if self.wrapKey ~= key then
		self.wrapKey = key
		self.wrapped = { }
		for i = 1, settled do
			wrapMessage(self.wrapped, chat.messages[i], width, #chat.messages[i].text)
		end
	end
	if not typing and not chat.thinking then
		return self.wrapped
	end
	local lines = { }
	for i, line in ipairs(self.wrapped) do
		lines[i] = line
	end
	if typing then
		local shown = revealed(last)
		wrapMessage(lines, last, width, shown)
		if shown < #last.text then
			lines[#lines - 1] = lines[#lines - 1].."^8_"
		end
	else
		t_insert(lines, colorCodes.UNIQUE.."Agent")
		local steps = chat.thinking.steps
		local dots = string.rep(".", 1 + m_floor(GetTime() / 400) % 3)
		for i, step in ipairs(steps) do
			wrapParagraph(lines, step..(i == #steps and dots or ""), width, i == #steps and "^7  " or "^8  ")
		end
		if #steps == 0 then
			t_insert(lines, "^8  Thinking"..dots)
		end
	end
	return lines
end

function AgentTabClass:TranscriptBox()
	return self.x + PAD + 2, self.y + HEADER, self.width - PAD * 3 - 2 - 16, self:TranscriptHeight()
end

-- Called before the current tab so the panel can take its input first.
function AgentTabClass:ProcessInput(viewPort, inputEvents)
	self.x = viewPort.x
	self.y = viewPort.y
	self.width = viewPort.width
	self.height = viewPort.height

	local scrollBar = self.controls.scrollBar
	local boxX, boxY, boxW, boxH = self:TranscriptBox()
	local cursorX, cursorY = GetCursorPos()
	local overPanel = isMouseInRegion(viewPort)
	local overBox = cursorX >= boxX and cursorX < boxX + boxW and cursorY >= boxY and cursorY < boxY + boxH
	for id, event in ipairs(inputEvents) do
		local isMouse = event.key:match("BUTTON") or event.key:match("WHEEL")
		if isMouse and not overPanel then
			if event.type == "KeyDown" then
				self:SelectControl()
			end
		elseif event.type == "KeyUp" and overBox and scrollBar:IsScrollDownKey(event.key) then
			scrollBar:Scroll(1)
			inputEvents[id] = nil
		elseif event.type == "KeyUp" and overBox and scrollBar:IsScrollUpKey(event.key) then
			scrollBar:Scroll(-1)
			inputEvents[id] = nil
		end
	end
	if overPanel or self.selControl then
		local panelEvents, sourceIds = { }, { }
		for id, event in ipairs(inputEvents) do
			local isMouse = event.key:match("BUTTON") or event.key:match("WHEEL")
			if overPanel or not isMouse then
				t_insert(panelEvents, event)
				t_insert(sourceIds, id)
			end
		end
		self:ProcessControlsInput(panelEvents, viewPort)
		for i, id in ipairs(sourceIds) do
			local event = inputEvents[id]
			if panelEvents[i] == nil or (overPanel and (event.key:match("BUTTON") or event.key:match("WHEEL"))) then
				inputEvents[id] = nil
			end
		end
	end
	if self.refocusInput then
		self.refocusInput = false
		self:SelectControl(self.controls.input)
	end
end

-- Called after the current tab so the panel is drawn over anything the tab draws outside its viewport.
function AgentTabClass:Draw(viewPort)
	local chat = self:Chat()
	local scrollBar = self.controls.scrollBar
	local boxX, boxY, boxW, boxH = self:TranscriptBox()

	SetDrawLayer(nil, PANEL_LAYER)

	SetDrawColor(0.1, 0.1, 0.1)
	DrawImage(nil, self.x, self.y, self.width, self.height)
	SetDrawColor(0.85, 0.85, 0.85)
	DrawImage(nil, self.x, self.y, 2, self.height)

	SetDrawColor(0.4, 0.4, 0.4)
	DrawImage(nil, boxX - 1, boxY - 1, boxW + 2, boxH + 2)
	SetDrawColor(0.03, 0.03, 0.03)
	DrawImage(nil, boxX, boxY, boxW, boxH)

	if chat then
		local lines = self:WrapTranscript(chat, boxW - PAD * 2)
		local atBottom = scrollBar.offset >= (scrollBar.offsetMax or 0)
		scrollBar:SetContentDimension(#lines * TEXT_HEIGHT + PAD, boxH)
		if atBottom or self.stickToBottom then
			scrollBar:SetOffset(scrollBar.offsetMax or 0)
			self.stickToBottom = false
		end
		SetViewport(boxX + PAD, boxY + PAD / 2, boxW - PAD * 2, boxH - PAD)
		local first = m_max(1, m_floor(scrollBar.offset / TEXT_HEIGHT))
		for i = first, #lines do
			local y = (i - 1) * TEXT_HEIGHT - scrollBar.offset
			if y > boxH then
				break
			end
			DrawString(0, y, "LEFT", TEXT_HEIGHT, "VAR", lines[i])
		end
		if #lines == 0 then
			local hint = { }
			wrapParagraph(hint, "Messages you send here go to the connected agent, which can search PoB's data and test changes on this build.", boxW - PAD * 2, "^8")
			for i, line in ipairs(hint) do
				DrawString(0, (i - 1) * TEXT_HEIGHT, "LEFT", TEXT_HEIGHT, "VAR", line)
			end
		end
		SetViewport()
	end

	-- Like DrawControls, but back on the panel's layer before each control: Edit/Button controls reset the
	-- sublayer to 0 after drawing a hover tooltip, which would put later controls under the panel background
	for _, control in pairs(self.controls) do
		if control:IsShown() and control.Draw then
			SetDrawLayer(nil, PANEL_LAYER)
			control:Draw(viewPort, self.selControl and self.selControl.hasFocus and self.selControl ~= control)
		end
	end
	SetDrawLayer(nil, 0)
end
