--[[
  PlayerTools/AtaraxiaLibrary.lua
  Obsidian-compatible Library API â†’ Roster chrome (Ataraxia)
  Returned by loadstring like deividcomsono/Obsidian Library.lua
]]

local Players = game:GetService('Players')
local UserInputService = game:GetService('UserInputService')
local RunService = game:GetService('RunService')
local TweenService = game:GetService('TweenService')
local TextService = game:GetService('TextService')
local GuiService = game:GetService('GuiService')
local LocalPlayer = Players.LocalPlayer

local C = {
	bg0 = Color3.fromRGB(10, 10, 10),
	bg1 = Color3.fromRGB(17, 17, 17),
	bg2 = Color3.fromRGB(26, 26, 26),
	bg3 = Color3.fromRGB(36, 36, 36),
	line = Color3.fromRGB(48, 48, 48),
	text = Color3.fromRGB(242, 242, 242),
	muted = Color3.fromRGB(138, 138, 138),
	accent = Color3.fromRGB(255, 255, 255),
	danger = Color3.fromRGB(255, 107, 107),
}

local Library = {
	Options = {},
	Toggles = {},
	Tabs = {},
	ActiveTab = nil,
	MinSize = Vector2.new(880, 560),
	OriginalMinSize = Vector2.new(880, 560),
	DPIScale = 1,
	Toggled = true,
	Open = true,
	Unloaded = false,
	ShowCustomCursor = false,
	ToggleKeybind = nil,
	Backend = 'Ataraxia',
	Animations = {
		TabSwitch = false,
		Dropdown = false,
		KeyPicker = false,
	},
	Scheme = {
		Font = Enum.Font.SourceSans,
	},
	ScreenGui = nil,
	_conns = {},
	_toasts = nil,
}

local function track(conn)
	Library._conns[#Library._conns + 1] = conn
	return conn
end

local function corner(parent, r)
	local c = Instance.new('UICorner')
	c.CornerRadius = UDim.new(0, r or 4)
	c.Parent = parent
	return c
end

local function hairline(parent, _radius)
	-- Stroke on the control itself. A full-size overlay Frame (old Hairline) sits above
	-- children under ZIndexBehavior.Sibling and eats dropdown/option clicks.
	local s = Instance.new('UIStroke')
	s.Name = 'HairlineStroke'
	s.Color = C.line
	s.Thickness = 1
	s.Transparency = 0.15
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function mkLabel(parent, text, props)
	props = props or {}
	local l = Instance.new('TextLabel')
	l.BackgroundTransparency = 1
	-- SourceSansPro keeps thin glyphs (z) readable at small sizes; Gotham drops them.
	l.Font = props.font or Enum.Font.SourceSans
	l.TextSize = props.size or 14
	l.TextColor3 = props.color or C.text
	l.TextXAlignment = props.x or Enum.TextXAlignment.Left
	l.TextYAlignment = props.y or Enum.TextYAlignment.Center
	l.Text = text or ''
	l.Size = props.size2 or UDim2.new(1, 0, 0, 18)
	l.Position = props.pos or UDim2.new()
	l.TextWrapped = props.wrap == true
	l.TextTruncate = props.truncate or Enum.TextTruncate.None
	l.TextScaled = false
	l.RichText = false
	l.ZIndex = props.z or ((parent.ZIndex or 1) + 1)
	l.Parent = parent
	return l
end

function Library:GetTextBounds(_, Text, Font, Size, Width)
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(
			tostring(Text or ''),
			Size or 14,
			Font or self.Scheme.Font,
			Vector2.new(Width or 1e5, 1e5)
		)
	end)
	if ok and typeof(bounds) == 'Vector2' then
		return bounds.X, bounds.Y
	end
	local t = tostring(Text or '')
	return math.max(8, #t * (Size or 14) * 0.52), (Size or 14) + 4
end

function Library:GetCustomIcon()
	return nil
end

function Library:AddContextMenu()
	return {
		Open = function() end,
		SetSize = function() end,
		Size = UDim2.new(),
		Active = false,
	}
end

function Library:PlayTabAnimation() end

function Library:Notify(text, duration)
	if type(self.IsNotifyEnabled) == 'function' and self:IsNotifyEnabled() ~= true then
		return
	end
	duration = tonumber(duration) or 5
	-- Own ScreenGui: the in-window toast holder is 40px and clips multiline text.
	local pg = LocalPlayer and LocalPlayer:FindFirstChildOfClass('PlayerGui')
	if not pg then
		warn('[Ataraxia] ' .. tostring(text))
		return
	end
	local gui = pg:FindFirstChild('SB2Toasts')
	if not (typeof(gui) == 'Instance' and gui:IsA('ScreenGui')) then
		gui = Instance.new('ScreenGui')
		gui.Name = 'SB2Toasts'
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 100000
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		if type(protectgui) == 'function' then
			pcall(protectgui, gui)
		end
		gui.Parent = pg
		local holder = Instance.new('Frame')
		holder.Name = 'Holder'
		holder.BackgroundTransparency = 1
		holder.ClipsDescendants = false
		holder.Size = UDim2.fromOffset(380, 700)
		holder.Position = UDim2.new(1, -396, 0, 16)
		holder.Parent = gui
	end
	local holder = gui:FindFirstChild('Holder')
	if not holder then
		warn('[Ataraxia] ' .. tostring(text))
		return
	end
	holder.Position = UDim2.new(1, -396, 0, 16)
	if not holder:FindFirstChildOfClass('UIListLayout') then
		local lay = Instance.new('UIListLayout')
		lay.SortOrder = Enum.SortOrder.LayoutOrder
		lay.Padding = UDim.new(0, 8)
		lay.Parent = holder
	end
	-- Cap stacked toasts so a notify storm cannot fill the screen.
	local existing = {}
	for _, ch in ipairs(holder:GetChildren()) do
		if ch:IsA('GuiObject') and ch.Name == 'Toast' then
			existing[#existing + 1] = ch
		end
	end
	while #existing >= 4 do
		local oldest = table.remove(existing, 1)
		pcall(function()
			oldest:Destroy()
		end)
	end
	local body = tostring(text):gsub('\r\n', '\n'):gsub('\r', '\n')
	local rows = {}
	local start = 1
	while true do
		local nl = string.find(body, '\n', start, true)
		rows[#rows + 1] = string.sub(body, start, nl and (nl - 1) or #body)
		if not nl then
			break
		end
		start = nl + 1
	end
	if #rows == 0 then
		rows[1] = body
	end
	local fontSize = 14
	local lineH = 20
	local barH = 4
	local t = Instance.new('Frame')
	t.Name = 'Toast'
	t.Size = UDim2.new(1, 0, 0, 22 + #rows * lineH + barH)
	t.BackgroundColor3 = C.bg2
	t.BorderSizePixel = 0
	t.ClipsDescendants = true
	t.Parent = holder
	corner(t, 6)
	local outline = Instance.new('UIStroke')
	outline.Name = 'ToastOutline'
	outline.Color = Color3.fromRGB(255, 255, 255)
	outline.Thickness = 1
	outline.Transparency = 0
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	outline.Parent = t
	for i, row in ipairs(rows) do
		local l = mkLabel(t, row, {
			size = fontSize,
			size2 = UDim2.new(1, -24, 0, lineH),
			pos = UDim2.fromOffset(12, 10 + (i - 1) * lineH),
			wrap = false,
			y = Enum.TextYAlignment.Center,
		})
		l.ZIndex = (t.ZIndex or 1) + 1
	end
	local track = Instance.new('Frame')
	track.Name = 'TimeTrack'
	track.BackgroundColor3 = Color3.fromRGB(48, 48, 48)
	track.BorderSizePixel = 0
	track.Size = UDim2.new(1, -16, 0, barH)
	track.Position = UDim2.new(0, 8, 1, -(barH + 6))
	track.ZIndex = (t.ZIndex or 1) + 1
	track.Parent = t
	corner(track, 2)
	local fill = Instance.new('Frame')
	fill.Name = 'TimeFill'
	fill.BackgroundColor3 = Color3.new(1, 1, 1)
	fill.BorderSizePixel = 0
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.Parent = track
	corner(fill, 2)
	TweenService:Create(fill, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
		Size = UDim2.new(0, 0, 1, 0),
	}):Play()
	local flash = Instance.new('Frame')
	flash.Name = 'Flash'
	flash.BackgroundColor3 = Color3.new(1, 1, 1)
	flash.BackgroundTransparency = 0.45
	flash.BorderSizePixel = 0
	flash.Size = UDim2.new(1, 0, 1, 0)
	flash.ZIndex = (t.ZIndex or 1) + 8
	flash.Parent = t
	corner(flash, 6)
	TweenService:Create(flash, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()
	task.delay(0.3, function()
		if flash.Parent then
			flash:Destroy()
		end
	end)
	task.delay(duration, function()
		if t.Parent then
			t:Destroy()
		end
	end)
end

function Library:Toggle(force)
	if force == true or force == false then
		self.Toggled = force
	else
		self.Toggled = not self.Toggled
	end
	self.Open = self.Toggled
	local main = self.ScreenGui and self.ScreenGui:FindFirstChild('Main')
	if main then
		main.Visible = self.Toggled
	end
	if self._showPill then
		self._showPill.Visible = not self.Toggled
	end
	if self.ScreenGui then
		self.ScreenGui.Enabled = true
	end
	-- Only force-show the cursor while the full menu is open.
	if self.Toggled then
		UserInputService.MouseIconEnabled = true
		pcall(function()
			UserInputService.OverrideMouseIconBehavior = Enum.OverrideMouseIconBehavior.ForceShow
		end)
	else
		pcall(function()
			UserInputService.OverrideMouseIconBehavior = Enum.OverrideMouseIconBehavior.None
		end)
	end
end

local function makeShowPill(gui, title)
	local pill = Instance.new('TextButton')
	pill.Name = 'ShowPill'
	pill.AutoButtonColor = false
	pill.Text = ''
	pill.BorderSizePixel = 0
	pill.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
	pill.BackgroundTransparency = 0.08
	pill.Size = UDim2.fromOffset(152, 48)
	pill.Position = UDim2.new(0.5, -76, 1, -72)
	pill.AnchorPoint = Vector2.new(0, 0)
	pill.Visible = false
	pill.ZIndex = 200
	pill.Parent = gui
	corner(pill, 24)
	hairline(pill, 24)

	-- Four-petal mark (no remote asset).
	local mark = Instance.new('Frame')
	mark.Name = 'Mark'
	mark.BackgroundTransparency = 1
	mark.Size = UDim2.fromOffset(22, 22)
	mark.Position = UDim2.fromOffset(14, 13)
	mark.ZIndex = 201
	mark.Parent = pill
	for i = 0, 3 do
		local petal = Instance.new('Frame')
		petal.BackgroundColor3 = C.text
		petal.BorderSizePixel = 0
		petal.Size = UDim2.fromOffset(6, 10)
		petal.AnchorPoint = Vector2.new(0.5, 1)
		petal.Position = UDim2.fromScale(0.5, 0.5)
		petal.Rotation = i * 90
		petal.ZIndex = 202
		petal.Parent = mark
		corner(petal, 3)
	end

	mkLabel(pill, tostring(title or 'Ataraxia'), {
		font = Enum.Font.SourceSansBold,
		size = 15,
		size2 = UDim2.new(1, -52, 0, 18),
		pos = UDim2.fromOffset(44, 7),
		z = 201,
	})
	mkLabel(pill, 'Tap to show', {
		font = Enum.Font.SourceSans,
		size = 12,
		color = C.muted,
		size2 = UDim2.new(1, -52, 0, 16),
		pos = UDim2.fromOffset(44, 25),
		z = 201,
	})

	local dragging, dragStart, startPos, moved = false, nil, nil, false
	pill.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			moved = false
			dragStart = input.Position
			startPos = pill.Position
		end
	end)
	track(UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		local d = input.Position - dragStart
		if d.Magnitude < 6 then
			return
		end
		moved = true
		pill.Position = UDim2.new(
			startPos.X.Scale,
			startPos.X.Offset + d.X,
			startPos.Y.Scale,
			startPos.Y.Offset + d.Y
		)
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		if dragging and not moved then
			Library:Toggle(true)
		end
		dragging = false
		moved = false
	end))

	Library._showPill = pill
	return pill
end

function Library:Unload()
	if self.Config then
		pcall(self.Config.Finish)
	end
	self.Unloaded = true
	for _, c in ipairs(self._conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(self._conns)
	if self.ScreenGui then
		pcall(function()
			self.ScreenGui:Destroy()
		end)
	end
	self.ScreenGui = nil
	self._showPill = nil
	table.clear(self.Options)
	table.clear(self.Toggles)
	table.clear(self.Tabs)
	-- Anti-AFK and HideGameplayPaused stay armed across Unload so a script
	-- reload does not bring the idle kick or pause banner back.
end

---------------------------------------------------------------------------
-- Anti-AFK (Infinite Yield style) — built into every CreateWindow so games
-- do not each reimplement mute-Idled + VirtualUser. No jump / keys / camera.
---------------------------------------------------------------------------
local AntiAfk = (function()
	local api = {}
	local FILE = 'Ataraxia/antiafk'
	local remuteAt = 0
	local vuPulseAt = 0
	local rebindIdled

	local function fileDefaultOn()
		if type(isfile) == 'function' and type(readfile) == 'function' then
			local ok, exists = pcall(isfile, FILE)
			if ok and exists then
				local rok, body = pcall(readfile, FILE)
				if rok and tostring(body):lower():find('false', 1, true) then
					return false
				end
			end
		end
		return true
	end

	local function writeFile(on)
		if type(writefile) ~= 'function' then
			return
		end
		pcall(function()
			if type(makefolder) == 'function' and type(isfolder) == 'function' and not isfolder('Ataraxia') then
				makefolder('Ataraxia')
			end
		end)
		pcall(writefile, FILE, on and 'true' or 'false')
	end

	local function pulseVirtualUser(reason)
		pcall(function()
			local vu = game:GetService('VirtualUser')
			vu:CaptureController()
			vu:ClickButton2(Vector2.zero)
		end)
		getgenv().AtaraxiaAntiAfkLastPulse = os.clock()
		getgenv().AtaraxiaAntiAfkLastReason = reason or 'pulse'
	end

	-- Disable every Idled listener. getconnections() proxies are never == to the
	-- RBXScriptConnection from :Connect(), so we always re-bind ours afterward.
	local function muteIdledKick()
		if type(getconnections) ~= 'function' then
			return
		end
		pcall(function()
			for _, conn in ipairs(getconnections(LocalPlayer.Idled)) do
				pcall(function()
					if conn.Disable then
						conn:Disable()
					elseif conn.Disconnect then
						conn:Disconnect()
					end
				end)
			end
		end)
	end

	local function onIdled()
		if getgenv().AtaraxiaAntiAfkOn ~= true then
			return
		end
		pulseVirtualUser('idled')
		muteIdledKick()
		rebindIdled()
	end

	rebindIdled = function()
		local prev = getgenv().AtaraxiaAntiAfkConn
		if prev then
			pcall(function()
				prev:Disconnect()
			end)
		end
		getgenv().AtaraxiaAntiAfkConn = LocalPlayer.Idled:Connect(onIdled)
	end

	local function remuteAndRebind()
		muteIdledKick()
		rebindIdled()
	end

	function api.stop()
		getgenv().AtaraxiaAntiAfkOn = false
		local prev = getgenv().AtaraxiaAntiAfkConn
		if prev then
			pcall(function()
				prev:Disconnect()
			end)
		end
		getgenv().AtaraxiaAntiAfkConn = nil
		local pulse = getgenv().AtaraxiaAntiAfkPulse
		if pulse then
			pcall(function()
				pulse:Disconnect()
			end)
		end
		getgenv().AtaraxiaAntiAfkPulse = nil
		writeFile(false)
	end

	function api.start()
		local pulse = getgenv().AtaraxiaAntiAfkPulse
		if pulse then
			pcall(function()
				pulse:Disconnect()
			end)
		end
		getgenv().AtaraxiaAntiAfkOn = true
		writeFile(true)
		remuteAndRebind()
		getgenv().AtaraxiaAntiAfkPulse = RunService.Heartbeat:Connect(function()
			if getgenv().AtaraxiaAntiAfkOn ~= true then
				return
			end
			local now = os.clock()
			-- Remute often: engine can re-bind Idled kick listeners.
			if now - remuteAt >= 8 then
				remuteAt = now
				remuteAndRebind()
			end
			-- Backup VU click if Idled never fires (some clients stay quiet until kick).
			if now - vuPulseAt >= 540 then
				vuPulseAt = now
				pulseVirtualUser('heartbeat')
			end
		end)
		vuPulseAt = os.clock()
		remuteAt = os.clock()
	end

	function api.isOn()
		return getgenv().AtaraxiaAntiAfkOn == true
	end

	function api.ensure()
		if fileDefaultOn() then
			if not api.isOn() or not getgenv().AtaraxiaAntiAfkConn or not getgenv().AtaraxiaAntiAfkPulse then
				api.start()
			else
				remuteAndRebind()
			end
		end
	end

	return api
end)()

function Library:SetAntiAfk(on)
	if on == false then
		AntiAfk.stop()
	else
		AntiAfk.start()
	end
	return AntiAfk.isOn()
end

function Library:IsAntiAfk()
	return AntiAfk.isOn()
end

---------------------------------------------------------------------------
-- Invisicam. Games reset DevCameraOcclusionMode, so this re-applies. Opt out:
-- CreateWindow{ Invisicam = false }. Persists in Ataraxia/invisicam like Anti-AFK.
---------------------------------------------------------------------------
local Occlusion = (function()
	local api = {}
	local FILE = 'Ataraxia/invisicam'

	local function fileDefaultOn()
		if type(isfile) == 'function' and type(readfile) == 'function' then
			local ok, exists = pcall(isfile, FILE)
			if ok and exists then
				local rok, body = pcall(readfile, FILE)
				if rok and tostring(body):lower():find('false', 1, true) then
					return false
				end
			end
		end
		return true
	end

	local function writeFile(on)
		if type(writefile) ~= 'function' then
			return
		end
		pcall(function()
			if type(makefolder) == 'function' and type(isfolder) == 'function' and not isfolder('Ataraxia') then
				makefolder('Ataraxia')
			end
		end)
		pcall(writefile, FILE, on and 'true' or 'false')
	end

	local function savedMode()
		if getgenv().AtaraxiaSavedOcclusion == nil then
			pcall(function()
				getgenv().AtaraxiaSavedOcclusion = LocalPlayer.DevCameraOcclusionMode
			end)
		end
		return getgenv().AtaraxiaSavedOcclusion or Enum.DevCameraOcclusionMode.Zoom
	end

	local function apply(on)
		pcall(function()
			local want = on and Enum.DevCameraOcclusionMode.Invisicam or savedMode()
			if LocalPlayer.DevCameraOcclusionMode ~= want then
				LocalPlayer.DevCameraOcclusionMode = want
			end
		end)
	end

	function api.set(on)
		local want = on == true
		local was = getgenv().AtaraxiaInvisicamOn == true
		getgenv().AtaraxiaInvisicamOn = want
		apply(want)
		if was ~= want then
			writeFile(want)
		end
	end

	function api.isOn()
		return getgenv().AtaraxiaInvisicamOn == true
	end

	function api.tick()
		if getgenv().AtaraxiaInvisicamOn == true then
			apply(true)
		end
	end

	function api.ensure()
		if fileDefaultOn() then
			getgenv().AtaraxiaInvisicamOn = true
			apply(true)
		end
	end

	return api
end)()

function Library:SetInvisicam(on)
	if on == false then
		Occlusion.set(false)
	else
		Occlusion.set(true)
	end
	return Occlusion.isOn()
end

function Library:IsInvisicam()
	return Occlusion.isOn()
end

---------------------------------------------------------------------------
-- Hide Roblox "Gameplay Paused". The engine stall is not switchable from Lua;
-- this only keeps the CoreGui banner off. Opt out: CreateWindow{ HideGameplayPaused = false }.
-- Persists in Ataraxia/nopause. Stays armed across Unload like Anti-AFK.
---------------------------------------------------------------------------
local NoPause = (function()
	local api = {}
	local FILE = 'Ataraxia/nopause'
	local NAME = 'RobloxNetworkPauseNotification'

	local function fileDefaultOn()
		if type(isfile) == 'function' and type(readfile) == 'function' then
			local ok, exists = pcall(isfile, FILE)
			if ok and exists then
				local rok, body = pcall(readfile, FILE)
				if rok and tostring(body):lower():find('false', 1, true) then
					return false
				end
			end
		end
		return true
	end

	local function writeFile(on)
		if type(writefile) ~= 'function' then
			return
		end
		pcall(function()
			if type(makefolder) == 'function' and type(isfolder) == 'function' and not isfolder('Ataraxia') then
				makefolder('Ataraxia')
			end
		end)
		pcall(writefile, FILE, on and 'true' or 'false')
	end

	local function setEngineFlag(hide)
		pcall(function()
			GuiService:SetGameplayPausedNotificationEnabled(hide ~= true)
		end)
	end

	local function silence(sg)
		if not sg then
			return
		end
		pcall(function()
			if sg:IsA('LayerCollector') then
				sg.Enabled = false
			end
			if sg:IsA('GuiObject') then
				sg.Visible = false
			end
			for _, d in ipairs(sg:GetDescendants()) do
				if d:IsA('GuiObject') then
					d.Visible = false
				end
			end
		end)
	end

	local function hookOverlay(sg)
		if not sg then
			return
		end
		silence(sg)
		if sg:GetAttribute('AtaraxiaNoPause') == true then
			return
		end
		pcall(function()
			sg:SetAttribute('AtaraxiaNoPause', true)
		end)
		local hooks = getgenv().AtaraxiaNoPauseHooks
		if type(hooks) ~= 'table' then
			hooks = {}
			getgenv().AtaraxiaNoPauseHooks = hooks
		end
		if sg:IsA('LayerCollector') then
			hooks[#hooks + 1] = sg:GetPropertyChangedSignal('Enabled'):Connect(function()
				if getgenv().AtaraxiaNoPauseOn == true and sg.Enabled then
					silence(sg)
				end
			end)
		end
		hooks[#hooks + 1] = sg.DescendantAdded:Connect(function(d)
			if getgenv().AtaraxiaNoPauseOn == true and d:IsA('GuiObject') then
				pcall(function()
					d.Visible = false
				end)
			end
		end)
	end

	local function scan()
		local ok, CoreGui = pcall(function()
			return game:GetService('CoreGui')
		end)
		if not ok or not CoreGui then
			return
		end
		pcall(function()
			hookOverlay(CoreGui:FindFirstChild(NAME))
		end)
		pcall(function()
			local rg = CoreGui:FindFirstChild('RobloxGui')
			if not rg then
				return
			end
			for _, child in ipairs(rg:GetChildren()) do
				local n = child.Name
				if n == 'NetworkPause' or n == 'CoreScripts/NetworkPause' then
					hookOverlay(child)
				end
			end
		end)
	end

	local function dropHooks()
		local hooks = getgenv().AtaraxiaNoPauseHooks
		if type(hooks) == 'table' then
			for _, c in ipairs(hooks) do
				pcall(function()
					c:Disconnect()
				end)
			end
		end
		getgenv().AtaraxiaNoPauseHooks = {}
	end

	function api.stop()
		getgenv().AtaraxiaNoPauseOn = false
		local watch = getgenv().AtaraxiaNoPauseWatch
		if watch then
			pcall(function()
				watch:Disconnect()
			end)
		end
		getgenv().AtaraxiaNoPauseWatch = nil
		local tick = getgenv().AtaraxiaNoPauseTick
		if tick then
			pcall(function()
				tick:Disconnect()
			end)
		end
		getgenv().AtaraxiaNoPauseTick = nil
		dropHooks()
		setEngineFlag(false)
		pcall(function()
			local sg = game:GetService('CoreGui'):FindFirstChild(NAME)
			if sg and sg:IsA('LayerCollector') then
				sg.Enabled = true
			end
		end)
		writeFile(false)
	end

	function api.start()
		getgenv().AtaraxiaNoPauseOn = true
		writeFile(true)
		setEngineFlag(true)
		scan()
		if not getgenv().AtaraxiaNoPauseWatch then
			local ok, CoreGui = pcall(function()
				return game:GetService('CoreGui')
			end)
			if ok and CoreGui then
				getgenv().AtaraxiaNoPauseWatch = CoreGui.ChildAdded:Connect(function(ch)
					if getgenv().AtaraxiaNoPauseOn ~= true then
						return
					end
					if ch.Name == NAME or ch.Name == 'NetworkPause' then
						hookOverlay(ch)
					end
					setEngineFlag(true)
				end)
			end
		end
		if not getgenv().AtaraxiaNoPauseTick then
			getgenv().AtaraxiaNoPauseTick = RunService.Heartbeat:Connect(function()
				if getgenv().AtaraxiaNoPauseOn ~= true then
					return
				end
				local now = os.clock()
				if now - (getgenv().AtaraxiaNoPauseScanAt or 0) < 0.35 then
					return
				end
				getgenv().AtaraxiaNoPauseScanAt = now
				setEngineFlag(true)
				pcall(function()
					local sg = game:GetService('CoreGui'):FindFirstChild(NAME)
					if sg and sg:IsA('LayerCollector') and sg.Enabled then
						silence(sg)
					end
				end)
			end)
		end
	end

	function api.isOn()
		return getgenv().AtaraxiaNoPauseOn == true
	end

	function api.ensure()
		if fileDefaultOn() then
			api.start()
		end
	end

	return api
end)()

function Library:SetHideGameplayPaused(on)
	if on == false then
		NoPause.stop()
	else
		NoPause.start()
	end
	return NoPause.isOn()
end

function Library:IsHideGameplayPaused()
	return NoPause.isOn()
end

---------------------------------------------------------------------------
-- Notification mute. Library:Notify no-ops when off.
-- Persists in Ataraxia/notifications (default on). Shared across games.
---------------------------------------------------------------------------
local NotifyPref = (function()
	local api = {}
	local FILE = 'Ataraxia/notifications'
	local enabled = true

	local function readFile()
		if type(isfile) == 'function' and type(readfile) == 'function' then
			local ok, exists = pcall(isfile, FILE)
			if ok and exists then
				local rok, body = pcall(readfile, FILE)
				if rok and tostring(body):lower():find('false', 1, true) then
					return false
				end
			end
		end
		return true
	end

	local function writeFile(on)
		if type(writefile) ~= 'function' then
			return
		end
		pcall(function()
			if type(makefolder) == 'function' and type(isfolder) == 'function' and not isfolder('Ataraxia') then
				makefolder('Ataraxia')
			end
		end)
		pcall(writefile, FILE, on and 'true' or 'false')
	end

	enabled = readFile()

	function api.isOn()
		return enabled == true
	end

	function api.set(on)
		enabled = on ~= false
		writeFile(enabled)
		return enabled
	end

	return api
end)()

function Library:SetNotifyEnabled(on)
	return NotifyPref.set(on)
end

function Library:IsNotifyEnabled()
	return NotifyPref.isOn()
end

function Library:AddNotifyToggle(box)
	if not box or type(box.AddToggle) ~= 'function' then
		return
	end
	return box:AddToggle('ATA_Notifications', {
		Text = 'Show notifications',
		Default = NotifyPref.isOn(),
		Tooltip = 'Ataraxia toasts (Library:Notify). Off is saved in Ataraxia/notifications for every game.',
	}):OnChanged(function(v)
		Library:SetNotifyEnabled(v == true)
	end)
end

local function fireChanged(obj, value)
	for _, fn in ipairs(obj._changed or {}) do
		task.spawn(fn, value)
	end
end

local function attachOnChanged(obj)
	function obj:OnChanged(fn)
		self._changed = self._changed or {}
		self._changed[#self._changed + 1] = fn
		return self
	end
end

---------------------------------------------------------------------------
-- Controls
---------------------------------------------------------------------------
local function addToggle(box, idx, opts)
	opts = opts or {}
	local row = Instance.new('Frame')
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, -12, 0, 30)
	row.Parent = box.Container
	mkLabel(row, opts.Text or idx, {
		size = 14,
		size2 = UDim2.new(1, -54, 1, 0),
		pos = UDim2.fromOffset(0, 0),
		truncate = Enum.TextTruncate.AtEnd,
	})

	local on = opts.Default == true
	local pill = Instance.new('TextButton')
	pill.Size = UDim2.fromOffset(44, 24)
	pill.Position = UDim2.new(1, -44, 0.5, -12)
	pill.BackgroundColor3 = on and C.accent or C.bg3
	pill.Text = ''
	pill.AutoButtonColor = false
	pill.BorderSizePixel = 0
	pill.ZIndex = 5
	pill.Parent = row
	corner(pill, 12)
	local knob = Instance.new('Frame')
	knob.Size = UDim2.fromOffset(18, 18)
	knob.Position = on and UDim2.new(1, -21, 0.5, -9) or UDim2.fromOffset(3, 3)
	knob.BackgroundColor3 = on and C.bg0 or C.muted
	knob.BorderSizePixel = 0
	knob.ZIndex = 6
	knob.Parent = pill
	corner(knob, 9)

	local obj = {
		Type = 'Toggle',
		Idx = idx,
		Value = on,
		Destroyed = false,
		_changed = {},
	}
	attachOnChanged(obj)

	local function paint(v)
		obj.Value = v == true
		pill.BackgroundColor3 = obj.Value and C.accent or C.bg3
		knob.BackgroundColor3 = obj.Value and C.bg0 or C.muted
		knob.Position = obj.Value and UDim2.new(1, -21, 0.5, -9) or UDim2.fromOffset(3, 3)
	end

	function obj:SetValue(v)
		local nv = v == true
		if self.Value == nv then
			if self.Display then
				self:Display()
			end
			return
		end
		paint(nv)
		fireChanged(self, self.Value)
	end

	function obj:Display()
		paint(self.Value)
	end

	pill.MouseButton1Click:Connect(function()
		obj:SetValue(not obj.Value)
	end)

	Library.Toggles[idx] = obj
	Library.Options[idx] = obj
	box:_relayout()
	return obj
end

local function addButton(box, text, callback)
	local b = Instance.new('TextButton')
	b.Size = UDim2.new(1, -16, 0, 30)
	b.BackgroundColor3 = C.bg3
	b.Text = tostring(text or 'Button')
	b.TextColor3 = C.text
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 12
	b.AutoButtonColor = false
	b.BorderSizePixel = 0
	b.Parent = box.Container
	corner(b, 4)
	hairline(b, 4)
	b.MouseButton1Click:Connect(function()
		if type(callback) == 'function' then
			task.spawn(callback)
		end
	end)
	box:_relayout()
	return b
end

local function addSlider(box, idx, opts)
	opts = opts or {}
	local minV = tonumber(opts.Min) or 0
	local maxV = tonumber(opts.Max) or 100
	local rounding = tonumber(opts.Rounding) or 0
	local value = tonumber(opts.Default) or minV
	value = math.clamp(value, minV, maxV)

	local wrap = Instance.new('Frame')
	wrap.BackgroundTransparency = 1
	wrap.Size = UDim2.new(1, -16, 0, 44)
	wrap.Parent = box.Container

	local title = mkLabel(wrap, (opts.Text or idx) .. '  ' .. tostring(value), {
		size = 12,
		size2 = UDim2.new(1, 0, 0, 16),
	})
	local trackBar = Instance.new('Frame')
	trackBar.Size = UDim2.new(1, 0, 0, 8)
	trackBar.Position = UDim2.fromOffset(0, 26)
	trackBar.BackgroundColor3 = C.bg0
	trackBar.BorderSizePixel = 0
	trackBar.Parent = wrap
	corner(trackBar, 4)
	local fill = Instance.new('Frame')
	fill.Size = UDim2.new((value - minV) / math.max(1e-6, maxV - minV), 0, 1, 0)
	fill.BackgroundColor3 = C.accent
	fill.BorderSizePixel = 0
	fill.Parent = trackBar
	corner(fill, 4)

	local obj = {
		Type = 'Slider',
		Idx = idx,
		Value = value,
		Min = minV,
		Max = maxV,
		Destroyed = false,
		_changed = {},
	}
	attachOnChanged(obj)

	local function round(v)
		if rounding <= 0 then
			return math.floor(v + 0.5)
		end
		local m = 10 ^ rounding
		return math.floor(v * m + 0.5) / m
	end

	function obj:SetValue(v)
		v = round(math.clamp(tonumber(v) or minV, minV, maxV))
		self.Value = v
		fill.Size = UDim2.new((v - minV) / math.max(1e-6, maxV - minV), 0, 1, 0)
		title.Text = (opts.Text or idx) .. '  ' .. tostring(v)
		fireChanged(self, v)
	end

	local sliding = false
	trackBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			sliding = true
		end
	end)
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			sliding = false
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if sliding and input.UserInputType == Enum.UserInputType.MouseMovement then
			local rel = math.clamp((input.Position.X - trackBar.AbsolutePosition.X) / math.max(1, trackBar.AbsoluteSize.X), 0, 1)
			obj:SetValue(minV + rel * (maxV - minV))
		end
	end))

	Library.Options[idx] = obj
	box:_relayout()
	return obj
end

local function addInput(box, idx, opts)
	opts = opts or {}
	local wrap = Instance.new('Frame')
	wrap.BackgroundTransparency = 1
	wrap.Size = UDim2.new(1, -16, 0, opts.Text and 52 or 32)
	wrap.Parent = box.Container
	local y = 0
	if opts.Text then
		mkLabel(wrap, opts.Text, { size = 12, size2 = UDim2.new(1, 0, 0, 16) })
		y = 20
	end
	local boxIn = Instance.new('TextBox')
	boxIn.Size = UDim2.new(1, 0, 0, 28)
	boxIn.Position = UDim2.fromOffset(0, y)
	boxIn.BackgroundColor3 = C.bg0
	boxIn.TextColor3 = C.text
	boxIn.PlaceholderText = opts.Placeholder or ''
	boxIn.PlaceholderColor3 = C.muted
	boxIn.Text = tostring(opts.Default or '')
	boxIn.Font = Enum.Font.GothamMedium
	boxIn.TextSize = 12
	boxIn.ClearTextOnFocus = opts.ClearTextOnFocus == true
	boxIn.TextXAlignment = Enum.TextXAlignment.Left
	boxIn.BorderSizePixel = 0
	boxIn.Parent = wrap
	corner(boxIn, 4)
	hairline(boxIn, 4)
	local pad = Instance.new('UIPadding')
	pad.PaddingLeft = UDim.new(0, 8)
	pad.Parent = boxIn

	local obj = {
		Type = 'Input',
		Idx = idx,
		Value = boxIn.Text,
		Destroyed = false,
		_changed = {},
	}
	attachOnChanged(obj)

	function obj:SetValue(v)
		v = tostring(v or '')
		if opts.AllowEmpty == false and v == '' then
			return
		end
		self.Value = v
		boxIn.Text = v
		fireChanged(self, v)
	end

	local function commit()
		local v = boxIn.Text
		if opts.Numeric then
			v = tostring(tonumber(v) or obj.Value or '')
			boxIn.Text = v
		end
		if opts.AllowEmpty == false and v == '' then
			boxIn.Text = tostring(obj.Value or '')
			return
		end
		obj.Value = v
		fireChanged(obj, v)
		if type(opts.Callback) == 'function' then
			task.spawn(opts.Callback, v)
		end
	end

	if opts.Finished then
		-- Keep Value live while typing so other buttons (e.g. Test webhook) can read
		-- the pasted URL before FocusLost commits / fires Callback.
		boxIn:GetPropertyChangedSignal('Text'):Connect(function()
			obj.Value = boxIn.Text
		end)
		boxIn.FocusLost:Connect(function(enter)
			if enter or true then
				commit()
			end
		end)
	else
		boxIn:GetPropertyChangedSignal('Text'):Connect(function()
			obj.Value = boxIn.Text
			if type(opts.Callback) == 'function' then
				task.spawn(opts.Callback, boxIn.Text)
			end
			fireChanged(obj, boxIn.Text)
		end)
	end

	Library.Options[idx] = obj
	box:_relayout()
	return obj
end

local function flattenMultiDefault(default)
	if type(default) == 'table' then
		-- map or array
		local out = {}
		local isMap = false
		for k, v in pairs(default) do
			if type(k) == 'string' and v == true then
				isMap = true
				out[k] = true
			end
		end
		if isMap then
			return out
		end
		for _, v in ipairs(default) do
			if type(v) == 'string' then
				out[v] = true
			end
		end
		return out
	elseif type(default) == 'string' and default ~= '' then
		return { [default] = true }
	end
	return {}
end

local function addDropdown(box, idx, opts)
	opts = opts or {}
	local values = {}
	for _, v in ipairs(opts.Values or {}) do
		values[#values + 1] = v
	end
	local multi = opts.Multi == true
	local value
	if multi then
		value = flattenMultiDefault(opts.Default)
	else
		value = opts.Default
		if value == nil and not opts.AllowNull and values[1] then
			value = values[1]
		end
	end

	local wrap = Instance.new('Frame')
	wrap.BackgroundTransparency = 1
	wrap.Size = UDim2.new(1, -16, 0, 54)
	wrap.ClipsDescendants = false
	wrap.Parent = box.Container
	mkLabel(wrap, opts.Text or idx, {
		size = 13,
		size2 = UDim2.new(1, 0, 0, 16),
	})

	-- Closed field: plain Frame (NOT ScrollingFrame) + label + caret
	local field = Instance.new('Frame')
	field.Name = 'Field'
	field.Size = UDim2.new(1, 0, 0, 30)
	field.Position = UDim2.fromOffset(0, 20)
	field.BackgroundColor3 = C.bg0
	field.BorderSizePixel = 0
	field.ClipsDescendants = true
	field.Parent = wrap
	corner(field, 4)
	hairline(field, 4)

	local valueLbl = mkLabel(field, '', {
		size = 14,
		size2 = UDim2.new(1, -36, 1, 0),
		pos = UDim2.fromOffset(10, 0),
		truncate = Enum.TextTruncate.AtEnd,
	})
	valueLbl.ZIndex = 2

	local caret = mkLabel(field, '▼', {
		font = Enum.Font.SourceSansBold,
		size = 12,
		color = C.muted,
		size2 = UDim2.fromOffset(24, 30),
		pos = UDim2.new(1, -28, 0, 0),
		x = Enum.TextXAlignment.Center,
	})
	caret.ZIndex = 2

	local openBtn = Instance.new('TextButton')
	openBtn.Size = UDim2.fromScale(1, 1)
	openBtn.BackgroundTransparency = 1
	openBtn.Text = ''
	openBtn.AutoButtonColor = false
	openBtn.BorderSizePixel = 0
	openBtn.ZIndex = 3
	openBtn.Parent = field

	-- Popup on ScreenGui (not Main) so Main.ClipsDescendants cannot hide items.
	local listFrame = Instance.new('ScrollingFrame')
	listFrame.Name = 'DropdownList_' .. tostring(idx)
	listFrame.Visible = false
	listFrame.BackgroundColor3 = C.bg1
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 5
	listFrame.ScrollBarImageColor3 = C.muted
	listFrame.ScrollingDirection = Enum.ScrollingDirection.Y
	-- Manual CanvasSize in rebuild — AutomaticCanvasSize + scale-width rows collapsed to blank.
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.None
	listFrame.CanvasSize = UDim2.fromOffset(0, 0)
	listFrame.ZIndex = 2000
	listFrame.ClipsDescendants = true
	listFrame.Active = true
	listFrame.Parent = Library.ScreenGui or wrap
	corner(listFrame, 4)
	hairline(listFrame, 4)
	local listPad = Instance.new('UIPadding')
	listPad.PaddingTop = UDim.new(0, 4)
	listPad.PaddingBottom = UDim.new(0, 4)
	listPad.PaddingLeft = UDim.new(0, 4)
	listPad.PaddingRight = UDim.new(0, 4)
	listPad.Parent = listFrame
	local listLay = Instance.new('UIListLayout')
	listLay.Padding = UDim.new(0, 2)
	listLay.SortOrder = Enum.SortOrder.LayoutOrder
	listLay.Parent = listFrame

	local searchBox
	if opts.Searchable then
		searchBox = Instance.new('TextBox')
		-- Offset width — scale-X inside AutomaticCanvasSize ScrollingFrame collapses to 0.
		searchBox.Size = UDim2.fromOffset(180, 26)
		searchBox.BackgroundColor3 = C.bg0
		searchBox.TextColor3 = C.text
		searchBox.PlaceholderText = 'Filter...'
		searchBox.PlaceholderColor3 = C.muted
		searchBox.Text = ''
		searchBox.Font = Enum.Font.SourceSans
		searchBox.TextSize = 13
		searchBox.ClearTextOnFocus = false
		searchBox.BorderSizePixel = 0
		searchBox.ZIndex = 2010
		searchBox.LayoutOrder = 0
		searchBox.Parent = listFrame
		corner(searchBox, 3)
		local sp = Instance.new('UIPadding')
		sp.PaddingLeft = UDim.new(0, 8)
		sp.Parent = searchBox
	end

	local obj = {
		Type = 'Dropdown',
		Idx = idx,
		Value = value,
		Values = values,
		Multi = multi,
		Destroyed = false,
		_changed = {},
		_open = false,
		_ignoreAwayUntil = 0,
	}
	attachOnChanged(obj)

	local function displayText()
		if multi then
			local parts = {}
			for _, name in ipairs(obj.Values) do
				if type(obj.Value) == 'table' and obj.Value[name] then
					parts[#parts + 1] = name
				end
			end
			if #parts == 0 then
				return opts.AllowNull and 'None' or 'Select...'
			end
			return table.concat(parts, ', ')
		end
		if obj.Value == nil or obj.Value == '' then
			return opts.AllowNull and 'None' or 'Select...'
		end
		return tostring(obj.Value)
	end

	function obj:Display()
		valueLbl.Text = displayText()
		caret.Text = self._open and '▲' or '▼'
	end

	local function placePopup()
		if not field.Parent or not Library.ScreenGui then
			return
		end
		listFrame.Parent = Library.ScreenGui
		local fp = field.AbsolutePosition
		local fs = field.AbsoluteSize
		-- ScreenGui uses IgnoreGuiInset; AbsolutePosition is already screen-space.
		local nVals = 0
		if type(obj.Values) == 'table' then
			for _ in ipairs(obj.Values) do
				nVals += 1
			end
		end
		local maxH = math.min(220, 26 * math.min(10, math.max(1, nVals)) + (searchBox and 34 or 10))
		local width = math.max(fs.X, 180)
		local x = fp.X
		local y = fp.Y + fs.Y + 4
		-- Keep popup on-screen if field is near the bottom.
		local cam = workspace.CurrentCamera
		local vh = cam and cam.ViewportSize.Y or 800
		if y + maxH > vh - 8 then
			y = math.max(8, fp.Y - maxH - 4)
		end
		listFrame.Size = UDim2.fromOffset(width, maxH)
		listFrame.Position = UDim2.fromOffset(x, y)
		-- Keep filter/rows at offset width so they never collapse to 0.
		local innerW = math.max(width - 12, 160)
		if searchBox then
			searchBox.Size = UDim2.fromOffset(innerW, 26)
		end
		for _, ch in ipairs(listFrame:GetChildren()) do
			if ch:IsA('TextButton') then
				ch.Size = UDim2.fromOffset(innerW, 26)
			end
		end
	end

	local function closePopup()
		obj._open = false
		listFrame.Visible = false
		if Library._openDropdown == obj then
			Library._openDropdown = nil
		end
		obj:Display()
	end

	local function syncCanvas()
		local contentH = listLay.AbsoluteContentSize.Y
		if contentH < 8 then
			contentH = 0
			for _, ch in ipairs(listFrame:GetChildren()) do
				if ch:IsA('GuiObject') and not ch:IsA('UIListLayout') and not ch:IsA('UIPadding') then
					contentH += math.max(ch.AbsoluteSize.Y, 26) + 2
				end
			end
			contentH += 8
		end
		listFrame.CanvasSize = UDim2.fromOffset(0, math.max(contentH, 1))
		listFrame.CanvasPosition = Vector2.zero
		listFrame.ScrollBarThickness = contentH > (listFrame.AbsoluteSize.Y + 2) and 5 or 0
	end

	local rebuild
	local function makeRow(name, raw, order, innerW)
		local item = Instance.new('TextButton')
		item.Size = UDim2.fromOffset(innerW, 26)
		item.BackgroundColor3 = C.bg2
		item.BackgroundTransparency = 0
		item.TextColor3 = C.text
		item.Font = Enum.Font.SourceSans
		item.TextSize = 14
		item.TextXAlignment = Enum.TextXAlignment.Left
		item.AutoButtonColor = true
		item.BorderSizePixel = 0
		item.Text = '  ' .. name
		item.ZIndex = 2010
		item.Active = true
		item.LayoutOrder = order
		item.Parent = listFrame
		corner(item, 3)
		local selected = multi and type(obj.Value) == 'table' and obj.Value[name] or obj.Value == name or obj.Value == raw
		if selected then
			item.BackgroundColor3 = C.bg3
			item.Font = Enum.Font.SourceSansBold
			item.Text = '  ✓ ' .. name
		end
		item.MouseButton1Click:Connect(function()
			if multi then
				if type(obj.Value) ~= 'table' then
					obj.Value = {}
				end
				if obj.Value[name] then
					obj.Value[name] = nil
				else
					obj.Value[name] = true
				end
				obj:Display()
				rebuild()
				fireChanged(obj, obj.Value)
			else
				obj.Value = raw
				obj:Display()
				closePopup()
				fireChanged(obj, obj.Value)
			end
		end)
		return item
	end

	rebuild = function()
		for _, ch in ipairs(listFrame:GetChildren()) do
			if ch:IsA('TextButton') or (ch:IsA('TextLabel') and ch.Name == 'EmptyHint') then
				ch:Destroy()
			end
		end
		local filter = searchBox and string.lower(searchBox.Text or '') or ''
		local width = math.max(listFrame.AbsoluteSize.X, field.AbsoluteSize.X, 180)
		local innerW = math.max(width - 12, 160)
		if searchBox then
			searchBox.Size = UDim2.fromOffset(innerW, 26)
		end
		local count = 0
		local order = 1
		for _, raw in ipairs(obj.Values) do
			local name = tostring(raw)
			if filter == '' or string.find(string.lower(name), filter, 1, true) then
				count += 1
				order += 1
				makeRow(name, raw, order, innerW)
			end
		end
		-- Fallback if Values was stored as a map (Obsidian quirks).
		if count == 0 and type(obj.Values) == 'table' then
			for k, v in pairs(obj.Values) do
				local name = type(k) == 'string' and k or (type(v) == 'string' and v or nil)
				if name and (filter == '' or string.find(string.lower(name), filter, 1, true)) then
					count += 1
					order += 1
					makeRow(name, name, order, innerW)
				end
			end
		end
		if count == 0 then
			local empty = Instance.new('TextLabel')
			empty.Name = 'EmptyHint'
			empty.Size = UDim2.fromOffset(innerW, 26)
			empty.BackgroundTransparency = 1
			empty.TextColor3 = C.muted
			empty.Font = Enum.Font.SourceSans
			empty.TextSize = 13
			empty.TextXAlignment = Enum.TextXAlignment.Left
			empty.Text = filter ~= '' and '  No matches' or '  No options'
			empty.ZIndex = 2010
			empty.LayoutOrder = 1
			empty.Parent = listFrame
		end
		syncCanvas()
		task.defer(syncCanvas)
	end

	function obj:SetValues(list)
		self.Values = {}
		if type(list) == 'table' then
			local n = 0
			for _, v in ipairs(list) do
				n += 1
				self.Values[n] = v
			end
			if n == 0 then
				for k, v in pairs(list) do
					if type(k) == 'string' then
						self.Values[#self.Values + 1] = k
					elseif type(v) == 'string' then
						self.Values[#self.Values + 1] = v
					end
				end
			end
		end
		if self._open then
			rebuild()
			placePopup()
		end
		self:Display()
	end

	function obj:BuildDropdownList()
		if self._open then
			rebuild()
			placePopup()
		end
		self:Display()
	end

	function obj:SetValue(v)
		if multi then
			self.Value = flattenMultiDefault(v)
		else
			self.Value = v
		end
		self:Display()
		if self._open then
			rebuild()
		end
		fireChanged(self, self.Value)
	end

	local function toggleOpen()
		local opening = not obj._open
		if Library._openDropdown and Library._openDropdown ~= obj and type(Library._openDropdown) == 'table' then
			pcall(function()
				Library._openDropdown._open = false
				local other = Library.ScreenGui and Library.ScreenGui:FindFirstChild('DropdownList_' .. tostring(Library._openDropdown.Idx))
				if other then
					other.Visible = false
				end
				if type(Library._openDropdown.Display) == 'function' then
					Library._openDropdown:Display()
				end
			end)
		end
		obj._open = opening
		if obj._open then
			-- Ignore click-away before Visible flips — same press must not instantly close.
			obj._ignoreAwayUntil = os.clock() + 0.45
			Library._openDropdown = obj
			rebuild()
			placePopup()
			listFrame.Visible = true
			listFrame.ZIndex = 2000
			obj:Display()
		else
			closePopup()
		end
	end
	openBtn.MouseButton1Click:Connect(toggleOpen)
	if searchBox then
		searchBox:GetPropertyChangedSignal('Text'):Connect(function()
			rebuild()
		end)
	end

	-- click-away on InputEnded (InputBegan races the open click on some clients)
	track(UserInputService.InputEnded:Connect(function(input)
		if not obj._open then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		if os.clock() < (obj._ignoreAwayUntil or 0) then
			return
		end
		local p = input.Position
		local inField = p.X >= field.AbsolutePosition.X
			and p.X <= field.AbsolutePosition.X + field.AbsoluteSize.X
			and p.Y >= field.AbsolutePosition.Y
			and p.Y <= field.AbsolutePosition.Y + field.AbsoluteSize.Y
		local lp = listFrame.AbsolutePosition
		local ls = listFrame.AbsoluteSize
		local inList = listFrame.Visible
			and p.X >= lp.X
			and p.X <= lp.X + ls.X
			and p.Y >= lp.Y
			and p.Y <= lp.Y + ls.Y
		if not inField and not inList then
			closePopup()
		end
	end))

	obj:Display()
	Library.Options[idx] = obj
	box:_relayout()
	return obj
end

local function addLabel(box, text)
	local row = Instance.new('Frame')
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, -16, 0, 18)
	row.Parent = box.Container
	local lab = mkLabel(row, tostring(text or ''), {
		size = 11,
		color = C.muted,
		size2 = UDim2.new(1, 0, 1, 0),
		wrap = true,
	})
	-- grow with wrap
	row.Size = UDim2.new(1, -16, 0, math.max(18, select(2, Library:GetTextBounds(nil, text, nil, 11, 240))))

	local obj = {
		Type = 'Label',
		Text = tostring(text or ''),
		Destroyed = false,
	}
	function obj:SetText(t)
		self.Text = tostring(t or '')
		lab.Text = self.Text
	end

	function obj:AddKeyPicker(idx, opts)
		opts = opts or {}
		local key = tostring(opts.Default or 'Unknown')
		local kp = Instance.new('TextButton')
		kp.Size = UDim2.fromOffset(72, 22)
		kp.Position = UDim2.new(1, -72, 0.5, -11)
		kp.BackgroundColor3 = C.bg3
		kp.Text = key
		kp.TextColor3 = C.text
		kp.Font = Enum.Font.GothamBold
		kp.TextSize = 11
		kp.AutoButtonColor = false
		kp.BorderSizePixel = 0
		kp.Visible = opts.NoUI ~= true
		kp.Parent = row
		corner(kp, 4)

		local kobj = {
			Type = 'KeyPicker',
			Idx = idx,
			Value = key,
			Destroyed = false,
			_changed = {},
		}
		attachOnChanged(kobj)
		function kobj:SetValue(v)
			self.Value = tostring(v or 'Unknown')
			kp.Text = self.Value
			fireChanged(self, self.Value)
		end

		local listening = false
		kp.MouseButton1Click:Connect(function()
			listening = true
			kp.Text = '...'
		end)
		track(UserInputService.InputBegan:Connect(function(input, gp)
			if not listening then
				return
			end
			if input.UserInputType == Enum.UserInputType.Keyboard then
				listening = false
				kobj:SetValue(input.KeyCode.Name)
			end
		end))

		Library.Options[idx] = kobj
		box:_relayout()
		return kobj
	end

	box:_relayout()
	return obj
end

---------------------------------------------------------------------------
-- Groupbox / Tab / Window
---------------------------------------------------------------------------
local function makeGroupbox(sideParent, title)
	local holder = Instance.new('Frame')
	holder.Name = title or 'Groupbox'
	holder.BackgroundColor3 = C.bg1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.new(1, 0, 0, 60)
	holder.ClipsDescendants = true
	holder.Parent = sideParent
	corner(holder, 4)
	hairline(holder, 4)

	-- Clickable header (Obsidian accordion) — Wiki boxes start collapsed.
	local headBtn = Instance.new('TextButton')
	headBtn.Name = 'Header'
	headBtn.Size = UDim2.new(1, 0, 0, 36)
	headBtn.BackgroundTransparency = 1
	headBtn.Text = ''
	headBtn.AutoButtonColor = false
	headBtn.BorderSizePixel = 0
	headBtn.ZIndex = 3
	headBtn.Parent = holder

	local chevron = mkLabel(headBtn, '▼', {
		font = Enum.Font.SourceSansBold,
		size = 14,
		color = C.muted,
		size2 = UDim2.fromOffset(18, 36),
		pos = UDim2.fromOffset(10, 0),
		x = Enum.TextXAlignment.Center,
	})
	chevron.ZIndex = 4

	local head = mkLabel(headBtn, title or '', {
		font = Enum.Font.SourceSansBold,
		size = 15,
		size2 = UDim2.new(1, -40, 1, 0),
		pos = UDim2.fromOffset(32, 0),
	})
	head.ZIndex = 4

	local container = Instance.new('Frame')
	container.Name = 'Container'
	container.BackgroundTransparency = 1
	container.Position = UDim2.fromOffset(8, 38)
	container.Size = UDim2.new(1, -16, 0, 20)
	container.ZIndex = 2
	container.Parent = holder
	local lay = Instance.new('UIListLayout')
	lay.Padding = UDim.new(0, 6)
	lay.Parent = container

	local box = {
		Title = title,
		Holder = holder,
		Container = container,
		Collapsed = false,
	}

	function box:_relayout()
		if self.Collapsed then
			container.Visible = false
			chevron.Text = '▶'
			holder.Size = UDim2.new(1, 0, 0, 36)
			return
		end
		container.Visible = true
		chevron.Text = '▼'
		-- Defer: AbsoluteContentSize is often 0 the frame visibility flips.
		task.defer(function()
			if self.Collapsed or not holder.Parent then
				return
			end
			local h = lay.AbsoluteContentSize.Y
			if h < 8 then
				h = 0
				for _, ch in ipairs(container:GetChildren()) do
					if ch:IsA('GuiObject') and not ch:IsA('UIListLayout') and not ch:IsA('UIPadding') then
						h += math.max(ch.AbsoluteSize.Y, 18) + 6
					end
				end
			end
			h = math.max(h, 24)
			container.Size = UDim2.new(1, -16, 0, h)
			holder.Size = UDim2.new(1, 0, 0, h + 48)
		end)
	end

	function box:Resize()
		self:_relayout()
	end

	function box:SetCollapsed(v)
		self.Collapsed = v == true
		self:_relayout()
	end

	headBtn.MouseButton1Click:Connect(function()
		box:SetCollapsed(not box.Collapsed)
	end)

	function box:AddToggle(idx, opts)
		return addToggle(self, idx, opts)
	end
	function box:AddButton(text, cb)
		return addButton(self, text, cb)
	end
	function box:AddSlider(idx, opts)
		return addSlider(self, idx, opts)
	end
	function box:AddDropdown(idx, opts)
		return addDropdown(self, idx, opts)
	end
	function box:AddInput(idx, opts)
		return addInput(self, idx, opts)
	end
	function box:AddLabel(text)
		return addLabel(self, text)
	end

	track(lay:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
		box:_relayout()
	end))
	box:_relayout()
	return box
end

---------------------------------------------------------------------------
-- Account-based profiles.
-- Named files live in Ataraxia/<game>/profiles/ and are a shared list every
-- account can load. Autoload is Ataraxia/<game>/autoload/<account>.txt so a
-- save on one alt does not boot that profile on another. Each game folder is
-- its own set (Dungeon Lootr ≠ PlayerTools).
---------------------------------------------------------------------------
Library.Config = (function()
	local HttpService = game:GetService('HttpService')
	local KINDS = { Toggle = true, Slider = true, Dropdown = true, Input = true, KeyPicker = true }
	local SKIP_PREFIX = 'ATA_'
	local SAVE_DELAY = 1.5
	local api = {}
	local gameFolder = 'default'
	local skip = {}
	local suspended, dirty, saveAt = false, false, 0
	local defaults = nil
	local statusLabel = nil
	local assignedName = nil

	local function sanitize(s, fallback)
		s = tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')
		s = s:gsub('[^%w%._ %-]', '')
		s = s:gsub('%s+', ' ')
		if s == '' then
			return fallback or ''
		end
		if #s > 48 then
			s = s:sub(1, 48)
		end
		return s
	end

	local function accountKey()
		local name = string.lower(tostring(LocalPlayer.Name or 'unknown'))
		name = name:gsub('[^%w_%-]', '_')
		if name == '' then
			name = 'unknown'
		end
		return name
	end

	local function rootDir()
		return 'Ataraxia/' .. gameFolder
	end

	local function profileDir()
		return rootDir() .. '/profiles'
	end

	local function autoloadDir()
		return rootDir() .. '/autoload'
	end

	local function accountDir()
		return rootDir() .. '/accounts'
	end

	local function profilePath(name)
		return profileDir() .. '/' .. name .. '.json'
	end

	local function autoloadPath()
		return autoloadDir() .. '/' .. accountKey() .. '.txt'
	end

	local function accountPath()
		return accountDir() .. '/' .. accountKey() .. '.json'
	end

	local function ensureDirs()
		if type(makefolder) ~= 'function' then
			return
		end
		local function one(path)
			pcall(function()
				if type(isfolder) ~= 'function' or not isfolder(path) then
					makefolder(path)
				end
			end)
		end
		one('Ataraxia')
		one(rootDir())
		one(profileDir())
		one(autoloadDir())
		one(accountDir())
	end

	local function persistable(idx, obj)
		if type(idx) ~= 'string' or type(obj) ~= 'table' then
			return false
		end
		if skip[idx] or idx:sub(1, #SKIP_PREFIX) == SKIP_PREFIX then
			return false
		end
		return KINDS[obj.Type] == true and type(obj.SetValue) == 'function' and not obj.Destroyed
	end

	local function pack(v)
		local t = type(v)
		if t == 'boolean' or t == 'number' or t == 'string' then
			return v
		end
		if t == 'table' then
			local map = {}
			for k, on in pairs(v) do
				if type(k) == 'string' and on then
					map[k] = true
				end
			end
			return map
		end
		return nil
	end

	local function snapshot()
		local out = {}
		for idx, obj in pairs(Library.Options) do
			if persistable(idx, obj) then
				local v = pack(obj.Value)
				if v ~= nil then
					out[idx] = v
				end
			end
		end
		return out
	end

	local function writeJson(path, data)
		if type(writefile) ~= 'function' then
			return false
		end
		ensureDirs()
		local ok, encoded = pcall(function()
			return HttpService:JSONEncode(data)
		end)
		if not ok then
			return false
		end
		return pcall(writefile, path, encoded)
	end

	local function readJson(path)
		if type(isfile) ~= 'function' or type(readfile) ~= 'function' then
			return nil
		end
		local ok, exists = pcall(isfile, path)
		if not ok or not exists then
			return nil
		end
		local rok, body = pcall(readfile, path)
		if not rok then
			return nil
		end
		local dok, decoded = pcall(function()
			return HttpService:JSONDecode(body)
		end)
		if dok and type(decoded) == 'table' then
			return decoded
		end
		return nil
	end

	local function apply(data)
		if type(data) ~= 'table' then
			return 0
		end
		suspended = true
		local notify = Library.Notify
		Library.Notify = function() end
		local n = 0
		for idx, v in pairs(data) do
			local obj = Library.Options[idx]
			if persistable(idx, obj) then
				local ok = pcall(function()
					obj:SetValue(v)
				end)
				if ok then
					n += 1
				end
			end
		end
		Library.Notify = notify
		suspended = false
		dirty = false
		return n
	end

	local function setStatus()
		if not statusLabel or not statusLabel.SetText then
			return
		end
		local mine = api.GetAutoload()
		local who = tostring(LocalPlayer.Name or '?')
		if mine and mine ~= '' then
			statusLabel:SetText(('This account (%s) autoloads  ·  %s'):format(who, mine))
		else
			statusLabel:SetText(('This account (%s)  ·  personal save, no named autoload'):format(who))
		end
	end

	function api.SetFolder(name)
		gameFolder = sanitize(name, 'default'):gsub(' ', '-'):lower()
		if gameFolder == '' then
			gameFolder = 'default'
		end
		ensureDirs()
	end

	function api.IgnoreIndexes(map)
		if type(map) ~= 'table' then
			return
		end
		for k, v in pairs(map) do
			if v then
				skip[tostring(k)] = true
			end
		end
	end

	function api.List()
		local names = {}
		local seen = {}
		if type(listfiles) == 'function' then
			local ok, files = pcall(listfiles, profileDir())
			if ok and type(files) == 'table' then
				for _, path in ipairs(files) do
					local base = tostring(path):gsub('\\', '/'):match('([^/]+)%.json$')
					if base and not seen[base] then
						seen[base] = true
						names[#names + 1] = base
					end
				end
			end
		end
		table.sort(names, function(a, b)
			return string.lower(a) < string.lower(b)
		end)
		return names
	end

	function api.GetAutoload()
		if type(isfile) ~= 'function' or type(readfile) ~= 'function' then
			return nil
		end
		local path = autoloadPath()
		local ok, exists = pcall(isfile, path)
		if not ok or not exists then
			return nil
		end
		local rok, body = pcall(readfile, path)
		if not rok then
			return nil
		end
		local name = sanitize(body, '')
		if name == '' or name == 'none' then
			return nil
		end
		local pok, has = pcall(isfile, profilePath(name))
		if pok and has then
			return name
		end
		return nil
	end

	function api.SetAutoload(name)
		ensureDirs()
		name = sanitize(name, '')
		if name == '' then
			if type(delfile) == 'function' then
				pcall(delfile, autoloadPath())
			end
			assignedName = nil
			setStatus()
			return true
		end
		if type(writefile) ~= 'function' then
			return false
		end
		local ok = pcall(writefile, autoloadPath(), name)
		if ok then
			assignedName = name
			setStatus()
		end
		return ok
	end

	function api.HasState()
		if type(isfile) ~= 'function' then
			return false
		end
		local a = api.GetAutoload()
		if a then
			return true
		end
		local ok, exists = pcall(isfile, accountPath())
		return ok and exists == true
	end

	function api.SaveProfile(name)
		name = sanitize(name, '')
		if name == '' then
			return false, 'Name a profile first'
		end
		ensureDirs()
		if not writeJson(profilePath(name), snapshot()) then
			return false, 'Write failed'
		end
		api.SetAutoload(name)
		assignedName = name
		dirty = false
		api.RefreshUI()
		return true
	end

	function api.LoadProfile(name)
		name = sanitize(name, '')
		if name == '' then
			return 0
		end
		local data = readJson(profilePath(name))
		if not data then
			return 0
		end
		local n = apply(data)
		api.SetAutoload(name)
		assignedName = name
		return n
	end

	function api.DeleteProfile(name)
		name = sanitize(name, '')
		if name == '' or type(delfile) ~= 'function' then
			return false
		end
		pcall(delfile, profilePath(name))
		if api.GetAutoload() == name then
			api.SetAutoload(nil)
		end
		if assignedName == name then
			assignedName = nil
		end
		api.RefreshUI()
		return true
	end

	function api.SaveAccount()
		ensureDirs()
		if writeJson(accountPath(), snapshot()) then
			dirty = false
			return true
		end
		return false
	end

	function api.SaveCurrent()
		local name = assignedName or api.GetAutoload()
		if name and name ~= '' then
			local ok = api.SaveProfile(name)
			return ok
		end
		return api.SaveAccount()
	end

	function api.ImportTable(data)
		return apply(data)
	end

	function api.ImportFile(path)
		local data = readJson(path)
		if not data then
			return 0
		end
		return apply(data)
	end

	function api.LoadAutoload()
		local name = api.GetAutoload()
		if name then
			assignedName = name
			local n = 0
			local data = readJson(profilePath(name))
			if data then
				n = apply(data)
			end
			setStatus()
			api.RefreshUI()
			return n
		end
		assignedName = nil
		local data = readJson(accountPath())
		local n = apply(data)
		setStatus()
		api.RefreshUI()
		return n
	end

	function api.Reset()
		if defaults then
			apply(defaults)
		end
		api.SaveCurrent()
	end

	function api.Queue()
		if suspended then
			return
		end
		dirty = true
		saveAt = os.clock() + SAVE_DELAY
	end

	function api.Tick()
		if dirty and not suspended and os.clock() >= saveAt then
			api.SaveCurrent()
		end
	end

	function api.Hook()
		defaults = defaults or snapshot()
		for idx, obj in pairs(Library.Options) do
			if persistable(idx, obj) and type(obj.OnChanged) == 'function' then
				obj:OnChanged(api.Queue)
			end
		end
	end

	function api.Finish()
		if dirty then
			api.SaveCurrent()
		end
		suspended = true
	end

	function api.RefreshUI()
		local list = Library.Options.ATA_ProfileList
		if list and type(list.SetValues) == 'function' then
			local names = api.List()
			if #names == 0 then
				names = { '(none saved)' }
			end
			pcall(function()
				list:SetValues(names)
				local cur = assignedName or api.GetAutoload() or names[1]
				if cur then
					list:SetValue(cur)
				end
			end)
		end
		setStatus()
	end

	function api.Build(box)
		if not box then
			return
		end
		statusLabel = box:AddLabel('Profiles  ·  this account')
		box:AddDropdown('ATA_ProfileList', {
			Text = 'Saved profiles',
			Values = { '(none saved)' },
			Default = '(none saved)',
			Tooltip = 'Shared list for this game. Every account can load these. Autoload is per-account.',
		})
		box:AddInput('ATA_ProfileName', {
			Text = 'Profile name',
			Default = '',
			Placeholder = 'e.g. frost farm',
			Tooltip = 'Name used when you Save. Lives in Ataraxia/<game>/profiles/.',
		})
		box:AddButton('Save profile (this account autoloads it)', function()
			local typed = Library.Options.ATA_ProfileName and tostring(Library.Options.ATA_ProfileName.Value or '') or ''
			local picked = Library.Options.ATA_ProfileList and tostring(Library.Options.ATA_ProfileList.Value or '') or ''
			local name = sanitize(typed, '')
			if name == '' and picked ~= '' and picked ~= '(none saved)' then
				name = sanitize(picked, '')
			end
			local ok, err = api.SaveProfile(name)
			if ok then
				Library:Notify(('Saved "%s"  ·  autoload for %s only'):format(name, LocalPlayer.Name))
			else
				Library:Notify(err or 'Save failed')
			end
		end)
		box:AddButton('Load selected (this account)', function()
			local picked = Library.Options.ATA_ProfileList and tostring(Library.Options.ATA_ProfileList.Value or '') or ''
			picked = sanitize(picked, '')
			if picked == '' or picked == '(none saved)' then
				Library:Notify('Pick a profile first')
				return
			end
			local n = api.LoadProfile(picked)
			Library:Notify(n > 0 and ('Loaded "%s" for %s'):format(picked, LocalPlayer.Name) or 'Load failed')
		end)
		box:AddButton('Set selected as my autoload', function()
			local picked = Library.Options.ATA_ProfileList and tostring(Library.Options.ATA_ProfileList.Value or '') or ''
			picked = sanitize(picked, '')
			if picked == '' or picked == '(none saved)' then
				Library:Notify('Pick a profile first')
				return
			end
			if api.SetAutoload(picked) then
				assignedName = picked
				Library:Notify(('Autoload "%s" for %s'):format(picked, LocalPlayer.Name))
			end
		end)
		box:AddButton('Clear my autoload', function()
			api.SetAutoload(nil)
			api.SaveAccount()
			Library:Notify(('Autoload cleared for %s'):format(LocalPlayer.Name))
		end)
		box:AddButton('Delete selected profile', function()
			local picked = Library.Options.ATA_ProfileList and tostring(Library.Options.ATA_ProfileList.Value or '') or ''
			picked = sanitize(picked, '')
			if picked == '' or picked == '(none saved)' then
				Library:Notify('Pick a profile first')
				return
			end
			api.DeleteProfile(picked)
			Library:Notify(('Deleted "%s"'):format(picked))
		end)
		box:AddLabel('Other accounts see the same list. They do not autoload until they Load / Set autoload.')
		api.RefreshUI()
	end

	return api
end)()

function Library:SetFolder(name)
	if self.Config then
		self.Config.SetFolder(name)
	end
end

function Library:CreateWindow(info)
	info = info or {}
	if type(info.Folder) == 'string' and info.Folder ~= '' then
		self:SetFolder(info.Folder)
	end
	-- Floor size: scale-sized columns inside a ScrollingFrame collapse to ~0px otherwise.
	local width = math.max(880, (info.Size and info.Size.X.Offset) or 880)
	local height = math.max(560, (info.Size and info.Size.Y.Offset) or 560)
	self.MinSize = Vector2.new(880, 560)
	self.OriginalMinSize = self.MinSize

	if self.ScreenGui then
		pcall(function()
			self.ScreenGui:Destroy()
		end)
	end

	local gui = Instance.new('ScreenGui')
	gui.Name = 'SB2PlayerTools'
	gui:SetAttribute('SB2PlayerTools', true)
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 99998
	-- Global: nested controls (dropdown rows, open hit-target) must beat ancestor chrome.
	-- Sibling left Main/Hairline overlays above option rows so menus looked dead.
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	if type(protectgui) == 'function' then
		pcall(protectgui, gui)
	end
	gui.Parent = LocalPlayer:WaitForChild('PlayerGui')
	self.ScreenGui = gui

	UserInputService.MouseIconEnabled = true
	pcall(function()
		UserInputService.OverrideMouseIconBehavior = Enum.OverrideMouseIconBehavior.ForceShow
	end)
	do
		local t = 0
		track(RunService.Heartbeat:Connect(function(dt)
			if not Library.Toggled then
				return
			end
			t += dt
			if t < 0.5 then
				return
			end
			t = 0
			UserInputService.MouseIconEnabled = true
			pcall(function()
				UserInputService.OverrideMouseIconBehavior = Enum.OverrideMouseIconBehavior.ForceShow
			end)
		end))
	end

	local toastHolder = Instance.new('Frame')
	toastHolder.BackgroundTransparency = 1
	toastHolder.Size = UDim2.fromOffset(320, 420)
	toastHolder.Position = UDim2.new(1, -336, 0, 16)
	toastHolder.ZIndex = 100
	toastHolder.Parent = gui
	Instance.new('UIListLayout', toastHolder).Padding = UDim.new(0, 6)
	self._toasts = toastHolder

	makeShowPill(gui, info.Title or 'Ataraxia')

	local main = Instance.new('Frame')
	main.Name = 'Main'
	main.Size = UDim2.fromOffset(width, height)
	main.Position = info.Position or UDim2.new(0.5, -math.floor(width / 2), 0.5, -math.floor(height / 2))
	main.BackgroundColor3 = C.bg0
	main.BorderSizePixel = 0
	main.ClipsDescendants = true
	main.Active = true
	main.Parent = gui
	corner(main, 6)
	hairline(main, 6)

	local header = Instance.new('Frame')
	header.Name = 'Header'
	header.Size = UDim2.new(1, 0, 0, 52)
	header.BackgroundColor3 = C.bg1
	header.BorderSizePixel = 0
	header.Active = true
	header.Parent = main
	local hLine = Instance.new('Frame')
	hLine.Size = UDim2.new(1, 0, 0, 1)
	hLine.Position = UDim2.new(0, 0, 1, -1)
	hLine.BackgroundColor3 = C.line
	hLine.BorderSizePixel = 0
	hLine.Parent = header

	mkLabel(header, tostring(info.Title or 'Ataraxia'), {
		font = Enum.Font.SourceSansBold,
		size = 22,
		size2 = UDim2.new(1, -120, 0, 24),
		pos = UDim2.fromOffset(16, 6),
	})
	do
		local sub = tostring(info.Footer or '')
		if sub == '' then
			sub = tostring(info.Title or 'Ataraxia') .. ' · custom chrome'
		end
		-- Never put a long quote in the chrome — tiny fonts drop glyphs.
		if #sub > 48 then
			sub = string.sub(sub, 1, 45) .. '…'
		end
		mkLabel(header, sub, {
			font = Enum.Font.SourceSans,
			size = 14,
			color = C.muted,
			size2 = UDim2.new(1, -120, 0, 16),
			pos = UDim2.fromOffset(16, 30),
		})
	end

	-- Per-script version (bottom-left): CreateWindow{ Version = "1.2.3" } or
	-- {Folder}/version.json ("version" field). Each helper shows its own stamp.
	do
		local verText = nil
		if type(info.Version) == 'string' and info.Version ~= '' then
			verText = info.Version
		else
			local folder = tostring(info.Folder or '')
			local path = nil
			if folder ~= '' and type(isfile) == 'function' and isfile(folder .. '/version.json') then
				path = folder .. '/version.json'
			end
			if path and type(readfile) == 'function' then
				local ok, body = pcall(readfile, path)
				if ok and type(body) == 'string' and body ~= '' then
					local okJ, data = pcall(function()
						return game:GetService('HttpService'):JSONDecode(body)
					end)
					if okJ and type(data) == 'table' and data.version ~= nil then
						verText = tostring(data.version)
					end
				end
			end
		end
		if verText and verText ~= '' then
			if not string.match(verText, '^[vV]') then
				verText = 'v' .. verText
			end
			local verLbl = mkLabel(main, verText, {
				font = Enum.Font.SourceSans,
				size = 12,
				color = C.muted,
				size2 = UDim2.fromOffset(160, 16),
				pos = UDim2.new(0, 10, 1, -20),
				z = 50,
			})
			verLbl.Name = 'ScriptVersion'
			self.VersionLabel = verLbl
			self.Version = verText
		end
	end

	local function chrome(text, x, danger, fn)
		local b = Instance.new('TextButton')
		b.Size = UDim2.fromOffset(28, 28)
		b.Position = UDim2.new(1, x, 0.5, -14)
		b.BackgroundColor3 = danger and Color3.fromRGB(48, 20, 20) or C.bg3
		b.Text = text
		b.TextColor3 = danger and C.danger or C.text
		b.Font = Enum.Font.SourceSansBold
		b.TextSize = 16
		b.AutoButtonColor = false
		b.BorderSizePixel = 0
		b.Parent = header
		corner(b, 4)
		hairline(b, 4)
		b.MouseButton1Click:Connect(fn)
	end
	chrome('—', -72, false, function()
		Library:Toggle()
	end)
	chrome('×', -36, true, function()
		Library:Toggle()
	end)

	local body = Instance.new('Frame')
	body.Name = 'Body'
	body.Size = UDim2.new(1, 0, 1, -52)
	body.Position = UDim2.fromOffset(0, 52)
	body.BackgroundColor3 = C.bg0
	body.BorderSizePixel = 0
	body.Parent = main

	local RAIL_W = 160
	local rail = Instance.new('Frame')
	rail.Name = 'Rail'
	rail.Size = UDim2.new(0, RAIL_W, 1, 0)
	rail.BackgroundColor3 = C.bg1
	rail.BorderSizePixel = 0
	rail.Parent = body
	local railEdge = Instance.new('Frame')
	railEdge.Size = UDim2.new(0, 1, 1, 0)
	railEdge.Position = UDim2.new(1, -1, 0, 0)
	railEdge.BackgroundColor3 = C.line
	railEdge.BorderSizePixel = 0
	railEdge.Parent = rail

	local railScroll = Instance.new('ScrollingFrame')
	railScroll.Name = 'RailScroll'
	railScroll.Size = UDim2.new(1, -8, 1, -12)
	railScroll.Position = UDim2.fromOffset(4, 8)
	railScroll.BackgroundTransparency = 1
	railScroll.BorderSizePixel = 0
	railScroll.ScrollBarThickness = 3
	railScroll.ScrollBarImageColor3 = C.bg3
	railScroll.CanvasSize = UDim2.fromOffset(0, 0)
	railScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	railScroll.Parent = rail
	local railLay = Instance.new('UIListLayout')
	railLay.Padding = UDim.new(0, 4)
	railLay.SortOrder = Enum.SortOrder.LayoutOrder
	railLay.Parent = railScroll

	local pages = Instance.new('Frame')
	pages.Name = 'Pages'
	pages.Size = UDim2.new(1, -RAIL_W, 1, 0)
	pages.Position = UDim2.fromOffset(RAIL_W, 0)
	pages.BackgroundColor3 = C.bg0
	pages.BorderSizePixel = 0
	pages.ClipsDescendants = true
	pages.Parent = body

	local dragging, dragStart, startPos = false, nil, nil
	header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if input.Position.X >= header.AbsolutePosition.X + header.AbsoluteSize.X - 90 then
				return
			end
			dragging = true
			dragStart = input.Position
			startPos = main.Position
		end
	end)
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local d = input.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end))

	track(UserInputService.InputBegan:Connect(function(input, gp)
		if gp or Library.Unloaded then
			return
		end
		local kb = Library.ToggleKeybind
		if type(kb) == 'table' and kb.Value and input.KeyCode.Name == tostring(kb.Value) then
			Library:Toggle()
		end
	end))

	local Window = {}
	local tabOrder = 0
	function Window:AddTab(name, _icon)
		tabOrder += 1
		local btn = Instance.new('TextButton')
		btn.Name = name
		btn.LayoutOrder = tabOrder
		btn.Size = UDim2.new(1, -4, 0, 32)
		btn.BackgroundColor3 = C.bg1
		btn.Text = name
		btn.TextColor3 = C.muted
		btn.Font = Enum.Font.SourceSans
		btn.TextSize = 15
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.AutoButtonColor = false
		btn.BorderSizePixel = 0
		btn.Parent = railScroll
		corner(btn, 4)
		local bp = Instance.new('UIPadding')
		bp.PaddingLeft = UDim.new(0, 10)
		bp.Parent = btn

		local page = Instance.new('ScrollingFrame')
		page.Name = name
		page.Size = UDim2.fromScale(1, 1)
		page.BackgroundTransparency = 1
		page.BorderSizePixel = 0
		page.ScrollBarThickness = 6
		page.ScrollBarImageColor3 = C.bg3
		page.Visible = false
		page.CanvasSize = UDim2.fromOffset(0, 0)
		page.AutomaticCanvasSize = Enum.AutomaticSize.Y
		page.Parent = pages

		-- Offset columns (NOT scale) — scale width inside ScrollingFrame collapses to 0.
		local left = Instance.new('Frame')
		left.Name = 'Left'
		left.BackgroundTransparency = 1
		left.Position = UDim2.fromOffset(12, 12)
		left.Size = UDim2.fromOffset(340, 0)
		left.AutomaticSize = Enum.AutomaticSize.Y
		left.Parent = page
		local leftLay = Instance.new('UIListLayout')
		leftLay.Padding = UDim.new(0, 10)
		leftLay.SortOrder = Enum.SortOrder.LayoutOrder
		leftLay.Parent = left

		local right = Instance.new('Frame')
		right.Name = 'Right'
		right.BackgroundTransparency = 1
		right.Position = UDim2.fromOffset(364, 12)
		right.Size = UDim2.fromOffset(340, 0)
		right.AutomaticSize = Enum.AutomaticSize.Y
		right.Parent = page
		local rightLay = Instance.new('UIListLayout')
		rightLay.Padding = UDim.new(0, 10)
		rightLay.SortOrder = Enum.SortOrder.LayoutOrder
		rightLay.Parent = right

		local function layoutCols()
			local w = page.AbsoluteSize.X
			if w < 50 then
				return
			end
			local gap = 12
			local colW = math.max(260, math.floor((w - gap * 3) / 2))
			left.Size = UDim2.fromOffset(colW, 0)
			right.Size = UDim2.fromOffset(colW, 0)
			left.Position = UDim2.fromOffset(gap, gap)
			right.Position = UDim2.fromOffset(gap * 2 + colW, gap)
		end
		track(page:GetPropertyChangedSignal('AbsoluteSize'):Connect(layoutCols))
		task.defer(layoutCols)
		task.delay(0.15, layoutCols)
		task.delay(0.6, layoutCols)

		local tab = {
			Name = name,
			Button = btn,
			Container = page,
			Canvas = page,
		}

		function tab:Show()
			for _, t in pairs(Library.Tabs) do
				t.Container.Visible = false
				t.Button.BackgroundColor3 = C.bg1
				t.Button.TextColor3 = C.muted
				t.Button.Font = Enum.Font.SourceSans
			end
			page.Visible = true
			btn.BackgroundColor3 = C.bg3
			btn.TextColor3 = C.text
			btn.Font = Enum.Font.SourceSansBold
			Library.ActiveTab = tab
			layoutCols()
		end

		function tab:RefreshSides()
			layoutCols()
		end

		function tab:AddLeftGroupbox(title)
			return makeGroupbox(left, title)
		end
		function tab:AddRightGroupbox(title)
			return makeGroupbox(right, title)
		end

		btn.MouseButton1Click:Connect(function()
			tab:Show()
		end)

		Library.Tabs[name] = tab
		if not Library.ActiveTab then
			tab:Show()
		end
		return tab
	end

	self.Toggled = true
	self.Open = true
	-- Built-in anti-AFK for every consumer of this library (opt out: CreateWindow{ AntiAfk = false }).
	if info.AntiAfk ~= false then
		pcall(AntiAfk.ensure)
	end
	if info.Invisicam ~= false then
		pcall(Occlusion.ensure)
	end
	if info.HideGameplayPaused ~= false then
		pcall(NoPause.ensure)
	end
	track(RunService.Heartbeat:Connect(function()
		if Library.Config then
			pcall(Library.Config.Tick)
		end
		pcall(Occlusion.tick)
	end))
	return Window
end

return Library
