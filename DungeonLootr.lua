--[[
	Dungeon Lootr helper — Ataraxia menu (same chrome as PlayerTools)
	Home toggles the window. HUD stays on screen.
	Re-run dungeon-lootr/DungeonLootr.lua or dungeon-lootr/LootHUD.lua to reload.

	Combat: Auto parry / auto dodge / auto skill fire Inputs.Parry, Inputs.Dash (Q), and Inputs.Skill.
	Roll: Auto roll uses the class summon/spin remote and stops on picked classes.
	Codes: Use all codes hits CodesService.RedeemCode (same as Menu → Codes).
	Quests: Claim all clicks the real Claim buttons, battlepass quests/tiers, AchievementService.ClaimAll. No admin / Cmdr.
]]

local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local Lighting = game:GetService('Lighting')
local CollectionService = game:GetService('CollectionService')
local LocalPlayer = Players.LocalPlayer

if type(getgenv().DLUnload) == 'function' then
	pcall(getgenv().DLUnload)
end
if type(getgenv().DLLootHudUnload) == 'function' then
	pcall(getgenv().DLLootHudUnload)
end
local resumeFarm = getgenv().DLResumeFarm == true
getgenv().DLClassQueue = nil

-- Reloading while a loop or a position hold was mid-flight used to orphan it: the old
-- thread keeps running, the new instance has no handle on it, and the character ends
-- up held in place by a writer nobody can stop. Every long-lived loop checks this
-- epoch and exits as soon as a newer instance claims it.
--
-- Identity, not a counter. A number can be cleared by an older build's unload, and
-- then every stale copy recomputes the same 1 and believes it is still current — a
-- live session had 13 copies all convinced they owned the character, each firing
-- parry on its own logic. A fresh table can never collide.
local EPOCH = {}
getgenv().DLEpoch = EPOCH
local function currentInstance()
	return getgenv().DLEpoch == EPOCH
end

-- The single DLUnload slot only ever cleaned up whichever copy registered last, so
-- any load that overwrote the slot before its predecessor unloaded orphaned that
-- copy's connections for the rest of the session. Keep the handles in a global the
-- next load can always reach.
if type(getgenv().DLConns) == 'table' then
	for _, c in ipairs(getgenv().DLConns) do
		pcall(function()
			c:Disconnect()
		end)
	end
end
getgenv().DLConns = {}

-- Drop a position hold left behind by a previous instance — unless this is a
-- farm reload, where yanking the pin + collision is what dumps you on the floor.
if getgenv().DLPinConn and not resumeFarm then
	pcall(function()
		getgenv().DLPinConn:Disconnect()
	end)
	getgenv().DLPinConn = nil
end

local function exists(path)
	return type(isfile) == 'function' and isfile(path) == true
end

local ataPath
for _, path in ipairs({
	'PlayerTools/AtaraxiaLibrary.lua',
	'AtaraxiaLibrary.lua',
	'dungeon-lootr/AtaraxiaLibrary.lua',
}) do
	if exists(path) then
		ataPath = path
		break
	end
end
if not ataPath then
	error('[DL] AtaraxiaLibrary.lua missing (need PlayerTools/AtaraxiaLibrary.lua)')
end

local compile = loadstring or load
local libraryFn, libraryErr = compile(readfile(ataPath), ataPath)
if not libraryFn then
	error('[DL] Ataraxia compile: ' .. tostring(libraryErr))
end
getgenv().Library = nil
local Library = libraryFn()
assert(Library and Library.CreateWindow, 'Ataraxia failed')

Library.ToggleKeybind = { Value = 'Home' }
Library.Animations = Library.Animations or {}
Library.Animations.TabSwitch = false

local DL_BUILD = '1.0.68'
getgenv().DLBuild = DL_BUILD

local Window = Library:CreateWindow({
	Title = 'Dungeon Lootr',
	Footer = 'Home toggles menu',
	Folder = 'dungeon-lootr',
	Version = DL_BUILD,
	Size = UDim2.fromOffset(880, 560),
})
pcall(function()
	if Library.ScreenGui then
		Library.ScreenGui.Name = 'DLDungeonLootr'
		Library.ScreenGui:SetAttribute('SB2PlayerTools', nil)
		Library.ScreenGui:SetAttribute('DLDungeonLootr', true)
	end
end)

local Toggles = Library.Toggles
local Options = Library.Options

local conns = {}
local marks = {}
local function track(c)
	conns[#conns + 1] = c
	local reg = getgenv().DLConns
	if type(reg) == 'table' then
		reg[#reg + 1] = c
	end
	return c
end

local MARK = '_DLMark'
local HUD_NAME = 'DLLootHud'
local ENEMY_COLOR = Color3.fromRGB(255, 95, 95)
local ENEMY_ELITE_COLOR = Color3.fromRGB(255, 145, 45)
local ENEMY_MINI_COLOR = Color3.fromRGB(255, 210, 50)
local ENEMY_BOSS_COLOR = Color3.fromRGB(255, 70, 220)
local RARITY_COLOR = {
	Common = Color3.fromRGB(210, 210, 210),
	Uncommon = Color3.fromRGB(70, 210, 90),
	Rare = Color3.fromRGB(70, 140, 255),
	Epic = Color3.fromRGB(185, 85, 255),
	Legendary = Color3.fromRGB(255, 185, 50),
	Mythic = Color3.fromRGB(255, 70, 95),
	Potion = Color3.fromRGB(80, 220, 220),
	Key = Color3.fromRGB(255, 160, 60),
	Loot = Color3.fromRGB(255, 215, 80),
	Extract = Color3.fromRGB(255, 255, 255),
}

local savedLighting = {
	Brightness = Lighting.Brightness,
	ClockTime = Lighting.ClockTime,
	FogEnd = Lighting.FogEnd,
	Ambient = Lighting.Ambient,
	OutdoorAmbient = Lighting.OutdoorAmbient,
	GlobalShadows = Lighting.GlobalShadows,
}
if getgenv().DLSavedOcclusion == nil then
	pcall(function()
		getgenv().DLSavedOcclusion = LocalPlayer.DevCameraOcclusionMode
	end)
end

local defaultWalk = 28
local rt = {
	parryFire = 0,
	parryArmed = 0,
	parryDelay = 0,
	parryScan = 0,
	dodgeOnlyUntil = 0,
	bossNearAt = 0,
	bossCueAt = 0,
	parryLock = 0,
	learnedUntil = 0,
	fCueUntil = 0,
	fFollowDodgeAt = 0,
	fFollowParryAt = 0,
	fFollowParryUntil = 0,
	fSkipFollow = false,
	fParriedAt = 0,
	fOnAt = 0,
	fLetterHeld = 0,
	fAwaitFollow = 0,
	fLongUntil = 0,
	fNoFollow = false,
	dodgeFire = 0,
	muteVfx = 0,
	noclip = 0,
	combatHold = 0,
	junkAt = 0,
	hbCombat = 0,
	keyNoclip = 0,
	gateAt = 0,
	gateFrom = nil,
	gatePos = nil,
	gatePrompt = nil,
	gateDoor = nil,
	gateDist = nil,
	sessionAt = 0,
	session = nil,
	softlockAt = 0,
	softlockN = 0,
	chestSkip = {},
}
local enemyWatches = {}
local enemyCache = {}
local enemyCacheAt = 0
local lastSkillFire = 0
local nextSkillSlot = 1
local lastRollAt = 0
local rollBusy = false
local rollRF = nil
local rollRFLabel = nil
local walkConn = nil
local walkHum = nil
local WALK_BIND = 'DLWalkPin'
local lastLootable, lastTotal, lastGround, lastEnemies = 0, 0, 0, 0
local keyDoors = {}
local lootChests = {}
local potionStations = {}
local noclipOn = false
local lastKeyDist = nil
local chestFiredAt = {}
local lastChestGrab = 0
local routeBusy = false
local routeLabel = nil
local routeDoneAt = 0
local farmThread = nil
local farmBusy = false
local farmLabel = nil
local farmHome = nil
local farmKills = 0
local farmFinished = {}
local farmBan = {}
local function farmSkipped(npc)
	-- Chest-room mannequins have no Humanoid. Fighting them parks farm on the
	-- dummy (skipFinal then also hides the floor boss).
	if npc and npc:GetAttribute('IsLootRoomGuard') == true then
		return true
	end
	local ban = farmBan[npc]
	if ban and os.clock() < ban then
		return true
	end
	local untilAt = farmFinished[npc]
	if untilAt ~= nil and os.clock() < untilAt then
		return true
	end
	return type(rt.npcInCorridor) == 'function' and rt.npcInCorridor(npc) == true
end
local runCompleteAt = nil
local replayArmedAt = nil
local replayTries = 0
local lastReplayAt = 0
local replayCount = 0
local EXTRA_CODES = {
	'45KLIKE',
	'JACKAL',
	'SILVERINE',
	'20MVISIT',
	'20mvisit',
	'TOURNAMENT',
	'UPDATE1',
	'15KCCU',
	'WEEKENDBUFFS',
	'RAIDTIME',
	'COURAGE',
	'LOVETHISGAME',
	'LOOTR',
	'FORGESKIP',
	'8KLIKE',
	'10KFAV',
	'FULLRELEASE',
	'LOOTRISBACK',
	'JACKPOT',
	'20KPLAYERS',
	'GIVEMEGEMSPLEASE',
}
pcall(function()
	local cfg = game:GetService('ReplicatedStorage'):FindFirstChild('Configuration')
	local v = cfg and cfg:FindFirstChild('DEFAULT_WALK_SPEED')
	if v and v:IsA('ValueBase') and type(v.Value) == 'number' and v.Value > 0 then
		defaultWalk = v.Value
	end
end)

local function copyText(text)
	if type(setclipboard) == 'function' and pcall(setclipboard, text) then
		return true
	end
	if type(toclipboard) == 'function' and pcall(toclipboard, text) then
		return true
	end
	return false
end

local function fmtNum(n)
	if type(n) ~= 'number' or n ~= n then
		return '—'
	end
	if math.abs(n - math.floor(n + 0.5)) < 0.05 then
		return tostring(math.floor(n + 0.5))
	end
	return string.format('%.1f', n)
end

local function on(idx)
	local bag = Toggles
	if type(bag) ~= 'table' then
		return false
	end
	local t = bag[idx]
	return t and t.Value == true
end

-- Missing from old profiles = previous always-on farm behavior.
local function wantOpenGates()
	local t = Toggles and Toggles.DLOpenGates
	if t == nil then
		return true
	end
	return t.Value == true
end

local function character()
	local models = workspace:FindFirstChild('PlayerModels')
	local fromFolder = models and models:FindFirstChild(LocalPlayer.Name)
	return fromFolder or LocalPlayer.Character
end

-- Lowest of Humanoid / Stat_MaxHP / visible HUD / billboard. Never treat a
-- missing or dead humanoid as 100% — that is why flee/potion sat out a wipe.
rt.readHp = function()
	local samples = {}
	local statMax = tonumber(LocalPlayer:GetAttribute('Stat_MaxHP'))
	local function consider(h, m)
		h = tonumber(h)
		m = tonumber(m)
		if not h or not m or m <= 0 then
			return
		end
		if h < 0 then
			h = 0
		end
		-- Lobby placeholders (100/100, 500/500) while real max is thousands.
		if statMax and statMax > m * 1.5 and (m == 100 or m == 500) then
			return
		end
		samples[#samples + 1] = { hp = h, max = m, pct = (h / m) * 100 }
	end
	local function considerText(s)
		if type(s) ~= 'string' then
			return
		end
		s = string.gsub(s, ',', '')
		local a, b = string.match(s, '([%d%.]+)%s*/%s*([%d%.]+)')
		if a then
			consider(a, b)
		end
	end
	local char = character()
	local hum = char and char:FindFirstChildOfClass('Humanoid')
	if hum then
		consider(hum.Health, hum.MaxHealth)
		-- Only pair current Health with Stat_MaxHP when the two maxes agree.
		-- Mixing 1400/2256 with a 21k stat max reads as ~6% while the bar is
		-- full, which latches heal-wait and never returns to the boss.
		if statMax and statMax > 0 and hum.MaxHealth > 0 then
			local ratio = statMax / hum.MaxHealth
			if ratio > 0.7 and ratio < 1.4 then
				consider(hum.Health, statMax)
			end
		end
	end
	local pg = LocalPlayer:FindFirstChild('PlayerGui')
	local hud = pg and pg:FindFirstChild('Main')
	hud = hud and hud:FindFirstChild('HUD')
	local bar = hud and hud:FindFirstChild('Healthbar_Container')
	if bar then
		local amt = bar:FindFirstChild('Health_Amount', true)
		if amt and amt:IsA('TextLabel') then
			considerText(amt.Text)
		end
	end
	local actions = hud and hud:FindFirstChild('Actions')
	local bottom = actions and actions:FindFirstChild('Bottom')
	local bars = bottom and bottom:FindFirstChild('Bars')
	local hudHp = bars and bars:FindFirstChild('Health')
	if hudHp then
		local amt = hudHp:FindFirstChild('Amount') or hudHp:FindFirstChild('Health_Amount', true)
		if amt and (amt:IsA('TextLabel') or amt:IsA('TextButton')) then
			considerText(amt.Text)
		end
	end
	if char then
		local hrp = char:FindFirstChild('HumanoidRootPart')
		local bill = hrp and hrp:FindFirstChild('Player_Healthbar')
		if bill then
			local amt = bill:FindFirstChild('Health_Amount', true)
			if amt and amt:IsA('TextLabel') then
				considerText(amt.Text)
			end
		end
	end
	local chosen
	for _, s in ipairs(samples) do
		if s.pct > 0 and (not chosen or s.pct < chosen.pct) then
			chosen = s
		end
	end
	if not chosen then
		-- Every sample is 0, or there were none: dead / loading.
		local dead = not hum or hum.Health <= 0
		if dead or #samples > 0 then
			rt.hpLast, rt.hpLastMax, rt.hpLastPct = 0, statMax or 0, 0
			return 0, statMax or 0, 0
		end
		if type(rt.hpLastPct) == 'number' then
			return rt.hpLast, rt.hpLastMax, rt.hpLastPct
		end
		return statMax or 0, statMax or 0, 100
	end
	rt.hpLast, rt.hpLastMax, rt.hpLastPct = chosen.hp, chosen.max, chosen.pct
	return chosen.hp, chosen.max, chosen.pct
end

rt.hpPct = function()
	local _, _, pct = rt.readHp()
	return pct or 0
end

rt.healTrigger = function()
	return Options.DLPotionHp and tonumber(Options.DLPotionHp.Value) or 40
end

rt.healResume = function()
	local trig = rt.healTrigger()
	local resume = Options.DLHealResume and tonumber(Options.DLHealResume.Value) or 70
	return math.max(trig, resume or 70)
end

-- Latch once HP drops under the drink/flee slider; stay latched until HP is
-- actually over the resume slider so a 40% sip does not send farm back in.
rt.updateHealWait = function(pct)
	pct = tonumber(pct)
	if not pct then
		pct = rt.hpPct()
	end
	if pct <= 0 then
		return false
	end
	if pct <= rt.healTrigger() then
		rt.healWait = true
	elseif pct > rt.healResume() then
		rt.healWait = false
	end
	return rt.healWait == true
end

rt.clearRefillHold = function()
	local n = -1
	if rt.PotionRefill and type(rt.PotionRefill.count) == 'function' then
		n = tonumber(rt.PotionRefill.count()) or -1
	end
	local stale = type(rt.refillAt) == 'number' and (os.clock() - rt.refillAt) > 15
	if n > 0 or stale then
		rt.refillBusy = false
		rt.refillUrgent = false
		if routeLabel == 'potion refill' then
			routeBusy = false
			routeLabel = nil
		end
		return true
	end
	return false
end

rt.bindCharHp = function(char)
	if not char then
		return
	end
	local hum = char:FindFirstChildOfClass('Humanoid')
	if not hum then
		hum = char:WaitForChild('Humanoid', 5)
	end
	if not hum then
		return
	end
	-- Damage we take is the only ground truth for when a swing actually lands, so
	-- it is what the parry timing is learned from.
	local lastHp = hum.Health
	track(hum.HealthChanged:Connect(function(h)
		local drop = lastHp - h
		lastHp = h
		if drop > 1 then
			pcall(rt.learnHitLag)
		end
	end))
	track(hum.HealthChanged:Connect(function()
		if not on('DLAutoFlee') or os.clock() < (rt.hpFleeAt or 0) then
			return
		end
		local pct = rt.hpPct()
		if rt.updateHealWait(pct) and type(rt.fleeNow) == 'function' then
			rt.hpFleeAt = os.clock() + 0.25
			task.spawn(rt.fleeNow, true)
		end
	end))
	track(hum.Died:Connect(function()
		if LocalPlayer:GetAttribute('InDungeon') == true or LocalPlayer:GetAttribute('DungeonRun') == true then
			runCompleteAt = os.clock()
		end
	end))
end

local function skillReady(n)
	local onCd = LocalPlayer:GetAttribute('Skill' .. n .. '_OnCooldown') == true
	local rem = tonumber(LocalPlayer:GetAttribute('Skill' .. n .. '_CooldownRemaining')) or 0
	local ends = tonumber(LocalPlayer:GetAttribute('Skill' .. n .. '_CooldownEnd'))
	if onCd and type(ends) == 'number' then
		rem = math.max(0, ends - os.clock())
	end
	local charges = tonumber(LocalPlayer:GetAttribute('Skill' .. n .. '_Charges'))
	local maxC = tonumber(LocalPlayer:GetAttribute('Skill' .. n .. '_MaxCharges'))
	if type(maxC) == 'number' and maxC > 1 then
		local have = type(charges) == 'number' and charges or 0
		if have >= maxC then
			return ('S%s %s/%s'):format(n, fmtNum(have), fmtNum(maxC))
		end
		return ('S%s %s/%s %ss'):format(n, fmtNum(have), fmtNum(maxC), fmtNum(rem))
	end
	if onCd or rem > 0.05 then
		return ('S%s %ss'):format(n, fmtNum(math.max(0, rem)))
	end
	return ('S%s ready'):format(n)
end

local function statsText()
	local char = character()
	local hp, maxHp = rt.readHp()
	hp, maxHp = hp or 0, maxHp or 0
	local className = tostring(LocalPlayer:GetAttribute('Current_Class') or LocalPlayer:GetAttribute('Active_Class') or '?')
	local dungeon = tostring(LocalPlayer:GetAttribute('CurrentDungeon') or 'Lobby')
	local diff = tostring(LocalPlayer:GetAttribute('CurrentDifficultyMode') or '')
	local level = tonumber(LocalPlayer:GetAttribute('PlayerLevel')) or 0
	local inRun = LocalPlayer:GetAttribute('InDungeon') == true or LocalPlayer:GetAttribute('DungeonRun') == true
	local parryCd = LocalPlayer:GetAttribute('Parry_Cooldown_Active') == true
	local parry = char and char:GetAttribute('Parry') == true
	local iframe = (char and char:GetAttribute('iFrame') == true) or LocalPlayer:GetAttribute('iFrame') == true
	local parryText = parry and 'PARRY' or (parryCd and 'parry cd') or 'parry ready'
	local lines = {
		('%s  ·  Lv %s'):format(className, fmtNum(level)),
		inRun and (dungeon .. (diff ~= '' and ('  ·  ' .. diff) or '')) or 'Lobby',
		('HP  %s / %s'):format(fmtNum(hp), fmtNum(maxHp)),
		skillReady(1) .. '    ' .. skillReady(2),
		skillReady(3) .. '    ' .. skillReady(4),
		parryText .. (iframe and '  ·  i-frame' or ''),
	}
	if on('DLAutoParry') then
		lines[#lines + 1] = os.clock() < rt.parryArmed and 'auto parry  ·  armed' or 'auto parry on'
	end
	if on('DLAutoDodge') then
		local dodgeCd = LocalPlayer:GetAttribute('Dodge_Cooldown_Active') == true
		if dodgeCd then
			lines[#lines + 1] = 'auto dodge  ·  cd'
		elseif os.clock() < rt.parryArmed then
			lines[#lines + 1] = 'auto dodge  ·  armed'
		else
			lines[#lines + 1] = 'auto dodge on'
		end
	end
	if os.clock() < (rt.aoeUntil or 0) then
		lines[#lines + 1] = 'aoe gap'
	end
	if on('DLAutoSkill') then
		lines[#lines + 1] = 'auto skill on'
	end
	if on('DLAutoRoll') then
		lines[#lines + 1] = 'auto roll on'
	end
	if on('DLAutoPotion') then
		lines[#lines + 1] = 'auto potion  ·  ' .. tostring(rt.healTrigger()) .. '%  →  ' .. tostring(rt.healResume()) .. '%'
	end
	if rt.refillBusy or rt.refillUrgent then
		lines[#lines + 1] = 'potion refill  ·  cauldron'
	elseif on('DLAutoPotionRefill') then
		lines[#lines + 1] = 'refill at x0'
	end
	if on('DLAutoFlee') then
		lines[#lines + 1] = 'flee heal  ·  wait until ' .. tostring(rt.healResume()) .. '%'
	end
	if on('DLAutoFarm') then
		lines[#lines + 1] = farmLabel and ('farm  ·  ' .. farmLabel) or 'auto farm on'
	elseif farmLabel then
		lines[#lines + 1] = 'farm  ·  ' .. farmLabel
	end
	if on('DLAutoSpecial') then
		lines[#lines + 1] = rt.specialHud or 'auto special summon on'
	end
	if on('DLHuntSpecial') then
		local needle = Options.DLHuntTarget and tostring(Options.DLHuntTarget.Value or '') or ''
		if needle == '' or needle == 'nil' then
			needle = 'Scarlet Knight'
		end
		lines[#lines + 1] = ('hunt  ·  %s  ·  %d'):format(needle, tonumber(rt.huntKills) or 0)
	end
	if on('DLAutoReplay') then
		if replayArmedAt then
			lines[#lines + 1] = ('replay  ·  waiting (try %d)'):format(replayTries)
		else
			lines[#lines + 1] = ('auto replay on  ·  %d runs'):format(replayCount)
		end
	end
	if on('DLLoopSpecific') then
		local name = Options.DLLoopDungeon and tostring(Options.DLLoopDungeon.Value or '') or ''
		local diff = Options.DLLoopDifficulty and tostring(Options.DLLoopDifficulty.Value or '') or ''
		if name ~= '' and name ~= 'nil' then
			lines[#lines + 1] = ('loop  ·  %s · %s'):format(name, diff)
		else
			lines[#lines + 1] = 'loop  ·  pick a dungeon'
		end
	end
	if noclipOn and not routeBusy and not farmBusy then
		lines[#lines + 1] = 'noclip  ·  key door'
	end
	if routeLabel then
		lines[#lines + 1] = 'chest route  ·  ' .. routeLabel
	elseif on('DLChestAnywhere') then
		lines[#lines + 1] = wantOpenGates() and 'auto chest route on' or 'auto chest  ·  skip locked'
	end
	if Toggles.DLDpsMeter == nil or on('DLDpsMeter') then
		local dpsLine = rt.dpsLine and rt.dpsLine()
		if type(dpsLine) == 'string' and dpsLine ~= '' then
			lines[#lines + 1] = dpsLine
		end
	end
	return table.concat(lines, '\n'), className, dungeon, diff, hp, maxHp, level
end

local function getPart(inst)
	if not inst then
		return nil
	end
	if inst:IsA('BasePart') then
		return inst
	end
	if inst:IsA('Model') then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA('BasePart', true)
	end
	return inst:FindFirstChildWhichIsA('BasePart', true)
end

local function clearMark(inst)
	local m = marks[inst]
	if not m then
		return
	end
	marks[inst] = nil
	pcall(function()
		if m.highlight then
			m.highlight:Destroy()
		end
	end)
	pcall(function()
		if m.billboard then
			m.billboard:Destroy()
		end
	end)
end

local function setMark(inst, text, color)
	if not inst or not inst.Parent then
		clearMark(inst)
		return
	end
	local part = getPart(inst)
	if not part then
		clearMark(inst)
		return
	end
	local m = marks[inst]
	if not m then
		local hl = Instance.new('Highlight')
		hl.Name = MARK
		hl.FillTransparency = 0.72
		hl.OutlineTransparency = 0.15
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Adornee = inst:IsA('Model') and inst or part
		hl.Parent = inst
		local bb = Instance.new('BillboardGui')
		bb.Name = MARK
		bb.AlwaysOnTop = true
		bb.Size = UDim2.fromOffset(180, 28)
		bb.StudsOffset = Vector3.new(0, 3.2, 0)
		bb.MaxDistance = 480
		bb.Adornee = part
		bb.Parent = inst
		local lab = Instance.new('TextLabel')
		lab.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
		lab.BackgroundTransparency = 0.25
		lab.BorderSizePixel = 0
		lab.Size = UDim2.fromScale(1, 1)
		lab.Font = Enum.Font.GothamBold
		lab.TextSize = 13
		lab.TextStrokeTransparency = 0.4
		lab.Parent = bb
		Instance.new('UICorner', lab).CornerRadius = UDim.new(0, 6)
		m = { highlight = hl, billboard = bb, label = lab }
		marks[inst] = m
		inst.Destroying:Once(function()
			clearMark(inst)
		end)
	end
	m.label.Text = text
	m.label.TextColor3 = color
	m.highlight.FillColor = color
	m.highlight.OutlineColor = color
	m.highlight.Enabled = true
	m.billboard.Enabled = true
end

local function chestLabel(model)
	local prompt = model:FindFirstChild('ChestPrompt', true)
	if not prompt or not prompt:IsA('ProximityPrompt') or prompt.Enabled ~= true then
		return nil
	end
	local obj = tostring(prompt.ObjectText or 'Chest')
	local rarity = obj:match('^(%w+)') or 'Chest'
	return obj, RARITY_COLOR[rarity] or RARITY_COLOR.Common
end

local function chestPrompt(model)
	-- Real ChestPrompt only — unrelated prompts under the model are not loot.
	local prompt = model and model:FindFirstChild('ChestPrompt', true)
	if prompt and prompt:IsA('ProximityPrompt') then
		return prompt
	end
	return nil
end

-- HoldDuration prompts (blessing altar = 0.25s) need a real hold. Ending on the
-- next defer frame looks like a tap and the server ignores it — teleport works,
-- UI never opens. fireproximityprompt is also tried with an explicit duration.
local function fireChestPrompt(prompt)
	if not prompt or not prompt:IsA('ProximityPrompt') or prompt.Enabled ~= true then
		return false
	end
	local now = os.clock()
	if (chestFiredAt[prompt] or 0) + 1.2 > now then
		return false
	end
	chestFiredAt[prompt] = now
	local hold = math.max(tonumber(prompt.HoldDuration) or 0, 0)
	if type(fireproximityprompt) == 'function' then
		if hold > 0 then
			pcall(fireproximityprompt, prompt, hold)
			pcall(fireproximityprompt, prompt, 0, hold)
		end
		pcall(fireproximityprompt, prompt)
	elseif type(fireProximityPrompt) == 'function' then
		if hold > 0 then
			pcall(fireProximityPrompt, prompt, hold)
		end
		pcall(fireProximityPrompt, prompt)
	end
	pcall(function()
		prompt:InputHoldBegin()
	end)
	task.wait(hold > 0 and (hold + 0.12) or 0.05)
	pcall(function()
		prompt:InputHoldEnd()
	end)
	return true
end

local function scanEsp()
	local seen = {}
	local lootable, total, ground, enemies = 0, 0, 0, 0
	local stations = {}
	local wantChests = on('DLEspChests')
	local wantPotions = on('DLEspPotions')
	local wantKeys = on('DLEspKeys')
	local wantLoot = on('DLEspLoot')
	local wantEnemies = on('DLEspEnemies')
	local wantExtract = on('DLEspExtract')
	rt.scanEspAt = os.clock()

	if wantLoot then
		local lootFolder = workspace:FindFirstChild('Loot')
		if lootFolder then
			for _, child in ipairs(lootFolder:GetChildren()) do
				seen[child] = true
				ground += 1
				setMark(child, child.Name ~= '' and child.Name or 'Loot', RARITY_COLOR.Loot)
			end
		end
	end

	local doors = {}
	local chests = {}
	for _, root in ipairs(workspace:GetChildren()) do
		if root.Name:sub(1, 10) == 'Generated_' then
			for _, child in ipairs(root:GetChildren()) do
				if child:GetAttribute('DungeonChest') == true or child.Name:sub(1, 13) == 'DungeonChest' then
					total += 1
					local text, color = chestLabel(child)
					if text then
						lootable += 1
						chests[#chests + 1] = child
						if wantChests then
							seen[child] = true
							setMark(child, text, color)
						end
					end
				elseif child.Name == 'Potion_Station' then
					stations[#stations + 1] = child
					if wantPotions then
						seen[child] = true
						setMark(child, 'Potion station', RARITY_COLOR.Potion)
					end
				elseif child.Name:sub(1, 7) == 'Locked_' then
					doors[#doors + 1] = child
					local prompt = child:FindFirstChildWhichIsA('ProximityPrompt', true)
					if wantKeys and prompt and prompt.Enabled then
						seen[child] = true
						local obj = tostring(prompt.ObjectText ~= '' and prompt.ObjectText or prompt.ActionText)
						setMark(child, obj, RARITY_COLOR.Key)
					end
				else
					local low = string.lower(child.Name)
					if wantExtract and (low:find('extract', 1, true) or low:find('portal', 1, true) or low:find('exit', 1, true)) then
						seen[child] = true
						setMark(child, child.Name, RARITY_COLOR.Extract)
					end
				end
			end
			local npcs = root:FindFirstChild('NPCs')
			if wantEnemies and npcs then
				for _, npc in ipairs(npcs:GetChildren()) do
					local hum = npc:FindFirstChildOfClass('Humanoid')
					if hum and hum.Health > 0 then
						enemies += 1
						-- Enemy visuals are Drawing tracers (updated every frame), not
						-- billboard marks — marks get streamed away / capped and look broken.
					end
				end
			end
		end
	end

	if wantExtract then
		local portals = workspace:FindFirstChild('Portals')
		if portals then
			for _, child in ipairs(portals:GetChildren()) do
				seen[child] = true
				setMark(child, child.Name, RARITY_COLOR.Extract)
			end
		end
	end

	-- Lobby stations live under PVP_AREA (and any other top-level folder that hosts
	-- them). Avoid workspace:GetDescendants — the ESP tick is hot and a full walk
	-- is wasteful when the known folders are enough.
	local function takeStations(folder)
		if not folder then
			return
		end
		for _, d in ipairs(folder:GetDescendants()) do
			if d.Name == 'Potion_Station' and d:IsA('Model') then
				local already = false
				for _, s in ipairs(stations) do
					if s == d then
						already = true
						break
					end
				end
				if not already then
					stations[#stations + 1] = d
				end
				if wantPotions then
					seen[d] = true
					setMark(d, 'Potion station', RARITY_COLOR.Potion)
				end
			end
		end
	end
	-- Lobby PVP stations are irrelevant mid-run; skip that GetDescendants walk.
	if LocalPlayer:GetAttribute('InDungeon') ~= true then
		takeStations(workspace:FindFirstChild('PVP_AREA'))
	end

	for inst in pairs(marks) do
		if not seen[inst] then
			clearMark(inst)
		end
	end
	lastLootable, lastTotal, lastGround, lastEnemies = lootable, total, ground, enemies
	keyDoors = doors
	lootChests = chests
	potionStations = stations
end

local function scanEspThrottled(minGap)
	local gap = minGap or (farmBusy and 2.0 or 0.75)
	if os.clock() - (rt.scanEspAt or 0) < gap then
		return false
	end
	scanEsp()
	return true
end

-- Overlay HUD (separate from the menu)
local pg = LocalPlayer:WaitForChild('PlayerGui')
pcall(function()
	local old = pg:FindFirstChild(HUD_NAME)
	if old then
		old:Destroy()
	end
end)
local hudGui = Instance.new('ScreenGui')
hudGui.Name = HUD_NAME
hudGui.ResetOnSpawn = false
hudGui.IgnoreGuiInset = true
hudGui.DisplayOrder = 99990
if type(protectgui) == 'function' then
	pcall(protectgui, hudGui)
end
hudGui.Enabled = false
hudGui.Parent = pg
local hudFrame = Instance.new('Frame')
hudFrame.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
hudFrame.BackgroundTransparency = 0.18
hudFrame.BorderSizePixel = 0
hudFrame.Position = UDim2.fromOffset(16, 72)
	hudFrame.Size = UDim2.fromOffset(248, 272)
hudFrame.Parent = hudGui
Instance.new('UICorner', hudFrame).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new('UIStroke')
stroke.Color = Color3.fromRGB(40, 48, 62)
stroke.Parent = hudFrame
local hudTitle = Instance.new('TextLabel')
hudTitle.BackgroundTransparency = 1
hudTitle.Position = UDim2.fromOffset(12, 8)
hudTitle.Size = UDim2.new(1, -24, 0, 16)
hudTitle.Font = Enum.Font.GothamBold
hudTitle.TextSize = 12
hudTitle.TextXAlignment = Enum.TextXAlignment.Left
hudTitle.TextColor3 = Color3.fromRGB(230, 232, 238)
hudTitle.Text = 'Dungeon Lootr'
hudTitle.Parent = hudFrame
local hudBody = Instance.new('TextLabel')
hudBody.BackgroundTransparency = 1
hudBody.Position = UDim2.fromOffset(12, 28)
hudBody.Size = UDim2.new(1, -24, 1, -36)
hudBody.Font = Enum.Font.GothamMedium
hudBody.TextSize = 13
hudBody.TextXAlignment = Enum.TextXAlignment.Left
hudBody.TextYAlignment = Enum.TextYAlignment.Top
hudBody.TextColor3 = Color3.fromRGB(190, 196, 208)
hudBody.TextWrapped = true
hudBody.Text = '…'
hudBody.Parent = hudFrame

local function refreshHud()
	local show = on('DLShowHud')
	hudGui.Enabled = show == true
	if not show then
		return
	end
	local core = select(1, statsText())
	hudBody.Text = table.concat({
		core,
		('Chests  %s lootable / %s'):format(fmtNum(lastLootable), fmtNum(lastTotal)),
		('Ground  %s    Mobs  %s'):format(fmtNum(lastGround), fmtNum(lastEnemies)),
	}, '\n')
end

-- Outgoing DPS from Player Damage_Dealt / Hit_Count. Rolling 5s plus average
-- over active fight time (idle gaps are not counted, so walking between packs
-- does not drag the average down).
rt.dpsLine = (function()
	local WINDOW = 5
	local IDLE = 6
	local lastTotal = 0
	local lastHits = 0
	local lastAt = 0
	local lastHitAt = 0
	local fightDmg = 0
	local fightHits = 0
	local activeTime = 0
	local samples = {}
	local hudAt = 0
	local primed = false

	local function fmtDps(n)
		if type(n) ~= 'number' or n ~= n or n < 0 then
			return '—'
		end
		if n >= 1e6 then
			return string.format('%.1fm', n / 1e6)
		end
		if n >= 1000 then
			return string.format('%.1fk', n / 1000)
		end
		if n >= 100 then
			return tostring(math.floor(n + 0.5))
		end
		return string.format('%.1f', n)
	end

	local function resetFight()
		samples = {}
		fightDmg = 0
		fightHits = 0
		activeTime = 0
		lastHitAt = 0
	end

	local function snapshot()
		return tonumber(LocalPlayer:GetAttribute('Damage_Dealt')) or lastTotal, tonumber(LocalPlayer:GetAttribute('Hit_Count')) or lastHits
	end

	local function note(total, hits)
		total = tonumber(total) or lastTotal
		hits = tonumber(hits) or lastHits
		local now = os.clock()
		if not primed then
			lastTotal, lastHits, lastAt = total, hits, now
			primed = true
			return
		end
		if total < lastTotal then
			resetFight()
			lastTotal, lastHits, lastAt = total, hits, now
			return
		end
		local delta = total - lastTotal
		local hitDelta = math.max(0, hits - lastHits)
		lastTotal, lastHits, lastAt = total, hits, now
		if delta <= 0 then
			return
		end
		if lastHitAt > 0 and now - lastHitAt < IDLE then
			activeTime += now - lastHitAt
		end
		fightDmg += delta
		fightHits += hitDelta
		lastHitAt = now
		samples[#samples + 1] = { t = now, d = delta }
		while samples[1] and now - samples[1].t > WINDOW + 1 do
			table.remove(samples, 1)
		end
	end

	local function line()
		note(snapshot())
		local now = os.clock()
		local sum = 0
		for i = 1, #samples do
			local s = samples[i]
			if now - s.t <= WINDOW then
				sum += s.d
			end
		end
		local live = lastHitAt > 0 and now - lastHitAt <= IDLE
		local dps = live and (sum / WINDOW) or 0
		local span = activeTime
		if live and lastHitAt > 0 then
			span += math.min(now - lastHitAt, IDLE)
		end
		local avg = span >= 0.6 and (fightDmg / span) or 0
		if dps < 1 and avg < 1 then
			return nil
		end
		if live and dps >= 1 and avg >= 1 then
			local extra = ''
			if fightHits > 0 then
				extra = ('  ·  hit  %s'):format(fmtDps(fightDmg / fightHits))
			end
			return ('dps  %s/s  ·  avg  %s/s%s'):format(fmtDps(dps), fmtDps(avg), extra)
		end
		if avg >= 1 then
			return ('avg  %s/s'):format(fmtDps(avg))
		end
		return ('dps  %s/s'):format(fmtDps(dps))
	end

	note(snapshot())
	track(LocalPlayer:GetAttributeChangedSignal('Damage_Dealt'):Connect(function()
		note(snapshot())
		local now = os.clock()
		if now - hudAt < 0.12 then
			return
		end
		hudAt = now
		pcall(refreshHud)
	end))
	track(LocalPlayer:GetAttributeChangedSignal('Hit_Count'):Connect(function()
		note(snapshot())
	end))

	return line
end)()

local function applyFullbright(v)
	if v then
		Lighting.Brightness = 2
		Lighting.ClockTime = 14
		Lighting.FogEnd = 1e6
		Lighting.Ambient = Color3.fromRGB(180, 180, 180)
		Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
		Lighting.GlobalShadows = false
	else
		Lighting.Brightness = savedLighting.Brightness
		Lighting.ClockTime = savedLighting.ClockTime
		Lighting.FogEnd = savedLighting.FogEnd
		Lighting.Ambient = savedLighting.Ambient
		Lighting.OutdoorAmbient = savedLighting.OutdoorAmbient
		Lighting.GlobalShadows = savedLighting.GlobalShadows
	end
end

-- Same Invisicam pin as PlayerTools/CCI: walls go transparent instead of zooming
-- the camera through your back. Games reset DevCameraOcclusionMode, so we re-apply.
rt.applyOcclusion = function(enabled)
	pcall(function()
		if Library and type(Library.SetInvisicam) == 'function' then
			Library:SetInvisicam(enabled == true)
			return
		end
		if enabled then
			if LocalPlayer.DevCameraOcclusionMode ~= Enum.DevCameraOcclusionMode.Invisicam then
				LocalPlayer.DevCameraOcclusionMode = Enum.DevCameraOcclusionMode.Invisicam
			end
		else
			local saved = getgenv().DLSavedOcclusion or Enum.DevCameraOcclusionMode.Zoom
			if LocalPlayer.DevCameraOcclusionMode ~= saved then
				LocalPlayer.DevCameraOcclusionMode = saved
			end
		end
	end)
end

local VFX_ROOTS = { 'Particles', 'SpellTelegraphs', 'ActiveProjectiles' }
local function muteVfx()
	if not on('DLMuteVfx') then
		return
	end
	-- GetDescendants on Particles/SpellTelegraphs during Dark Professor
	-- airstrikes allocated thousands of instances and spiked frames 100–300ms.
	if farmBusy then
		return
	end
	local now = os.clock()
	if now - rt.muteVfx < 1.4 then
		return
	end
	rt.muteVfx = now
	local function muteKids(folder, depth)
		if not folder or depth > 3 then
			return
		end
		for _, d in ipairs(folder:GetChildren()) do
			pcall(function()
				if d:IsA('ParticleEmitter') or d:IsA('Trail') or d:IsA('Beam') or d:IsA('Fire') or d:IsA('Smoke') then
					if d.Enabled then
						d.Enabled = false
					end
				end
			end)
			if depth < 3 and (d:IsA('Folder') or d:IsA('Model') or d:IsA('BasePart')) then
				muteKids(d, depth + 1)
			end
		end
	end
	for _, name in ipairs(VFX_ROOTS) do
		muteKids(workspace:FindFirstChild(name), 1)
	end
end

local function wantedWalk()
	if not on('DLWalkOn') then
		return nil
	end
	return Options.DLWalkSpeed and tonumber(Options.DLWalkSpeed.Value) or defaultWalk
end

local function pinWalk(hum, spd)
	if not hum or type(spd) ~= 'number' then
		return
	end
	if math.abs((hum.WalkSpeed or 0) - spd) > 0.05 then
		hum.WalkSpeed = spd
	end
end

local function hookWalk(hum)
	if not hum then
		return
	end
	if walkHum == hum and walkConn then
		return
	end
	if walkConn then
		pcall(function()
			walkConn:Disconnect()
		end)
	end
	walkHum = hum
	walkConn = hum:GetPropertyChangedSignal('WalkSpeed'):Connect(function()
		local spd = wantedWalk()
		if spd then
			pinWalk(hum, spd)
		end
	end)
end

local function applyWalk()
	local spd = wantedWalk()
	if not spd then
		return
	end
	-- RenderStepped used to re-resolve the character every frame even when the
	-- speed was already correct — cheap individually, noisy at 60–120Hz.
	if walkHum and walkHum.Parent and math.abs((walkHum.WalkSpeed or 0) - spd) <= 0.05 then
		return
	end
	local char = character() or LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass('Humanoid')
	if not hum then
		return
	end
	hookWalk(hum)
	pinWalk(hum, spd)
end

-- Most parts on the character (weapon handles, hitboxes, slash and level FX) ship
-- with CanCollide off. Blanket-restoring them to true leaves that geometry solid
-- and resting on the floor, which lifts you off the ground and feels like flying.
-- So remember each part's real value and put back exactly that.
local noclipSaved = {}

local SOLID_LIMBS = {
	Head = true,
	Torso = true,
	Left_Arm = true,
	Right_Arm = true,
	Left_Leg = true,
	Right_Leg = true,
	['Left Arm'] = true,
	['Right Arm'] = true,
	['Left Leg'] = true,
	['Right Leg'] = true,
	UpperTorso = true,
	LowerTorso = true,
}

local function setCharNoclip(enabled)
	local char = character() or LocalPlayer.Character
	if not char then
		return
	end
	if enabled then
		-- Stepped used to call this every physics frame and re-walk the whole
		-- rig. Only touch parts that still collide; skip the rest.
		for _, p in ipairs(char:GetDescendants()) do
			if p:IsA('BasePart') and p.CanCollide then
				if noclipSaved[p] == nil then
					noclipSaved[p] = true
				end
				p.CanCollide = false
			end
		end
		return
	end
	for p, was in pairs(noclipSaved) do
		if p.Parent then
			pcall(function()
				p.CanCollide = was
			end)
		end
	end
	noclipSaved = {}
end

-- Keep farm/route noclip without a full descendant walk every Stepped tick.
local function maintainNoclip()
	if not noclipOn then
		return
	end
	local now = os.clock()
	-- Farm already re-applies noclip when it starts; the game rarely flips
	-- CanCollide back on mid-fight, so slow the maintain pass way down.
	-- ZoneEntered (horde / special wave spawn) needs collision. Noclip maintain
	-- used to flip it back off mid-arm and the room looked empty.
	if now < (rt.holdCollideUntil or 0) then
		return
	end
	local gap = farmBusy and 0.85 or 0.4
	if now - rt.noclip < gap then
		return
	end
	rt.noclip = now
	setCharNoclip(true)
end

-- The rig's real collision layout is not guessable: this game ships R6 with all four
-- limbs non-solid and only Head/Torso colliding. So snapshot the truth while the
-- character is untouched and restore that instead of assuming.
local collisionBaseline = nil

local function captureCollisionBaseline()
	local char = character() or LocalPlayer.Character
	if not char or noclipOn or routeBusy then
		return
	end
	local snap = {}
	for _, p in ipairs(char:GetChildren()) do
		if p:IsA('BasePart') then
			snap[p] = p.CanCollide
		end
	end
	collisionBaseline = snap
end

-- Repair for a character corrupted by the old blanket restore: rebuild the collision
-- layout, drop leftover velocity, and re-ground the humanoid.
local function fixMovement()
	local char = character() or LocalPlayer.Character
	if not char then
		return false
	end
	noclipSaved = {}
	for _, p in ipairs(char:GetDescendants()) do
		if p:IsA('BasePart') and p.Name ~= 'HumanoidRootPart' then
			local want
			if p.Parent ~= char then
				-- Nested geometry is cosmetic or FX (weapon meshes, slash effects,
				-- hitboxes) and is never part of the collision rig.
				want = false
			elseif collisionBaseline and collisionBaseline[p] ~= nil then
				want = collisionBaseline[p]
			else
				want = SOLID_LIMBS[p.Name] == true
			end
			pcall(function()
				p.CanCollide = want
			end)
		end
	end
	local hum = char:FindFirstChildOfClass('Humanoid')
	local root = char:FindFirstChild('HumanoidRootPart') or char.PrimaryPart
	if root then
		pcall(function()
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end)
	end
	if hum then
		pcall(function()
			hum.PlatformStand = false
			hum.Sit = false
			hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.Running, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end
	return true
end

local function ghostDoor(door)
	if not door then
		return
	end
	for _, p in ipairs(door:GetDescendants()) do
		if p:IsA('BasePart') then
			p.CanCollide = false
		end
	end
end

-- Filled in after Pin / standingSpot exist (see below).
local KeyDoor = {
	find = function()
		return nil
	end,
	unlock = function()
		return false
	end,
}

local function nearestKeyDoor()
	local myRoot = character() and (character():FindFirstChild('HumanoidRootPart') or character().PrimaryPart)
	if not myRoot then
		return nil, nil
	end
	local best, bestD = nil, nil
	for _, door in ipairs(keyDoors) do
		if door and door.Parent then
			local part = getPart(door)
			if part then
				local d = (part.Position - myRoot.Position).Magnitude
				if not bestD or d < bestD then
					best, bestD = door, d
				end
			end
		end
	end
	return best, bestD
end

local function applyKeyNoclip()
	-- Farm already noclips the character for its own teleports; still ghost the
	-- door parts so a Locked_ portcullis cannot snag the rig mid-route.
	if routeBusy or farmBusy then
		return
	end
	if not on('DLAutoNoclip') then
		lastKeyDist = nil
		if noclipOn then
			noclipOn = false
			setCharNoclip(false)
		end
		return
	end
	local now = os.clock()
	if now - rt.keyNoclip < 0.2 then
		return
	end
	rt.keyNoclip = now
	local range = Options.DLNoclipRange and tonumber(Options.DLNoclipRange.Value) or 22
	local door, dist = nearestKeyDoor()
	lastKeyDist = dist
	local want = door ~= nil and type(dist) == 'number' and dist <= range
	if want then
		ghostDoor(door)
		noclipOn = true
		setCharNoclip(true)
	elseif noclipOn then
		noclipOn = false
		setCharNoclip(false)
	end
end

-- The server owns ChestPrompt and validates MaxActivationDistance against its own
-- copy, so a client-side range stretch is ignored. The only way to loot a far
-- chest is to actually stand next to it, fire the real prompt, then come back.
local function routeRoot()
	local char = character()
	if not char then
		return nil
	end
	return char:FindFirstChild('HumanoidRootPart') or char.PrimaryPart
end

-- Every teleport path (chest stops, room entries, holding next to an enemy) needs the
-- rig kept where it was put. Without this it free-falls between stops, because noclip
-- is on and nothing else fights gravity — measured as a ~9 stud vertical wobble, which
-- is what the jitter actually was. Heartbeat runs after physics, so writing here lands
-- before the next render instead of letting the fall show for a frame.
-- Callers pass a goal function, which keeps this free of any enemy/UI dependencies
-- that are not defined until much later in the file.
local Pin = (function()
	local api = {}
	local conn, rsConn, goalFn
	local snapExact = false
	local lastGoal, lastAim = nil, nil

	local function unbind()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		if rsConn then
			rsConn:Disconnect()
			rsConn = nil
		end
		if getgenv().DLPinConn then
			pcall(function()
				getgenv().DLPinConn:Disconnect()
			end)
			getgenv().DLPinConn = nil
		end
	end

	local bind

	function api.stop()
		if farmBusy then
			local myRoot = routeRoot()
			if myRoot then
				lastGoal = myRoot.Position
				lastAim = nil
				-- Loose park. snapExact here CFrame-locked every Heartbeat
				-- (the farm stutter) and cancelled M1 / skill windups.
				snapExact = false
				goalFn = function()
					return lastGoal
				end
				bind()
				return
			end
		end
		unbind()
		goalFn = nil
		snapExact = false
		lastGoal, lastAim = nil, nil
	end

	local function step()
		if not currentInstance() then
			-- Reload handoff: keep the last station until the new copy binds.
			if getgenv().DLResumeFarm then
				return
			end
			api.stop()
			return
		end
		local myRoot = routeRoot()
		if not myRoot then
			return
		end
		local goal, aim
		if goalFn then
			local ok, g, a = pcall(goalFn)
			if ok and typeof(g) == 'Vector3' then
				goal, aim = g, a
				lastGoal, lastAim = g, a
			end
		end
		-- Skills / knockback can run after Heartbeat. Hold the last station so
		-- noclip + a nil goal cannot dump the rig through the floor.
		if typeof(goal) ~= 'Vector3' then
			goal, aim = lastGoal, lastAim
		end
		if typeof(goal) ~= 'Vector3' then
			return
		end
		pcall(function()
			local here = myRoot.Position
			if os.clock() < (rt.ultLockUntil or 0) then
				return
			end
			local drift = (here - goal).Magnitude
			local dodging = os.clock() < (rt.aoeUntil or 0)
			local tight = snapExact or dodging
			-- Farm stand: loose hold so we do not CFrame-lock every Heartbeat and
			-- cancel M1 / skill windups (felt like input lag / skills not casting).
			local hold = snapExact and 0.18 or (dodging and 0.55 or (farmBusy and 1.35 or 0.55))
			if drift <= hold then
				-- Still face the pack. Stand-range used to skip lookAt, so a dash /
				-- skill could leave you looking away and M1s never connected
				-- (Demon Rogue Daemon: 2 studs off, 0 damage, HitReact frozen).
				if typeof(aim) == 'Vector3' then
					local to = Vector3.new(aim.X - here.X, 0, aim.Z - here.Z)
					if to.Magnitude > 0.25 then
						local look = Vector3.new(myRoot.CFrame.LookVector.X, 0, myRoot.CFrame.LookVector.Z)
						-- 0.65 (~49°) rewrote facing every few frames and looked like stutter.
						if look.Magnitude < 0.05 or look.Unit:Dot(to.Unit) < 0.25 then
							myRoot.CFrame = CFrame.lookAt(here, Vector3.new(aim.X, here.Y, aim.Z))
						end
					end
				end
				return
			end
			-- AOE gap: hard snap. Boss stand: soft lerp so attacks still play.
			local nextPos
			if tight then
				nextPos = goal
			elseif farmBusy then
				nextPos = here:Lerp(goal, 0.35)
			else
				nextPos = here:Lerp(goal, 0.45)
			end
			if typeof(aim) == 'Vector3' and (aim - nextPos).Magnitude > 0.05 then
				myRoot.CFrame = CFrame.lookAt(nextPos, aim)
			else
				myRoot.CFrame = CFrame.new(nextPos) * (myRoot.CFrame - myRoot.CFrame.Position)
			end
			if tight or drift > 6 then
				myRoot.AssemblyLinearVelocity = Vector3.zero
				myRoot.AssemblyAngularVelocity = Vector3.zero
			end
			local now = os.clock()
			if now - (rt.pinHumAt or 0) < 0.25 then
				return
			end
			rt.pinHumAt = now
			local char = myRoot.Parent
			local hum = char and char:FindFirstChildOfClass('Humanoid')
			if hum then
				hum.Jump = false
				if tight then
					pcall(function()
						hum:Move(Vector3.zero, true)
					end)
				end
				if farmBusy and tight then
					pcall(function()
						hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
						hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
					end)
				end
				local st = hum:GetState()
				if st == Enum.HumanoidStateType.Freefall
					or st == Enum.HumanoidStateType.Physics
					or st == Enum.HumanoidStateType.FallingDown
				then
					pcall(function()
						hum:ChangeState(Enum.HumanoidStateType.Running)
					end)
				end
			end
		end)
	end

	bind = function()
		if conn then
			return
		end
		rt.pinAcc = 1
		-- Heartbeat only. Re-connecting every Pin.at() hitch the frame (~200ms)
		-- and the two poses fought, which is the farm stutter.
		conn = RunService.Heartbeat:Connect(step)
		getgenv().DLPinConn = conn
	end

	function api.follow(fn)
		snapExact = false
		goalFn = fn
		bind()
	end

	function api.at(pos, exact)
		snapExact = exact == true
		lastGoal, lastAim = pos, nil
		local myRoot = routeRoot()
		if myRoot then
			pcall(function()
				myRoot.CFrame = CFrame.new(pos) * (myRoot.CFrame - myRoot.CFrame.Position)
				myRoot.AssemblyLinearVelocity = Vector3.zero
				myRoot.AssemblyAngularVelocity = Vector3.zero
			end)
		end
		goalFn = function()
			return pos
		end
		bind()
	end

	function api.station()
		local myRoot = routeRoot()
		if not myRoot then
			return
		end
		api.at(myRoot.Position, true)
	end

	return api
end)()

local function chestAnchor(model)
	local prompt = chestPrompt(model)
	local part = prompt and prompt.Parent
	if part and part:IsA('Attachment') then
		return part.WorldPosition
	end
	if part and part:IsA('BasePart') then
		return part.Position
	end
	part = model and model:FindFirstChildWhichIsA('BasePart', true)
	if part then
		local ok, pos = pcall(function()
			return model:GetPivot().Position
		end)
		return ok and pos or part.Position
	end
	-- Streamed-out chest: warp to its room Zone / spawn so the mesh loads.
	local idx = tonumber(model and model:GetAttribute('RoomIndex'))
	if idx then
		for _, gen in ipairs(workspace:GetChildren()) do
			if gen.Name:sub(1, 10) == 'Generated_' then
				local room = gen:FindFirstChild('Room_' .. tostring(idx))
				if not room then
					room = gen:FindFirstChild('Locked_' .. tostring(idx))
				end
				if room then
					local zone = room:FindFirstChild('Zone')
					if zone and zone:IsA('BasePart') then
						return zone.Position
					end
					local spawn = room:FindFirstChild('Chest_Spawn', true) or room:FindFirstChild('Chest_Spawn_Rare', true)
					if spawn and spawn:IsA('BasePart') then
						return spawn.Position
					end
				end
			end
		end
	end
	local ok, pos = pcall(function()
		return model:GetPivot().Position
	end)
	if ok and typeof(pos) == 'Vector3' and pos.Magnitude > 8 then
		return pos
	end
	return nil
end

-- Prefer the walkable floor near the target. A cast from +80 often hits a balcony
-- or rock slab first and parks the rig "over" the room — that is the warp float.
local function standingSpot(pos, lift, exclude)
	lift = lift or 4
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass('Humanoid')
	local root = char and char:FindFirstChild('HumanoidRootPart')
	local hip = 3.5
	if hum and root then
		hip = math.max(hip, hum.HipHeight + root.Size.Y * 0.5)
	end
	local y = pos.Y + lift
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter = { char }
	if exclude then
		filter[#filter + 1] = exclude
	end
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true
	local maxRise = 12
	-- Cast from above the target; if already sunk (noclip freefall), cast from higher.
	local originY = math.max(pos.Y + 10, (root and root.Position.Y or pos.Y) + 10)
	local hit = workspace:Raycast(Vector3.new(pos.X, originY, pos.Z), Vector3.new(0, -80, 0), params)
	if not hit then
		hit = workspace:Raycast(pos + Vector3.new(0, 100, 0), Vector3.new(0, -250, 0), params)
	end
	if hit then
		local floorY = hit.Position.Y + hip
		-- Always lift out of the floor when sunk; only reject high slabs above us.
		if floorY >= pos.Y - 8 and floorY <= pos.Y + maxRise then
			y = floorY
		elseif floorY > pos.Y + maxRise then
			-- High slab — keep near target height.
			y = math.max(y, pos.Y + hip * 0.35)
		else
			y = math.max(y, floorY)
		end
	else
		-- No floor hit: still bias up so we do not keep falling through void.
		y = math.max(y, pos.Y + hip)
	end
	return Vector3.new(pos.X, y, pos.Z)
end

-- Prompt-range stand for stations / shrines (same 8-stud server check as chests).
local function promptStandPos(prompt, model)
	if not prompt then
		return model and standingSpot(model:GetPivot().Position) or nil
	end
	local part = prompt.Parent
	local anchor
	if part and part:IsA('Attachment') then
		anchor = part.WorldPosition
	elseif part and part:IsA('BasePart') then
		anchor = part.Position
	elseif part and part:IsA('Model') then
		-- Key doors: prompt lives on KeyModel (the pedestal beside the gate), not
		-- the Door mesh. Standing on Locked_ pivot puts you out of Use Key range.
		local ok, p = pcall(function()
			return part:GetPivot().Position
		end)
		anchor = ok and p or nil
		if not anchor then
			local bp = part:FindFirstChildWhichIsA('BasePart', true)
			anchor = bp and bp.Position
		end
	elseif model then
		local ok, p = pcall(function()
			return model:GetPivot().Position
		end)
		anchor = ok and p or nil
	end
	if not anchor then
		return nil
	end
	local maxDist = tonumber(prompt.MaxActivationDistance) or 8
	local lift = math.clamp(maxDist * 0.35, 2.2, 3.2)
	local hover = anchor + Vector3.new(0, lift, 0)
	-- Prefer a tight hover on the button itself — floor snaps can land on the
	-- gate slab and fail the server's MaxActivationDistance check.
	local floor = standingSpot(anchor, lift, model)
	if (floor - anchor).Magnitude <= math.max(2, maxDist * 0.45) then
		return floor
	end
	return hover
end

-- Locked_ gates: Use Key sits on KeyModel (pedestal), not the Door mesh.
-- ParentRoomIndex ties each gate to a room — unlock that gate as soon as we
-- enter/clear the room instead of waiting for the idle "nearest gate" path.
KeyDoor = (function()
	local api = {}
	local lastAt = 0
	local unlocked = setmetatable({}, { __mode = 'k' })

	local function isUseKey(prompt, door)
		if not prompt or not prompt:IsA('ProximityPrompt') or not prompt.Enabled then
			return false
		end
		local blob = (tostring(prompt.ActionText) .. ' ' .. tostring(prompt.ObjectText)):lower()
		-- Totem: "Summon Special Boss" / "7x Platinum Key". Room gates are
		-- "Requires Platinum Key" / Use Key and MUST open.
		if blob:find('special boss', 1, true) or blob:find('summon', 1, true) then
			return false
		end
		if blob:find('platinum', 1, true) and blob:find('%d+%s*x') then
			return false
		end
		if blob:find('platinum', 1, true) then
			local onGate = door and tostring(door.Name):sub(1, 7) == 'Locked_'
			local act = string.lower(tostring(prompt.ActionText or ''))
			if not onGate and act ~= '' and not act:find('key', 1, true) and not act:find('unlock', 1, true) then
				return false
			end
		end
		return blob:find('key', 1, true) ~= nil or blob:find('unlock', 1, true) ~= nil
	end

	local function keyAnchor(prompt, door)
		local keyModel = prompt and prompt.Parent
		if keyModel and keyModel:IsA('BasePart') then
			return keyModel.Position, keyModel
		end
		if keyModel and keyModel:IsA('Attachment') then
			return keyModel.WorldPosition, keyModel
		end
		if keyModel and keyModel:IsA('Model') then
			local ok, p = pcall(function()
				return keyModel:GetPivot().Position
			end)
			if ok and p then
				return p, keyModel
			end
			local bp = keyModel:FindFirstChildWhichIsA('BasePart', true)
			if bp then
				return bp.Position, keyModel
			end
		end
		local part = door and (door:FindFirstChild('KeyModel', true) or getPart(door))
		if part and part:IsA('Model') then
			local ok, p = pcall(function()
				return part:GetPivot().Position
			end)
			return ok and p or nil, part
		end
		return part and part.Position or nil, part
	end

	local function eachLocked(fn)
		local seen = {}
		local function take(door)
			if door and door.Parent and not seen[door] then
				seen[door] = true
				fn(door)
			end
		end
		for _, door in ipairs(keyDoors) do
			take(door)
		end
		for _, root in ipairs(workspace:GetChildren()) do
			if type(root.Name) == 'string' and root.Name:sub(1, 10) == 'Generated_' then
				for _, child in ipairs(root:GetChildren()) do
					if child.Name:sub(1, 7) == 'Locked_' then
						take(child)
					end
				end
			end
		end
	end

	-- Fire Use Key as fast as the executor allows. Prefer fireproximityprompt with
	-- the real HoldDuration (server still validates); fall back to a short hold.
	local function fireKeyPrompt(prompt)
		if not prompt or not prompt:IsA('ProximityPrompt') then
			return false
		end
		-- Gold Key HoldDuration is ~0.8s and the server checks it. Capping the
		-- hold at 0.35s is why Use Key looked like it fired but never opened.
		local hold = math.max(tonumber(prompt.HoldDuration) or 0, 0)
		pcall(function()
			prompt.MaxActivationDistance = math.max(tonumber(prompt.MaxActivationDistance) or 10, 24)
		end)
		if type(fireproximityprompt) == 'function' then
			pcall(fireproximityprompt, prompt, hold)
			pcall(fireproximityprompt, prompt, 1, hold)
			pcall(fireproximityprompt, prompt)
		elseif type(fireProximityPrompt) == 'function' then
			pcall(fireProximityPrompt, prompt, hold)
			pcall(fireProximityPrompt, prompt)
		end
		pcall(function()
			prompt:InputHoldBegin()
		end)
		task.wait(hold > 0 and (hold + 0.08) or 0.08)
		pcall(function()
			prompt:InputHoldEnd()
		end)
		return true
	end

	function api.find(fromPos, maxDist)
		maxDist = maxDist or 500
		local bestDoor, bestPrompt, bestDist
		pcall(scanEspThrottled, 1.5)
		eachLocked(function(door)
			local prompt = door:FindFirstChildWhichIsA('ProximityPrompt', true)
			if isUseKey(prompt, door) then
				local pos = keyAnchor(prompt, door)
				if pos then
					local d = (pos - fromPos).Magnitude
					if d <= maxDist and (not bestDist or d < bestDist) then
						bestDoor, bestPrompt, bestDist = door, prompt, d
					end
				end
			end
		end)
		return bestDoor, bestPrompt, bestDist
	end

	-- Snap to KeyModel + fire. No walk-through — NextArea handles crossing.
	function api.unlockDoor(door)
		if not wantOpenGates() then
			return false
		end
		if not door or not door.Parent then
			return false
		end
		if unlocked[door] then
			return false
		end
		local prompt = door:FindFirstChildWhichIsA('ProximityPrompt', true)
		local waitUntil = os.clock() + 1.6
		while (not prompt or not prompt.Parent or not isUseKey(prompt, door)) and os.clock() < waitUntil do
			task.wait(0.12)
			prompt = door:FindFirstChildWhichIsA('ProximityPrompt', true)
		end
		if not isUseKey(prompt, door) then
			return false
		end
		ghostDoor(door)
		local anchor, keyModel = keyAnchor(prompt, door)
		if not anchor then
			return false
		end
		local stand = promptStandPos(prompt, (keyModel and keyModel:IsA('Model')) and keyModel or door)
			or (anchor + Vector3.new(0, 2.6, 0))
		Pin.at(stand, true)
		task.wait(0.28)
		local deadline = os.clock() + 3.2
		while os.clock() < deadline and prompt.Parent and prompt.Enabled do
			fireKeyPrompt(prompt)
			task.wait(0.08)
		end
		local opened = not prompt.Parent or not prompt.Enabled
		if opened then
			unlocked[door] = true
			ghostDoor(door)
		end
		-- Keep the station pin so farm noclip cannot drop us while we wait for NextArea.
		if not opened then
			Pin.station()
		end
		return opened
	end

	function api.unlockForRoom(roomIdx)
		roomIdx = tonumber(roomIdx)
		if not roomIdx then
			return false
		end
		local did = false
		local zonePos
		pcall(function()
			local dungeon = activeDungeonRoot()
			local zone = dungeon and Rooms.zone(dungeon, roomIdx)
			zonePos = zone and zone.Position
		end)
		eachLocked(function(door)
			if did then
				return
			end
			local pri = tonumber(door:GetAttribute('ParentRoomIndex'))
			local near = false
			if zonePos then
				local part = getPart(door)
				if part and (part.Position - zonePos).Magnitude <= 90 then
					near = true
				end
			end
			if pri == roomIdx or pri == roomIdx + 1 or near then
				if api.unlockDoor(door) then
					did = true
				end
			end
		end)
		if did then
			lastAt = os.clock()
		end
		return did
	end

	function api.unlock(fromPos)
		if os.clock() - lastAt < 0.55 then
			return false
		end
		-- Prefer the gate tied to the room we are in / just cleared.
		local cur = Rooms and Rooms.sessionCurrentRoom and Rooms.sessionCurrentRoom()
		if cur and cur > 0 and api.unlockForRoom(cur) then
			return true
		end
		local door = api.find(fromPos, 550)
		if not door then
			return false
		end
		local ok = api.unlockDoor(door)
		if ok then
			lastAt = os.clock()
		end
		return ok
	end

	return api
end)()

-- ChestPrompt MaxActivationDistance is 8 and the server wants you inside the
-- chest volume. Standing beside the bbox left the prompt just out of range.
local function chestStandPos(model)
	if not model then
		return nil
	end
	local ok, cf, size = pcall(function()
		return model:GetBoundingBox()
	end)
	if ok and typeof(cf) == 'CFrame' and typeof(size) == 'Vector3' and size.Magnitude > 0.5 then
		return cf.Position
	end
	local anchor = chestAnchor(model)
	if not anchor then
		return nil
	end
	return anchor + Vector3.new(0, 2.2, 0)
end

local function chestActionOk(prompt)
	if not prompt then
		return false
	end
	local act = string.lower(tostring(prompt.ActionText or ''))
	if act == '' or act:find('loot', 1, true) or act:find('open', 1, true)
		or act:find('claim', 1, true) or act:find('ready', 1, true)
	then
		return true
	end
	local obj = string.lower(tostring(prompt.ObjectText or ''))
	return obj:find('chest', 1, true) ~= nil
end

local function markChestDone(model)
	if not model then
		return
	end
	rt.chestDone = rt.chestDone or {}
	rt.chestDone[model] = true
	local uid = model:GetAttribute('ChestUID')
	if uid then
		rt.chestDoneUid = rt.chestDoneUid or {}
		rt.chestDoneUid[tostring(uid)] = true
	end
end

-- Server never sets Looted/Opened/Claimed. Claimed chests spawn a Chest_Lock
-- child (prompt stays Action=Loot, Enabled=false). Unclaimed chests have no lock.
local function chestIsClaimed(model)
	if not model or not model.Parent then
		return true
	end
	if rt.chestDone and rt.chestDone[model] then
		return true
	end
	local uid = model:GetAttribute('ChestUID')
	if uid and rt.chestDoneUid and rt.chestDoneUid[tostring(uid)] then
		return true
	end
	if model:GetAttribute('Looted') == true
		or model:GetAttribute('Opened') == true
		or model:GetAttribute('Claimed') == true
	then
		return true
	end
	if model:FindFirstChild('Chest_Lock', true) then
		return true
	end
	return false
end

-- Prompt.Enabled is often false until you stand in range after the pack dies.
local function chestClaimCandidate(model)
	if not model or not model.Parent then
		return false
	end
	if not (model:GetAttribute('DungeonChest') == true or model.Name:sub(1, 13) == 'DungeonChest') then
		return false
	end
	if chestIsClaimed(model) then
		markChestDone(model)
		return false
	end
	if model:GetAttribute('LockedRoom') == true then
		local prompt = chestPrompt(model)
		local idx = tonumber(model:GetAttribute('RoomIndex'))
		local gated = idx and rt.chestRoomOpen and rt.chestRoomOpen[idx]
		if not wantOpenGates() then
			-- Gate stays shut — do not route to locked-room chests.
			if not (prompt and prompt.Enabled == true) then
				return false
			end
		elseif not gated and not (prompt and prompt.Enabled == true) then
			-- Server enables ChestPrompt only after the key door is open. Waiting
			-- for chestRoomOpen[1003] never fired — those IDs are not Room_N.
			return false
		end
	end
	if (rt.chestSkip and rt.chestSkip[model] or 0) > os.clock() then
		return false
	end
	local prompt = chestPrompt(model)
	return prompt ~= nil and chestActionOk(prompt)
end

local function chestStillOpen(model)
	if not chestClaimCandidate(model) then
		return false
	end
	local prompt = chestPrompt(model)
	return prompt ~= nil and prompt.Enabled == true
end

local function clearChestSkipForRoom(idx)
	if not idx or type(rt.chestSkip) ~= 'table' then
		return
	end
	for model in pairs(rt.chestSkip) do
		if model and tonumber(model:GetAttribute('RoomIndex')) == idx then
			rt.chestSkip[model] = nil
		end
	end
end

function rt.isBossish(npc)
	if not npc then
		return false
	end
	return npc:GetAttribute('IsBoss') == true
		or npc:GetAttribute('IsSpecialBoss') == true
		or npc:GetAttribute('IsMiniBoss') == true
end

function rt.anyAwakeNpc()
	for _, root in ipairs(workspace:GetChildren()) do
		if root.Name:sub(1, 10) == 'Generated_' then
			local folder = root:FindFirstChild('NPCs')
			for _, npc in ipairs(folder and folder:GetChildren() or {}) do
				if npc:GetAttribute('IsDormant') ~= true then
					local hum = npc:FindFirstChildOfClass('Humanoid')
					if hum and hum.Health > 0 then
						return true
					end
				end
			end
		end
	end
	return false
end

function rt.anyAwakeTrash()
	for _, root in ipairs(workspace:GetChildren()) do
		if root.Name:sub(1, 10) == 'Generated_' then
			local folder = root:FindFirstChild('NPCs')
			for _, npc in ipairs(folder and folder:GetChildren() or {}) do
				if npc:GetAttribute('IsDormant') ~= true and not rt.isBossish(npc) then
					local hum = npc:FindFirstChildOfClass('Humanoid')
					if hum and hum.Health > 0 then
						return true
					end
				end
			end
		end
	end
	return false
end

function rt.roomHasLiving(idx)
	if not idx then
		return false
	end
	for _, root in ipairs(workspace:GetChildren()) do
		if root.Name:sub(1, 10) == 'Generated_' then
			local folder = root:FindFirstChild('NPCs')
			for _, npc in ipairs(folder and folder:GetChildren() or {}) do
				if tonumber(npc:GetAttribute('RoomIndex')) == idx then
					local hum = npc:FindFirstChildOfClass('Humanoid')
					if hum and hum.Health > 0 then
						return true
					end
				end
			end
		end
	end
	return false
end

local function collectChestRoute(silent, roomOnly)
	if rt.refillUrgent or rt.refillBusy then
		return false
	end
	if routeBusy then
		return false
	end
	local root = routeRoot()
	if not root then
		if not silent then
			Library:Notify('No character to move')
		end
		return false
	end
	-- Gate already spent (Use Key prompt off) = LockedRoom chests are free.
	rt.chestRoomOpen = rt.chestRoomOpen or {}
	local keyStillOut = false
	for _, gen in ipairs(workspace:GetChildren()) do
		if gen.Name:sub(1, 10) == 'Generated_' then
			for _, child in ipairs(gen:GetChildren()) do
				if child.Name:sub(1, 7) == 'Locked_' then
					local p = child:FindFirstChildWhichIsA('ProximityPrompt', true)
					if p and p.Enabled == true then
						local blob = (tostring(p.ActionText) .. ' ' .. tostring(p.ObjectText)):lower()
						if blob:find('key', 1, true) or blob:find('unlock', 1, true) then
							keyStillOut = true
						end
					end
				end
			end
		end
	end
	if not keyStillOut and wantOpenGates() then
		for _, gen in ipairs(workspace:GetChildren()) do
			if gen.Name:sub(1, 10) == 'Generated_' then
				for _, child in ipairs(gen:GetChildren()) do
					if child:GetAttribute('LockedRoom') == true then
						local idx = tonumber(child:GetAttribute('RoomIndex'))
						if idx then
							rt.chestRoomOpen[idx] = true
						end
					end
				end
			end
		end
	end
	local queue = {}
	local function consider(model)
		if not model or not model.Parent then
			return
		end
		if roomOnly and tonumber(model:GetAttribute('RoomIndex')) ~= roomOnly then
			return
		end
		local idx = tonumber(model:GetAttribute('RoomIndex'))
		if idx and rt.roomHasLiving(idx) then
			return
		end
		-- Disabled prompts after a wipe still need a stand-in. Skip rooms that
		-- still have a living pack.
		if (chestStillOpen(model) or chestClaimCandidate(model)) and chestAnchor(model) then
			queue[#queue + 1] = model
		end
	end
	for _, model in ipairs(lootChests) do
		consider(model)
	end
	-- Fresh scan: prompts often flip Enabled a beat after the last kill, so the
	-- cached lootChests list can still look empty when the farm is ready to leave.
	if #queue == 0 or roomOnly then
		for _, gen in ipairs(workspace:GetChildren()) do
			if gen.Name:sub(1, 10) == 'Generated_' then
				for _, child in ipairs(gen:GetChildren()) do
					if child:GetAttribute('DungeonChest') == true or child.Name:sub(1, 13) == 'DungeonChest' then
						consider(child)
					end
				end
			end
		end
	end
	if #queue == 0 then
		if not silent then
			Library:Notify('No lootable chests found')
		end
		routeDoneAt = os.clock()
		return false
	end

	routeBusy = true
	local home = root.CFrame
	local wasNoclip = noclipOn
	local got = 0
	-- Run inline when the farm is waiting on this room: the old task.spawn let the
	-- farm walk away before prompts were fired.
	local function run()
		noclipOn = true
		pcall(setCharNoclip, true)
		if not rt.chestSkip then
			rt.chestSkip = {}
		end
		rt.chestRoomTried = rt.chestRoomTried or {}
		rt.chestRoomOpen = rt.chestRoomOpen or {}
		for i, model in ipairs(queue) do
			if rt.refillUrgent or rt.refillBusy then
				break
			end
			local live = routeRoot()
			if not live or not currentInstance() then
				break
			end
			-- Re-check after travel: claimed while we were en route.
			if chestIsClaimed(model) then
				markChestDone(model)
				rt.chestSkip[model] = os.clock() + 90
			elseif not chestClaimCandidate(model) then
				rt.chestSkip[model] = os.clock() + 8
			else
				if model:GetAttribute('LockedRoom') == true then
					local idx = tonumber(model:GetAttribute('RoomIndex'))
					local prompt = chestPrompt(model)
					local open = prompt and prompt.Enabled == true
					if wantOpenGates() then
						open = open or (idx and rt.chestRoomOpen[idx])
					end
					if not open then
						rt.chestSkip[model] = os.clock() + 400
						continue
					end
				end
				routeLabel = ('chest %d/%d'):format(i, #queue)
				local pos = chestStandPos(model)
				if pos then
					Pin.at(pos, true)
					-- Mesh often streams in after the first warp; re-stand in the
					-- live bounding-box center so the prompt is in range.
					task.wait((rt.chestFast and 0.18) or 0.35)
					local pos2 = chestStandPos(model)
					if pos2 and (pos2 - pos).Magnitude > 0.6 then
						Pin.at(pos2, true)
						task.wait((rt.chestFast and 0.1) or 0.2)
					end
					local prompt = chestPrompt(model)
					local roomIdx = tonumber(model:GetAttribute('RoomIndex'))
					local function fightFirst()
						return rt.anyAwakeTrash() or rt.roomHasLiving(roomIdx)
					end
					-- Server leaves Enabled=false until you are in the 8-stud bubble
					-- after the pack is dead. Do not treat that as "already claimed".
					local armUntil = os.clock() + ((rt.chestFast and 1.5) or 2.4)
					while prompt and prompt.Enabled ~= true and os.clock() < armUntil do
						if fightFirst() then
							Pin.stop()
							routeBusy = false
							routeLabel = nil
							return got > 0
						end
						task.wait(0.08)
						prompt = chestPrompt(model)
					end
					if prompt and prompt.Enabled then
						if fightFirst() then
							Pin.stop()
							routeBusy = false
							routeLabel = nil
							return got > 0
						end
						pcall(function()
							prompt.MaxActivationDistance = math.max(tonumber(prompt.MaxActivationDistance) or 8, 14)
						end)
						chestFiredAt[prompt] = nil
						fireChestPrompt(prompt)
						local deadline = os.clock() + ((rt.chestFast and 0.9) or 1.6)
						while os.clock() < deadline and chestStillOpen(model) do
							if fightFirst() then
								break
							end
							task.wait(0.05)
						end
						if not chestClaimCandidate(model) or not chestStillOpen(model) then
							got += 1
							markChestDone(model)
							rt.chestSkip[model] = os.clock() + 120
						else
							-- Failed this pass — retry soon, do not park the chest 3 min.
							rt.chestSkip[model] = os.clock() + 6
						end
					elseif chestIsClaimed(model) then
						markChestDone(model)
						rt.chestSkip[model] = os.clock() + 90
					else
						rt.chestSkip[model] = os.clock() + 6
					end
				end
			end
		end
		routeLabel = 'returning'
		local live = routeRoot()
		if live then
			pcall(function()
				live.CFrame = home
				live.AssemblyLinearVelocity = Vector3.zero
				live.AssemblyAngularVelocity = Vector3.zero
			end)
			Pin.at(home.Position)
			task.wait(0.25)
		end
		if not wasNoclip then
			noclipOn = false
			pcall(setCharNoclip, false)
			pcall(fixMovement)
			task.wait(0.2)
			local back = routeRoot()
			local hum = back and back.Parent and back.Parent:FindFirstChildOfClass('Humanoid')
			if back and hum and hum.FloorMaterial == Enum.Material.Air then
				pcall(function()
					back.CFrame = CFrame.new(standingSpot(home.Position, 0)) * (home - home.Position)
					back.AssemblyLinearVelocity = Vector3.zero
					back.AssemblyAngularVelocity = Vector3.zero
				end)
				if not silent then
					Library:Notify('Recovered from a fall through the floor')
				end
			end
		end
		Pin.stop()
		routeLabel = nil
		routeBusy = false
		routeDoneAt = os.clock()
		lastChestGrab = os.clock()
		if not silent or got > 0 then
			Library:Notify(('Chest route: %d/%d looted'):format(got, #queue))
		end
	end
	if roomOnly or farmBusy then
		run()
		return got > 0
	end
	task.spawn(run)
	return true
end

-- After a room wipe, unlock that room's Gold/Silver key gate first, then loot.
-- Prompts stay disabled for a beat; poll that room's chests before leaving.
local function inEndlessFarm()
	local d = tostring(
		LocalPlayer:GetAttribute('CurrentDifficultyMode')
			or LocalPlayer:GetAttribute('CurrentDifficulty')
			or rt.runDifficulty
			or ''
	)
	if string.lower(d):find('endless', 1, true) then
		return true
	end
	-- Some Endless floors leave CurrentDifficultyMode nil. The HUD container is
	-- the same signal the game uses for Depth / Enemies Left.
	local now = os.clock()
	if rt.endlessHudAt and now - rt.endlessHudAt < 1.25 then
		return rt.endlessHud == true
	end
	rt.endlessHudAt = now
	rt.endlessHud = false
	local pg = LocalPlayer:FindFirstChild('PlayerGui')
	local main = pg and pg:FindFirstChild('Main')
	local hud = main and main:FindFirstChild('HUD')
	local cont = hud and hud:FindFirstChild('Endless_Container')
	if cont and cont:IsA('GuiObject') and cont.Visible == true then
		rt.endlessHud = true
	end
	return rt.endlessHud == true
end

local function lootClearedRoom(roomIdx, dungeon)
	if not roomIdx then
		return false
	end
	if rt.roomHasLiving(roomIdx) then
		return false
	end
	pcall(function()
		if wantOpenGates() then
			KeyDoor.unlockForRoom(roomIdx)
		end
	end)
	if not dungeon then
		for _, root in ipairs(workspace:GetChildren()) do
			if root.Name:sub(1, 10) == 'Generated_' then
				dungeon = root
				break
			end
		end
	end
	if not dungeon then
		return false
	end
	farmLabel = ('looting Room_%d'):format(roomIdx)
	local deadline = os.clock() + (inEndlessFarm() and 1.2 or 2.2)
	local emptyPolls = 0
	while os.clock() < deadline do
		if not on('DLAutoFarm') then
			return false
		end
		if rt.roomHasLiving(roomIdx) or rt.anyAwakeTrash() then
			return false
		end
		pcall(scanEspThrottled, 0.9)
		local ready = false
		local sawChest = false
		local pending = false
		for _, child in ipairs(dungeon:GetChildren()) do
			if child:GetAttribute('DungeonChest') == true or child.Name:sub(1, 13) == 'DungeonChest' then
				local belongs = tonumber(child:GetAttribute('RoomIndex')) == roomIdx
				if not belongs then
					local pos = chestStandPos(child)
					belongs = pos ~= nil and Rooms.posInRoom(dungeon, roomIdx, pos)
				end
				if belongs then
					sawChest = true
					if chestClaimCandidate(child) then
						ready = true
						pending = true
						break
					end
					if not chestIsClaimed(child) then
						pending = true
					end
				end
			end
		end
		if ready then
			rt.chestFast = true
			local ok = collectChestRoute(true, roomIdx)
			rt.chestFast = false
			return ok
		end
		if sawChest and not pending then
			return false
		end
		if not sawChest then
			emptyPolls += 1
			if emptyPolls >= 4 then
				return false
			end
		end
		task.wait(inEndlessFarm() and 0.08 or 0.2)
	end
	-- Do not fall through to a map-wide sweep — that looted other rooms
	-- while packs were still up.
	return false
end

local spectateName = nil
local function stopSpectate()
	spectateName = nil
	local char = character()
	local hum = char and char:FindFirstChildOfClass('Humanoid')
	local cam = workspace.CurrentCamera
	if cam and hum then
		cam.CameraSubject = hum
		cam.CameraType = Enum.CameraType.Custom
	end
end

local function applySpectate()
	if not on('DLSpectate') then
		return
	end
	local name = spectateName or (Options.DLPlayerList and Options.DLPlayerList.Value)
	if type(name) ~= 'string' or name == '' then
		return
	end
	local plr = Players:FindFirstChild(name)
	local model = (plr and (plr.Character or (workspace:FindFirstChild('PlayerModels') and workspace.PlayerModels:FindFirstChild(name))))
	local hum = model and model:FindFirstChildOfClass('Humanoid')
	local cam = workspace.CurrentCamera
	if cam and hum then
		cam.CameraSubject = hum
	end
end

-- Locomotion / recover / hitstun must not arm a parry. Unnamed tracks used to
-- count as attacks, which is why parry fired after swings that already landed.
-- Returns (isAttack, guessed). Every mob in this game names its clips
-- "Animation" / "Animation1", so a guess carries no real signal — callers must
-- corroborate a guess with CanAttack before arming.
local function isAttackAnim(track, loose)
	local anim = track and track.Animation
	local name = string.lower(tostring(
		(anim and (anim.Name ~= '' and anim.Name or anim.AnimationId))
			or (track and track.Name)
			or ''
	))
	if name == '' then
		return loose == true, loose == true
	end
	if name:find('walk', 1, true)
		or name:find('run', 1, true)
		or name:find('idle', 1, true)
		or name:find('loco', 1, true)
		or name:find('strafe', 1, true)
		or name:find('sprint', 1, true)
		or name:find('jump', 1, true)
		or name:find('fall', 1, true)
		or name:find('land', 1, true)
		or name:find('swim', 1, true)
		or name:find('climb', 1, true)
		or name:find('recover', 1, true)
		or name:find('hitreact', 1, true)
		or name:find('hit_react', 1, true)
		or name:find('hurt', 1, true)
		or name:find('flinch', 1, true)
		or name:find('stun', 1, true)
		or name:find('death', 1, true)
		or name:find('die', 1, true)
		or name:find('spawn', 1, true)
		or name:find('despawn', 1, true)
		or name:find('sleep', 1, true)
		or name:find('wake', 1, true)
		or name:find('block', 1, true)
		or name:find('parry', 1, true)
		or name:find('emote', 1, true)
		or name:find('dance', 1, true)
		or name:find('buff', 1, true)
	then
		return false, false
	end
	local named = name:find('attack', 1, true)
		or name:find('slash', 1, true)
		or name:find('swing', 1, true)
		or name:find('strike', 1, true)
		or name:find('smash', 1, true)
		or name:find('punch', 1, true)
		or name:find('kick', 1, true)
		or name:find('bite', 1, true)
		or name:find('claw', 1, true)
		or name:find('slam', 1, true)
		or name:find('stomp', 1, true)
		or name:find('lunge', 1, true)
		or name:find('thrust', 1, true)
		or name:find('cast', 1, true)
		or name:find('spell', 1, true)
		or name:find('shoot', 1, true)
		or name:find('telegraph', 1, true)
		or name:find('windup', 1, true)
		or name:find('wind_up', 1, true)
		or name:find('skill', 1, true)
		or name:find('aoe', 1, true)
		or name:find('roar', 1, true)
	if named then
		return true, false
	end
	-- Boss clips are often unnamed rbxassetid ids. After the locomotion reject
	-- above, treat longer non-looped clips as swings. Short loops are idle/walk.
	if loose == true then
		local len, looped = 0, false
		pcall(function()
			len = track.Length or 0
			looped = track.Looped == true
		end)
		if looped then
			return false, false
		end
		if len < 0.55 or len > 4.5 then
			return false, false
		end
		return true, true
	end
	return false, false
end

-- Specials / bosses hit in the first third of the clip. Waiting until
-- (length - 0.22) parked F after Scarlet Knight's swing already landed.
rt.bossAnimHitWait = function(len, tpos)
	len = tonumber(len) or 0
	tpos = tonumber(tpos) or 0
	if len <= 0 then
		return 0.08, false
	end
	local hitAt = math.clamp(len * 0.34, 0.12, math.max(0.12, len - 0.08))
	local wait = hitAt - tpos
	if wait <= 0.06 then
		return 0, true
	end
	return wait, false
end

rt.telegraphLit = function(npc)
	local now = os.clock()
	rt.telLitAt = rt.telLitAt or {}
	rt.telLitVal = rt.telLitVal or {}
	if (rt.telLitAt[npc] or 0) + 0.12 > now then
		return rt.telLitVal[npc] == true
	end
	rt.telLitAt[npc] = now
	local root = npc and npc:FindFirstChild('Telegraph_Root')
	if not root then
		rt.telLitVal[npc] = false
		return false
	end
	if root:IsA('BasePart') and root.Transparency < 0.92 then
		rt.telLitVal[npc] = true
		return true
	end
	local function fxOn(d)
		if not (
			d:IsA('Beam')
			or d:IsA('ParticleEmitter')
			or d:IsA('Trail')
			or d:IsA('Highlight')
			or d:IsA('BillboardGui')
		) then
			return false
		end
		local ok, en = pcall(function()
			return d.Enabled
		end)
		return ok and en == true
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA('BasePart') and d.Transparency < 0.92 then
			local sz = d.Size
			if sz.X > 1.5 or sz.Y > 1.5 or sz.Z > 1.5 then
				rt.telLitVal[npc] = true
				return true
			end
		elseif fxOn(d) then
			rt.telLitVal[npc] = true
			return true
		end
	end
	rt.telLitVal[npc] = false
	return false
end

-- Rising edge only — staying lit must not keep re-arming F every scan.
rt.telegraphRose = function(npc)
	rt.telWasLit = rt.telWasLit or {}
	local lit = rt.telegraphLit(npc)
	local was = rt.telWasLit[npc] == true
	rt.telWasLit[npc] = lit
	return lit and not was
end

-- Fresh wind-up only. mode 'boss-wind' keeps pushing fire later (closer to the
-- hit). 'boss-hit' fires immediately — telegraph ending / anim almost done.
-- Pushing fireAt into the parry-CD future is what made us tap F after the swing
-- already connected on fodder; bosses need the opposite.
-- Set getgenv().DLParryDebug = true to trace which cue armed each press.
function rt.pdbg(fmt, ...)
	if getgenv().DLParryDebug then
		print('[parry] ' .. string.format(fmt, ...))
	end
end

-- Measured on the live client: F opens the window 82ms later and holds it 645ms.
rt.PARRY_OPEN = 0.082
rt.PARRY_HOLD = 0.645

-- Learned attack timing.
--
-- CanAttack is a short pulse (~0.12s), not the wind-up, and the hit lands a fixed
-- lag after it — per attack, not per mob. Broken Reality lands one swing at
-- rise+0.88 and the other at rise+1.35, so no single hardcoded lead covers both:
-- the old 0.45s default opened the window before the late swing and closed again
-- before it arrived. Learn the lag from the damage we actually take and place the
-- press so one window brackets every hit we have seen from that mob.
rt.canRise = {}
rt.hitLag = {}

function rt.noteCanRise(npc)
	rt.canRise[npc] = os.clock()
end

function rt.learnHitLag()
	local now = os.clock()
	local best, bestT = nil, nil
	for npc, t in pairs(rt.canRise) do
		if not npc.Parent or now - t > 3 then
			rt.canRise[npc] = nil
		elseif not bestT or t > bestT then
			best, bestT = npc, t
		end
	end
	if not best then
		return
	end
	local lag = now - bestT
	-- Under 0.15s is the hit we already ate before the cue; over 2.5s is unrelated.
	if lag < 0.15 or lag > 2.5 then
		return
	end
	local name = tostring(best.Name)
	local list = rt.hitLag[name]
	if not list then
		list = {}
		rt.hitLag[name] = list
	end
	list[#list + 1] = lag
	if #list > 10 then
		table.remove(list, 1)
	end
	rt.pdbg('learn %s hit at rise+%.2f (n=%d)', name, lag, #list)
end

-- Press delay that keeps the whole observed spread inside one window:
-- press <= earliestHit - open, and press >= latestHit - (open + hold).
function rt.learnedLead(name)
	local list = rt.hitLag[tostring(name)]
	if not list or #list < 3 then
		return nil
	end
	local lo, hi = math.huge, -math.huge
	local sorted = {}
	for _, v in ipairs(list) do
		lo = math.min(lo, v)
		hi = math.max(hi, v)
		sorted[#sorted + 1] = v
	end
	-- Margins stay tiny on purpose. Broken Reality's two swings land at rise+0.80
	-- and rise+1.42, a 0.62s spread against a 0.645s window: the press that covers
	-- both is a ~25ms sliver, and a 0.03s margin on each side was enough to discard
	-- it and fall back to covering only the early swing.
	local earliest = hi - (rt.PARRY_OPEN + rt.PARRY_HOLD) + 0.01
	local latest = lo - rt.PARRY_OPEN - 0.01
	if earliest > latest then
		-- Spread is wider than one window, so no press covers everything. Centre on
		-- the median swing rather than guessing at the extremes.
		table.sort(sorted)
		local mid = sorted[math.ceil(#sorted / 2)]
		return math.clamp(mid - (rt.PARRY_OPEN + rt.PARRY_HOLD * 0.5), 0.02, 1.4)
	end
	return math.clamp((earliest + latest) * 0.5, 0.02, 1.4)
end

function rt.parryNotif(npc)
	return npc and npc:FindFirstChild('Parry_Notification', true)
end

function rt.fCueLit(npc)
	local pn = rt.parryNotif(npc)
	return pn ~= nil and pn:GetAttribute('Fire') == true
end

-- Real swings pulse CanAttack ~0.25s before the red F. Dashes light F too but
-- never pulse CanAttack. DashIFrameUntil stays minutes in the future after a
-- dash, so treating "until > time()" as dashing made every F look like a dash
-- and parry stopped entirely.
function rt.recentCanAttack(npc, window)
	local t = rt.canRise[npc]
	return type(t) == 'number' and (os.clock() - t) <= (window or 0.55)
end

function rt.noteFCueAnim(npc, track)
	if not npc or not track then
		return
	end
	local name = string.lower(tostring(track.Name or ''))
	local len, looped = 0, false
	pcall(function()
		local a = track.Animation
		if a and a.Name ~= '' then
			name = string.lower(tostring(a.Name))
		end
		len = track.Length or 0
		looped = track.Looped == true
	end)
	local now = os.clock()
	if name:find('walk', 1, true) or name:find('run', 1, true) or name:find('idle', 1, true) then
		if not rt.fCueLit(npc) then
			rt.fFollowParryAt = 0
			rt.fAwaitFollow = 0
			rt.fNoFollow = true
		end
		return
	end
	if rt.fNoFollow and not rt.fCueLit(npc) then
		return
	end
	if looped or len < 0.22 or len > 4.2 then
		return
	end
	if rt.fCueLit(npc) then
		if now - (rt.fOnAt or 0) > 6 then
			return
		end
		-- F is the telegraph. The swing clip starts ~0.35s later; pressing the
		-- instant the letter shows expires before the long channel's 89s.
		if len >= 1.05 then
			rt.fLongUntil = now + len
			rt.fFollowParryAt = now + 0.40
			rt.fFollowParryUntil = now + len + 0.2
			return
		end
		if len < 0.35 then
			rt.fFollowParryAt = now
			rt.fFollowParryUntil = now + 0.55
		end
		return
	end
	-- Letter hid. Short follow-up clip starts ~0.36s later (hit ~F-off+0.85);
	-- the long letter's 56 lands ~F-off+1.50 on a similar-length clip.
	if (rt.fAwaitFollow or 0) > 0 or (now - (rt.fParriedAt or 0) < 6.5 and now - (rt.fOnAt or 0) < 7) then
		local longLetter = (rt.fLetterHeld or 0) >= 2.8
		local delay = longLetter and 0.68 or 0.16
		rt.fFollowParryAt = now + delay
		rt.fFollowParryUntil = now + delay + 0.78
		rt.fAwaitFollow = 0
		if longLetter then
			rt.fLongUntil = math.max(rt.fLongUntil or 0, now + 1.9)
			rt.fFollowParryUntil = now + 1.95
		end
		rt.pdbg('F2 arm after clip len=%.2f held=%.2f delay=%.2f', len, rt.fLetterHeld or 0, delay)
	end
end

local function armParry(delay, mode, why, learned, forced)
	delay = tonumber(delay) or 0
	local now = os.clock()
	rt.pdbg('arm mode=%s delay=%.2f src=%s%s', tostring(mode or 'fodder'), delay, tostring(why or '?'), learned and ' LEARNED' or (forced and ' F' or ''))
	local sinceFire = now - (rt.parryFire or 0)
	-- Frame debounce only.
	if sinceFire < 0.12 then
		return
	end
	-- The red F over a boss is Parry_Notification.Fire. That is the real window,
	-- so it still arms even if a leftover learned lock or a just-spent cooldown
	-- would have eaten the cue — the tick then parries if ready, else dodges.
	if not forced then
		-- Past the debounce, the server attributes are the truth: a successful parry
		-- clears Parry_Cooldown_Active early, and a flat post-fire lockout made us sit
		-- out the rest of a combo instead of using the refund.
		if sinceFire < 0.55 then
			local ch = character()
			if LocalPlayer:GetAttribute('Parry_Cooldown_Active') == true
				or (ch and ch:GetAttribute('Parry') == true)
			then
				return
			end
		end
		-- A learned arm already knows when this swing lands. Every later cue for the
		-- same swing is noise by comparison — telegraph flicker, anim markers, and the
		-- telegraph fade that only happens *after* the hit — and letting them re-time
		-- the press is what pulled F off the swing it was waiting for.
		if learned then
			rt.parryLock = now + delay
			rt.learnedUntil = now + delay + rt.PARRY_HOLD + 0.2
		elseif now < (rt.parryLock or 0) or now < (rt.learnedUntil or 0) then
			rt.pdbg('skip %s src=%s (learned press owns this swing)', tostring(mode or 'fodder'), tostring(why or '?'))
			return
		end
	else
		rt.fCueUntil = now + 0.85
		rt.parryLock = 0
		rt.learnedUntil = 0
	end
	if mode == 'boss-hit' then
		rt.bossCueAt = now
		-- 0, not `now`: autoParryTick snapshots the clock before we arm, so
		-- setting delay to this call's clock made `now < parryDelay` forever and
		-- F only pressed after the red letter hid.
		rt.parryDelay = 0
		rt.parryArmed = math.max(rt.parryArmed or 0, now + 0.55)
		rt.parryCue = forced and 'F' or 'hit'
		return
	end
	local fireAt = now + math.max(0, delay)
	if mode == 'boss-wind' then
		rt.bossCueAt = now
		if (rt.parryArmed or 0) <= now then
			rt.parryDelay = fireAt
		elseif fireAt < (rt.parryDelay or 0) and fireAt >= now then
			-- Keep the sooner hit estimate. Sliding toward clip-end missed
			-- Scarlet Knight / Dark Professor swings.
			rt.parryDelay = fireAt
		end
		rt.parryArmed = math.max(rt.parryArmed or 0, (rt.parryDelay or fireAt) + math.max(0.28, delay * 0.2))
		rt.parryCue = 'wind'
		return
	end
	-- A boss in the fight owns the parry. Fodder chip is ~150 a hit while boss
	-- swings run 400+, and once fodder cues could arm (they never used to) they
	-- held the 1.8s cooldown down through every boss wind-up. Dodge still covers
	-- the fodder hit, and panicDodge still covers low HP.
	if now - (rt.bossNearAt or 0) < 1.0 and now - (rt.bossCueAt or 0) < 3.0 then
		return
	end
	if rt.parryDelay <= now or fireAt < rt.parryDelay then
		rt.parryDelay = fireAt
	end
	local hold = math.max(0.16, delay * 0.3 + 0.16)
	rt.parryArmed = math.max(rt.parryArmed, fireAt + hold)
	rt.parryCue = 'fodder'
end

-- Boss wind-ups are long, so firing the instant a telegraph appears parries too
-- early and burns the cooldown before the hit lands. This is the lead time.
local function bossParryDelay()
	local v = Options.DLParryBossDelay and tonumber(Options.DLParryBossDelay.Value)
	return v or 0.45
end

local function combatRemote(name)
	local playerFolder = game:GetService('ReplicatedStorage'):FindFirstChild('Player')
	local inputs = playerFolder and playerFolder:FindFirstChild('Remotes') and playerFolder.Remotes:FindFirstChild('Inputs')
	local rem = inputs and inputs:FindFirstChild(name)
	if rem and rem:IsA('RemoteEvent') then
		return rem
	end
	return nil
end

local function parryRemote()
	local rem = combatRemote('Parry')
	if rem then
		rem:FireServer()
		return true
	end
	return false
end

rt.dodgeReady = function(allowSkill)
	if LocalPlayer:GetAttribute('Dodge_Cooldown_Active') == true then
		return false
	end
	if not farmBusy and LocalPlayer:GetAttribute('InNoCombatZone') == true then
		return false
	end
	if not farmBusy
		and LocalPlayer:GetAttribute('InDungeon') ~= true
		and LocalPlayer:GetAttribute('DungeonRun') ~= true
	then
		return false
	end
	local char = character()
	if not char then
		return false
	end
	-- Already invuln: spending the dash CD here just leaves the next hit uncovered.
	-- Follow-up after a red-F parry is allowed through SkillIFrame: auto skill holds
	-- that flag for half the fight and was eating every scheduled Q.
	if char:GetAttribute('iFrame') == true
		or (not allowSkill and char:GetAttribute('SkillIFrame') == true)
		or char:GetAttribute('HitIFrame') == true
		or LocalPlayer:GetAttribute('iFrame') == true
		or char:GetAttribute('Parry') == true
	then
		return false
	end
	if rt.hpPct() <= 0 then
		return false
	end
	-- Same idea as parry: a successful dodge refunds Dodge_Cooldown_Active, so a
	-- long local lockout was throwing the next dash away. Frame debounce only.
	if os.clock() - (rt.dodgeFire or 0) < 0.12 then
		return false
	end
	return true
end

rt.fireDodge = function(forcedDir)
	local rem = combatRemote('Dash')
	local char = character()
	local myRoot = char and (char:FindFirstChild('HumanoidRootPart') or char.PrimaryPart)
	local dir = forcedDir
	if typeof(dir) ~= 'Vector3' then
		dir = nil
	end
	if myRoot and not dir then
		local bestD
		for _, npc in ipairs(enemyCache) do
			if npc and npc.Parent then
				local part = npc:FindFirstChild('HumanoidRootPart')
				if not part and npc:IsA('Model') then
					part = npc.PrimaryPart
				elseif not part and npc:IsA('BasePart') then
					part = npc
				end
				if part then
					local d = (part.Position - myRoot.Position).Magnitude
					if d <= 70 and (not bestD or d < bestD) then
						bestD = d
						local flat = Vector3.new(myRoot.Position.X - part.Position.X, 0, myRoot.Position.Z - part.Position.Z)
						if flat.Magnitude > 0.2 then
							dir = flat.Unit
						end
					end
				end
			end
		end
		if not dir then
			local look = myRoot.CFrame.LookVector
			dir = Vector3.new(look.X, 0, look.Z)
			if dir.Magnitude > 0.2 then
				dir = dir.Unit
			else
				dir = Vector3.new(0, 0, -1)
			end
		end
	end
	local ok = false
	if rem then
		ok = pcall(function()
			rem:FireServer(dir)
		end)
		if not ok then
			ok = pcall(function()
				rem:FireServer()
			end)
		end
	end
	-- Mobile dodge button is the same Q bind; click it if the remote signature missed.
	if not ok then
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		local main = pg and pg:FindFirstChild('Main')
		local hud = main and main:FindFirstChild('HUD')
		local btn = hud and hud:FindFirstChild('MobileActions')
		btn = btn and btn:FindFirstChild('Dodge')
		if btn and btn:IsA('GuiButton') then
			if type(firesignal) == 'function' then
				ok = pcall(firesignal, btn.MouseButton1Click)
			end
			if not ok and type(getconnections) == 'function' then
				local got, cons = pcall(getconnections, btn.MouseButton1Click)
				if got and type(cons) == 'table' then
					for _, c in ipairs(cons) do
						if c.Function then
							task.spawn(c.Function)
							ok = true
						end
					end
				end
			end
		end
	end
	return ok
end

-- Dark Professor paints red/yellow airstrike discs on the floor. Q-dash is
-- useless here — they cover the arena, so find a gap and stand in it.
-- Those discs often spawn as short-named workspace Parts (e.g. Workspace.R),
-- not under SpellTelegraphs.
rt.avoidFloorAoe = function()
	local myRoot = routeRoot()
	local char = character()
	if not myRoot or not char then
		return false
	end
	local me = myRoot.Position
	local circles = {}
	local function namedDanger(n)
		n = string.lower(tostring(n or ''))
		return n:find('circle', 1, true)
			or n:find('ring', 1, true)
			or n:find('aoe', 1, true)
			or n:find('airstrike', 1, true)
			or n:find('bomb', 1, true)
			or n:find('strike', 1, true)
			or n:find('meteor', 1, true)
			or n:find('nova', 1, true)
			or n:find('smash', 1, true)
			or n:find('slam', 1, true)
			or n:find('telegraph', 1, true)
			or n:find('indicator', 1, true)
	end
	local function underTelegraphFolder(part)
		local p = part
		for _ = 1, 8 do
			if not p then
				return false
			end
			local n = string.lower(tostring(p.Name or ''))
			if n == 'spelltelegraphs' or n == 'telegraphs' or n == 'telegraph_root' then
				return true
			end
			p = p.Parent
		end
		return false
	end
	local function addPart(part)
		if not part or part == workspace.Terrain then
			return
		end
		local isPart = false
		pcall(function()
			isPart = part:IsA('BasePart')
		end)
		if not isPart then
			return
		end
		local trans = 1
		pcall(function()
			trans = part.Transparency
		end)
		if trans >= 0.97 then
			return
		end
		local underChar = false
		pcall(function()
			underChar = part:IsDescendantOf(char)
		end)
		if underChar then
			return
		end
		local pos, size
		pcall(function()
			pos = part.Position
			size = part.Size
		end)
		if typeof(pos) ~= 'Vector3' or typeof(size) ~= 'Vector3' then
			return
		end
		local dx = pos.X - me.X
		local dz = pos.Z - me.Z
		if (dx * dx + dz * dz) > 14400 then
			return
		end
		local ok, col = pcall(function()
			return part.Color
		end)
		local hot = ok and col and (
			(col.R > 0.5 and col.G < 0.5 and col.B < 0.48)
			or (col.R > 0.65 and col.G > 0.35 and col.B < 0.4)
			or (col.R > 0.45 and col.G < 0.35 and col.B > 0.45)
		)
		-- Cylinder floor discs often use Size (thick, diam, diam) so Y is large.
		local sx, sy, sz = size.X, size.Y, size.Z
		local thick = math.min(sx, sy, sz)
		local span = math.max(sx, sy, sz)
		local flat = thick < 8 and span >= 5
		local neon = false
		pcall(function()
			neon = part.Material == Enum.Material.Neon or part.Material == Enum.Material.ForceField
		end)
		local collide = true
		pcall(function()
			collide = part.CanCollide == true
		end)
		local short = #tostring(part.Name) <= 2
		local disc = flat and (hot or neon or (not collide and span >= 8))
		local loose = (part.Parent == workspace or short) and disc
		local folderHit = underTelegraphFolder(part) and span >= 4
		if not (namedDanger(part.Name) or folderHit or (hot and flat) or loose) then
			return
		end
		local r = math.max(6, span * 0.5)
		circles[#circles + 1] = { x = pos.X, z = pos.Z, r = r }
	end
	local function scan(root, cap)
		if not root then
			return
		end
		local n = 0
		for _, d in ipairs(root:GetDescendants()) do
			n += 1
			if n > (cap or 120) then
				break
			end
			addPart(d)
		end
	end
	-- Dark Professor P2 puts orange cylinders straight under workspace.SpellTelegraphs.
	do
		local folder = workspace:FindFirstChild('SpellTelegraphs')
		if folder then
			for _, ch in ipairs(folder:GetChildren()) do
				addPart(ch)
			end
			scan(folder, 200)
		end
	end
	scan(workspace:FindFirstChild('ActiveProjectiles'), 80)
	scan(workspace:FindFirstChild('Effects'), 160)
	scan(workspace:FindFirstChild('Particles'), 80)
	for _, ch in ipairs(workspace:GetChildren()) do
		if ch:IsA('BasePart') and ch ~= workspace.Terrain then
			addPart(ch)
		elseif type(ch.Name) == 'string' and ch.Name:sub(1, 10) == 'Generated_' then
			scan(ch:FindFirstChild('SpellTelegraphs'), 80)
			scan(ch:FindFirstChild('Telegraphs'), 80)
			scan(ch:FindFirstChild('Particles'), 80)
			local folder = ch:FindFirstChild('NPCs')
			if folder then
				for _, npc in ipairs(folder:GetChildren()) do
					scan(npc:FindFirstChild('Telegraph_Root'), 80)
				end
			end
		end
	end
	local raid = workspace:FindFirstChild('Raid_NPCs')
	if raid then
		for _, npc in ipairs(raid:GetChildren()) do
			scan(npc:FindFirstChild('Telegraph_Root'), 80)
		end
	end
	local ring = char:FindFirstChild('Ring', true)
	if ring and (ring:IsA('ParticleEmitter') or ring:IsA('Beam') or ring:IsA('Trail')) then
		local ok, en = pcall(function()
			return ring.Enabled
		end)
		if ok and en == true then
			circles[#circles + 1] = { x = me.X, z = me.Z, r = 10 }
		end
	end
	if #circles == 0 then
		rt.aoeUntil = 0
		rt.aoeGoal = nil
		return false
	end
	local function covered(x, z, pad)
		pad = pad or 3
		for i = 1, #circles do
			local c = circles[i]
			local dx = x - c.x
			local dz = z - c.z
			local need = c.r + pad
			if dx * dx + dz * dz < need * need then
				return true
			end
		end
		return false
	end
	-- Already clear of discs: keep a sticky safe park. Do not rewrite aoeGoal every
	-- scan — that made Pin thrash and ate M1 / skill input.
	if not covered(me.X, me.Z, 2.5) then
		if typeof(rt.aoeGoal) ~= 'Vector3' or covered(rt.aoeGoal.X, rt.aoeGoal.Z, 2.5) then
			rt.aoeGoal = Vector3.new(me.X, me.Y, me.Z)
		end
		rt.aoeUntil = os.clock() + 0.9
		return true
	end
	local best, bestD = nil, nil
	local function tryAt(x, z)
		if covered(x, z, 3) then
			return
		end
		local dx = x - me.X
		local dz = z - me.Z
		local d = dx * dx + dz * dz
		if not bestD or d < bestD then
			bestD = d
			best = Vector3.new(x, me.Y, z)
		end
	end
	for i = 1, #circles do
		local c = circles[i]
		local fx, fz = me.X - c.x, me.Z - c.z
		local mag = math.sqrt(fx * fx + fz * fz)
		local ux, uz = 1, 0
		if mag > 0.4 then
			ux, uz = fx / mag, fz / mag
		end
		tryAt(c.x + ux * (c.r + 8), c.z + uz * (c.r + 8))
	end
	for i = 0, 15 do
		local a = i / 16 * math.pi * 2
		local ca, sa = math.cos(a), math.sin(a)
		tryAt(me.X + ca * 12, me.Z + sa * 12)
		tryAt(me.X + ca * 20, me.Z + sa * 20)
		tryAt(me.X + ca * 30, me.Z + sa * 30)
	end
	if not best then
		-- Nowhere clean: stand on the least-covered candidate.
		local least, leastN = nil, 1e9
		for i = 0, 15 do
			local a = i / 16 * math.pi * 2
			local x = me.X + math.cos(a) * 18
			local z = me.Z + math.sin(a) * 18
			local n = 0
			for j = 1, #circles do
				local c = circles[j]
				local dx, dz = x - c.x, z - c.z
				if dx * dx + dz * dz < (c.r + 2) * (c.r + 2) then
					n += 1
				end
			end
			if n < leastN then
				leastN = n
				least = Vector3.new(x, me.Y, z)
			end
		end
		best = least
	end
	if not best then
		return false
	end
	-- Sticky gap: only retarget if the old goal is covered or far from the new best.
	if typeof(rt.aoeGoal) == 'Vector3' and not covered(rt.aoeGoal.X, rt.aoeGoal.Z, 2.5) then
		local dx = rt.aoeGoal.X - best.X
		local dz = rt.aoeGoal.Z - best.Z
		if (dx * dx + dz * dz) < 36 then
			best = rt.aoeGoal
		end
	end
	rt.aoeGoal = best
	-- Hold the gap for the full telegraph window; refresh while discs stay up.
	rt.aoeUntil = os.clock() + 2.4
	return true
end

local function parryReady()
	if LocalPlayer:GetAttribute('Parry_Cooldown_Active') == true then
		return false
	end
	-- Farm pin / under-floor height can trip the lobby combat-zone flag. Still
	-- parry while a run is in progress.
	if not farmBusy and LocalPlayer:GetAttribute('InNoCombatZone') == true then
		return false
	end
	if not farmBusy
		and LocalPlayer:GetAttribute('InDungeon') ~= true
		and LocalPlayer:GetAttribute('DungeonRun') ~= true
	then
		return false
	end
	local char = character()
	if not char then
		return false
	end
	if char:GetAttribute('Parry') == true then
		return false
	end
	local hum = char:FindFirstChildOfClass('Humanoid')
	if not hum or hum.Health <= 0 then
		return false
	end
	-- Frame debounce only. Parry_Cooldown_Active and char Parry above are the real
	-- gate, and the game refunds the cooldown on a successful parry — a longer
	-- lockout here threw that refund away.
	if os.clock() - rt.parryFire < 0.12 then
		return false
	end
	return true
end

local function unwatchEnemy(npc)
	local bag = enemyWatches[npc]
	if not bag then
		return
	end
	enemyWatches[npc] = nil
	for _, c in ipairs(bag) do
		pcall(function()
			c:Disconnect()
		end)
	end
end

local function clearEnemyWatches()
	for npc in pairs(enemyWatches) do
		unwatchEnemy(npc)
	end
end

local function enemyHumanoid(npc)
	return npc:FindFirstChildOfClass('Humanoid')
end

local function enemyRoot(npc)
	if not npc then
		return nil
	end
	-- Floor circles / VFX sometimes land in the NPC list as Parts (Workspace.R).
	-- PrimaryPart only exists on Models — indexing it here used to kill autofarm.
	if npc:IsA('BasePart') then
		return npc, npc:FindFirstChildOfClass('Humanoid')
	end
	local hum = enemyHumanoid(npc)
	if hum and hum.RootPart then
		return hum.RootPart, hum
	end
	local part = npc:FindFirstChild('HumanoidRootPart')
	if not part and npc:IsA('Model') then
		part = npc.PrimaryPart
	end
	part = part or npc:FindFirstChildWhichIsA('BasePart')
	if part then
		return part, hum
	end
	-- Floor bosses stream out their HRP (Valkskar = accessories only) but keep a
	-- WorldPivot. Fodder leftovers stay nil so they are not counted as trash.
	if npc:GetAttribute('IsBoss') == true
		or npc:GetAttribute('IsMiniBoss') == true
		or npc:GetAttribute('IsSpecialBoss') == true
	then
		local ok, cf = pcall(function()
			return npc:GetPivot()
		end)
		local pos = ok and cf and cf.Position
		if pos and pos.Magnitude > 10 then
			rt.bossRoot = rt.bossRoot or {}
			local proxy = rt.bossRoot[npc]
			if type(proxy) ~= 'table' then
				proxy = {}
				rt.bossRoot[npc] = proxy
			end
			proxy.Position = pos
			proxy.Size = Vector3.new(2, 5, 2)
			proxy.Parent = npc
			return proxy, hum
		end
	end
	return nil, hum
end

-- Bosses run on an AnimationController with no Humanoid and only expose
-- HealthOverride (their max); current HP is server-side. So liveness for them is
-- "still parented and not flagged dead" rather than a health read.
local function enemyHealth(npc)
	local hum = enemyHumanoid(npc)
	if hum then
		return hum.Health, hum.MaxHealth
	end
	return nil, tonumber(npc:GetAttribute('HealthOverride'))
end

local function enemyAlive(npc)
	if not npc or not npc.Parent then
		return false
	end
	if farmSkipped(npc) then
		return false
	end
	local state = string.lower(tostring(npc:GetAttribute('State') or ''))
	if state == 'dead' or state == 'died' or state == 'dying' then
		return false
	end
	local hp = enemyHealth(npc)
	if hp ~= nil then
		return hp > 0
	end
	return true
end

local function isWorldEnemy(npc)
	if not npc or not npc.Parent then
		return false
	end
	if not npc:IsDescendantOf(workspace) then
		return false
	end
	if npc.Parent.Name == 'Dialogue_NPCS' or npc.Parent.Name == 'PlayerModels' then
		return false
	end
	for _, tag in ipairs(CollectionService:GetTags(npc)) do
		if tag == 'Idle_NPC' or tag == 'DialogueNPC' then
			return false
		end
	end
	return true
end

local function isBossEnemy(npc)
	if not npc then
		return false
	end
	if npc:GetAttribute('IsBoss') == true
		or npc:GetAttribute('IsSpecialBoss') == true
		or npc:GetAttribute('IsMiniBoss') == true
	then
		return true
	end
	if npc:GetAttribute('IsFodder') == false then
		return true
	end
	local id = string.lower(tostring(npc:GetAttribute('ItemId') or npc.Name or ''))
	if id:find('boss', 1, true)
		or id:find('miniboss', 1, true)
		or id:find('mini_boss', 1, true)
		or id:find('monarch', 1, true)
		or id:find('imperator', 1, true)
		or id:find('warden', 1, true)
	then
		return true
	end
	local _, hum = enemyRoot(npc)
	if hum and hum.MaxHealth >= 1500 then
		return true
	end
	return false
end

local function isMiniBossEnemy(npc)
	if not npc then
		return false
	end
	if npc:GetAttribute('IsMiniBoss') == true then
		return true
	end
	local id = string.lower(tostring(npc:GetAttribute('ItemId') or npc.Name or ''))
	return id:find('miniboss', 1, true)
		or id:find('mini_boss', 1, true)
		or id:find('mini-boss', 1, true)
		or false
end

local function isEliteEnemy(npc)
	return npc and npc:GetAttribute('IsElite') == true
end

local function enemyRank(npc)
	if not npc then
		return 0
	end
	if npc:GetAttribute('IsSpecialBoss') == true
		or npc:GetAttribute('IsSpecial') == true
	then
		return 4
	end
	local id = string.lower(tostring(npc:GetAttribute('ItemId') or npc.Name or ''))
	if id:find('special', 1, true) then
		return 4
	end
	if npc:GetAttribute('IsBoss') == true and not isMiniBossEnemy(npc) then
		return 3
	end
	if isMiniBossEnemy(npc) then
		return 3
	end
	if isEliteEnemy(npc) then
		return 2
	end
	if isBossEnemy(npc) then
		return 3
	end
	return 1
end

local function enemyEspColor(npc)
	if npc:GetAttribute('IsSpecialBoss') == true or (npc:GetAttribute('IsBoss') == true and not isMiniBossEnemy(npc)) then
		return ENEMY_BOSS_COLOR
	end
	if isMiniBossEnemy(npc) then
		return ENEMY_MINI_COLOR
	end
	if isEliteEnemy(npc) then
		return ENEMY_ELITE_COLOR
	end
	return ENEMY_COLOR
end

local function enemyEspTag(npc)
	if npc:GetAttribute('IsSpecialBoss') == true
		or npc:GetAttribute('IsSpecial') == true
		or string.lower(tostring(npc:GetAttribute('ItemId') or npc.Name or '')):find('special', 1, true)
	then
		return 'SPECIAL'
	end
	if isMiniBossEnemy(npc) then
		return 'MINI'
	end
	if npc:GetAttribute('IsBoss') == true then
		return 'BOSS'
	end
	if isEliteEnemy(npc) then
		return 'ELITE'
	end
	return nil
end

-- Infinite Yield–style Drawing tracers (screen lines), updated every frame so they
-- do not vanish when billboards stream out or scanEsp throttles mid-farm.
local enemyTracers = {}
local enemyEspList, enemyEspAt = {}, 0

local function clearEnemyTracers()
	for _, t in pairs(enemyTracers) do
		pcall(function()
			if t.line then
				t.line:Remove()
			end
		end)
		pcall(function()
			if t.text then
				t.text:Remove()
			end
		end)
	end
	enemyTracers = {}
end

local function refreshEnemyEspList()
	local list = {}
	local seen = {}
	local function consider(npc)
		if not npc or seen[npc] or not npc.Parent then
			return
		end
		local pn = npc.Parent.Name
		if pn == 'Enemies' or pn == 'CharacterWorld' or pn == 'RUSH_SPAWN' or pn == 'Prefab' or pn == 'Boss_Rush' then
			return
		end
		if not isWorldEnemy(npc) or not enemyAlive(npc) then
			return
		end
		seen[npc] = true
		list[#list + 1] = npc
	end
	for _, root in ipairs(workspace:GetChildren()) do
		if type(root.Name) == 'string' and root.Name:sub(1, 10) == 'Generated_' then
			local folder = root:FindFirstChild('NPCs')
			if folder then
				for _, npc in ipairs(folder:GetChildren()) do
					consider(npc)
				end
			end
		end
	end
	for _, tag in ipairs({ 'Enemy', 'Boss', 'Elite', 'MiniBoss', 'Miniboss' }) do
		local tagged = CollectionService:GetTagged(tag)
		if type(tagged) == 'table' then
			for _, inst in ipairs(tagged) do
				consider(inst)
			end
		end
	end
	enemyEspList = list
	enemyEspAt = os.clock()
	lastEnemies = #list
end

-- Same camera-space clip as PlayerTools/Tracers.iy — closed over so the main
-- chunk stays under Luau's 200-local register cap.
local updateEnemyTracers = (function()
-- Same camera-space clip as PlayerTools/Tracers.iy — bottom-of-screen + Z-flip
-- clamps pile every line into a corner on Potassium's Drawing API.
local CAM_NEAR = -0.2

local function camObjectPos(worldPos)
	local cam = workspace.CurrentCamera
	if not cam then
		return nil
	end
	return cam.CFrame:PointToObjectSpace(worldPos)
end

local function objectToScreen(objPos)
	local cam = workspace.CurrentCamera
	if not cam or not objPos then
		return Vector2.zero, false
	end
	local world = cam.CFrame:PointToWorldSpace(objPos)
	local v = cam:WorldToViewportPoint(world)
	return Vector2.new(v.X, v.Y), v.Z > 0
end

local function isInFront(objPos)
	return objPos ~= nil and objPos.Z < CAM_NEAR
end

local function clipSegmentToNear(p0, p1)
	if not p0 or not p1 then
		return nil
	end
	local f0, f1 = isInFront(p0), isInFront(p1)
	if f0 and f1 then
		return p0, p1
	end
	if f0 == f1 then
		if math.abs(p1.Z) < 1e-4 then
			return nil
		end
		local t = CAM_NEAR / p1.Z
		if t <= 0 then
			return nil
		end
		local onNear = p1 * t
		local start = onNear * 0.15
		if start.Z >= CAM_NEAR then
			start = Vector3.new(onNear.X, onNear.Y, CAM_NEAR - 0.05)
		end
		return start, onNear
	end
	local denom = p1.Z - p0.Z
	if math.abs(denom) < 1e-6 then
		return nil
	end
	local t = (CAM_NEAR - p0.Z) / denom
	local hit = p0:Lerp(p1, t)
	if f0 then
		return p0, hit
	end
	return hit, p1
end

local function tracerScreenPoints(fromWorld, toWorld)
	local cam = workspace.CurrentCamera
	if not cam then
		return nil
	end
	local p0 = camObjectPos(fromWorld)
	local p1 = camObjectPos(toWorld)
	-- Third-person: local HRP is often behind the cam — use a point in front of the lens.
	if not isInFront(p0) then
		p0 = Vector3.new(0, 0, CAM_NEAR - 0.5)
	end
	local c0, c1 = clipSegmentToNear(p0, p1)
	if not c0 or not c1 then
		return nil
	end
	local a = objectToScreen(c0)
	local b = objectToScreen(c1)
	return a, b
end

local function clampToScreenEdge(screenPos)
	local cam = workspace.CurrentCamera
	if not cam then
		return screenPos
	end
	local vp = cam.ViewportSize
	local margin = 10
	local cx, cy = vp.X * 0.5, vp.Y * 0.5
	local dx = screenPos.X - cx
	local dy = screenPos.Y - cy
	if math.abs(dx) < 0.5 and math.abs(dy) < 0.5 then
		return Vector2.new(cx, vp.Y - margin)
	end
	local scaleX = (dx >= 0) and ((vp.X - margin - cx) / dx) or ((margin - cx) / dx)
	local scaleY = (dy >= 0) and ((vp.Y - margin - cy) / dy) or ((margin - cy) / dy)
	local scale = math.min(scaleX, scaleY)
	return Vector2.new(cx + dx * scale, cy + dy * scale)
end

local function enemyHeadScreen(part)
	if not part then
		return nil
	end
	local above = part.Position + Vector3.new(0, 2.4, 0)
	local obj = camObjectPos(above)
	if not obj then
		return nil
	end
	if isInFront(obj) then
		local screen = objectToScreen(obj)
		return screen
	end
	if math.abs(obj.Z) < 1e-4 then
		return nil
	end
	local t = CAM_NEAR / obj.Z
	if t <= 0 then
		return nil
	end
	return clampToScreenEdge(objectToScreen(obj * t))
end

local function newEnemyTracer()
	local line = Drawing.new('Line')
	line.Thickness = 1.5
	line.Transparency = 0
	local text = Drawing.new('Text')
	text.Size = 14
	text.Center = true
	text.Outline = true
	pcall(function()
		text.Font = 2
	end)
	return { line = line, text = text }
end

local function updateEnemyTracers()
	if not on('DLEspEnemies') then
		if next(enemyTracers) then
			clearEnemyTracers()
		end
		return
	end
	if type(Drawing) ~= 'table' or type(Drawing.new) ~= 'function' then
		return
	end
	if os.clock() - enemyEspAt > 0.35 then
		refreshEnemyEspList()
	end
	local cam = workspace.CurrentCamera
	local myRoot = routeRoot()
	if not cam or not myRoot then
		return
	end
	local fromWorld = myRoot.Position
	local vpY = cam.ViewportSize.Y
	local seen = {}
	local labelBases = {}
	for _, npc in ipairs(enemyEspList) do
		local part = enemyRoot(npc)
		if part and part.Parent then
			seen[npc] = true
			local t = enemyTracers[npc]
			if not t then
				local ok, drawn = pcall(newEnemyTracer)
				if ok and drawn then
					t = drawn
					enemyTracers[npc] = t
				end
			end
			if t and t.line then
				local a, b = tracerScreenPoints(fromWorld, part.Position)
				local color = enemyEspColor(npc)
				local dormant = npc:GetAttribute('IsDormant') == true
				if a and b then
					t.line.From = a
					t.line.To = b
					t.line.Color = color
					t.line.Visible = true
					t.line.Transparency = dormant and 0.45 or 0
				else
					t.line.Visible = false
				end
				local head = enemyHeadScreen(part) or b
				local tag = enemyEspTag(npc)
				local _, hum = enemyRoot(npc)
				local hp = hum and tostring(math.floor(hum.Health + 0.5)) or '?'
				local label = npc.Name
				if tag then
					label = label .. ' [' .. tag .. ']'
				end
				if dormant then
					label = label .. ' · sleep'
				end
				label = label .. '  ' .. hp
				if t.text and head then
					t.text.Text = label
					t.text.Color = color
					t.text.Transparency = dormant and 0.35 or 0
					t.text.Visible = true
					labelBases[#labelBases + 1] = { text = t.text, base = head }
				elseif t.text then
					t.text.Visible = false
				end
			end
		end
	end
	-- Stack overlapping labels (same as Tracers.iy) so corner piles don't happen.
	table.sort(labelBases, function(u, v)
		local ay, by = u.base.Y, v.base.Y
		if math.abs(ay - by) > 0.5 then
			return ay < by
		end
		return u.base.X < v.base.X
	end)
	local placed = {}
	local clusterSq = 22 * 22
	for _, e in ipairs(labelBases) do
		local stack = 0
		local pos
		while true do
			pos = Vector2.new(e.base.X, e.base.Y - 16 - stack * 14)
			local hit = false
			for i = 1, #placed do
				local p = placed[i]
				local dx, dy = pos.X - p.X, pos.Y - p.Y
				if dx * dx + dy * dy < clusterSq then
					hit = true
					break
				end
			end
			if not hit or stack > 30 then
				break
			end
			stack += 1
		end
		pos = Vector2.new(pos.X, math.clamp(pos.Y, 12, vpY - 12))
		e.text.Position = pos
		placed[#placed + 1] = pos
	end
	for npc, t in pairs(enemyTracers) do
		if not seen[npc] then
			pcall(function()
				t.line:Remove()
			end)
			pcall(function()
				t.text:Remove()
			end)
			enemyTracers[npc] = nil
		end
	end
end
return updateEnemyTracers
end)()


local function parryRange()
	return Options.DLParryRange and tonumber(Options.DLParryRange.Value) or 40
end

local function myRootPart()
	local char = character()
	return char and (char:FindFirstChild('HumanoidRootPart') or char.PrimaryPart)
end

local function parryRangeFor(npc)
	local range = parryRange()
	if isBossEnemy(npc) then
		range = math.max(range, 52)
		local ok, size = pcall(function()
			return npc:GetExtentsSize()
		end)
		if ok and typeof(size) == 'Vector3' then
			range = math.max(range, math.max(size.X, size.Z) * 0.5 + 18)
		end
	end
	return range
end

local function enemyInRange(npc)
	if not isWorldEnemy(npc) then
		return false
	end
	local bossy = isBossEnemy(npc)
	if npc:GetAttribute('IsDormant') == true and not bossy then
		return false
	end
	-- Do not require a Humanoid here: bosses do not have one, and demanding it made
	-- every boss permanently "out of range" so parry never armed for them.
	local root = enemyRoot(npc)
	if not root or not enemyAlive(npc) then
		return false
	end
	local myRoot = myRootPart()
	if not myRoot then
		return false
	end
	-- Horizontal only: auto-low / under-ice farm used to push 3D distance over
	-- the limit and unwatch the pack, so parry never armed.
	local dx = root.Position.X - myRoot.Position.X
	local dz = root.Position.Z - myRoot.Position.Z
	return math.sqrt(dx * dx + dz * dz) <= parryRangeFor(npc)
end

local function watchEnemy(npc)
	if enemyWatches[npc] or not npc or not npc.Parent then
		return
	end
	local bag = {}
	enemyWatches[npc] = bag
	local bossy = isBossEnemy(npc)
	local lastCue = 0
	local lastCanEdge = 0
	local function windDelay()
		return bossy and bossParryDelay() or 0.08
	end
	local function maybeArm(delay, kind)
		if not enemyInRange(npc) then
			return
		end
		-- Bosses (and anything else) that paint the red F over their head expose
		-- Parry_Notification.Fire as the actual parry window. Telegraph / anim /
		-- CanAttack on those mobs only ever fired too early.
		if rt.parryNotif(npc) then
			return
		end
		-- A mob we have timed is driven by its CanAttack rise alone. Its other cues
		-- only ever dragged the press off the measured time: the telegraph fade in
		-- particular trails the hit, so it spent F right as the cooldown returned
		-- and left the cooldown covering the next swing's press. One wasted press
		-- desyncs every cycle after it.
		if rt.learnedLead(npc.Name) then
			rt.pdbg('ignore %s/%s (timed mob: CanAttack rise only)', npc.Name, tostring(kind))
			return
		end
		-- Fodder only: CanAttack is its real attack window, so telegraph flicker /
		-- State strings / leftover anim markers must not arm on their own. Bosses
		-- are exempt — their Telegraph_Root lights up well before CanAttack opens,
		-- and that lead is exactly what bossParryDelay is timing against.
		if not bossy
			and npc:GetAttribute('CanAttack') ~= nil
			and npc:GetAttribute('CanAttack') ~= true
			and os.clock() - lastCanEdge > 0.5
		then
			return
		end
		if bossy then
			if kind == 'hit' then
				armParry(0, 'boss-hit', npc.Name .. '/' .. tostring(kind))
			else
				armParry(delay ~= nil and delay or windDelay(), 'boss-wind', npc.Name .. '/' .. tostring(kind))
			end
			return
		end
		local now = os.clock()
		if now - lastCue < 0.4 then
			return
		end
		if kind ~= 'tel' then
			local root = enemyRoot(npc)
			local me = myRootPart()
			if root and me then
				local dx = root.Position.X - me.Position.X
				local dz = root.Position.Z - me.Position.Z
				if math.sqrt(dx * dx + dz * dz) > 22 then
					return
				end
			end
		end
		lastCue = now
		armParry(delay ~= nil and delay or 0.08, nil, npc.Name .. '/' .. tostring(kind))
	end

	-- Telegraph_Root is the game's own wind-up cue. Boss parts are often parented
	-- in already lit (no rising edge), then hide when the hit lands.
	local function hookTelegraphPart(part, bornLit)
		local lastT = part.Transparency
		if bornLit and lastT < 0.95 then
			maybeArm(windDelay(), 'tel')
		end
		bag[#bag + 1] = part:GetPropertyChangedSignal('Transparency'):Connect(function()
			local t = part.Transparency
			local was = lastT
			lastT = t
			if was >= 0.95 and t < 0.95 then
				maybeArm(windDelay(), 'tel')
			elseif bossy and was < 0.85 and t >= 0.85 then
				maybeArm(0.02, 'hit')
			end
		end)
	end
	local function hookTelegraphNode(d, bornLit)
		if d:IsA('BasePart') then
			hookTelegraphPart(d, bornLit)
			return
		end
		if not (
			d:IsA('Beam')
			or d:IsA('ParticleEmitter')
			or d:IsA('Trail')
			or d:IsA('BillboardGui')
			or d:IsA('Highlight')
		) then
			return
		end
		local function isOn()
			local ok, en = pcall(function()
				return d.Enabled
			end)
			return ok and en == true
		end
		if bornLit and isOn() then
			maybeArm(windDelay(), 'tel')
		end
		local okSig, sig = pcall(function()
			return d:GetPropertyChangedSignal('Enabled')
		end)
		if okSig and sig then
			bag[#bag + 1] = sig:Connect(function()
				if isOn() then
					maybeArm(windDelay(), 'tel')
				elseif bossy then
					maybeArm(0.02, 'hit')
				end
			end)
		end
	end
	local function hookTelegraphRoot(root, bornLit)
		if not root then
			return
		end
		hookTelegraphNode(root, bornLit)
		for _, d in ipairs(root:GetDescendants()) do
			hookTelegraphNode(d, bornLit)
		end
		bag[#bag + 1] = root.DescendantAdded:Connect(function(d)
			hookTelegraphNode(d, true)
		end)
	end
	hookTelegraphRoot(npc:FindFirstChild('Telegraph_Root', true), false)
	local lastDashAt = 0
	bag[#bag + 1] = npc:GetAttributeChangedSignal('DashIFrameUntil'):Connect(function()
		lastDashAt = os.clock()
		-- Dash is not an attack. If we were waiting to 2nd-parry after F hid,
		-- the follow-up is a relocate instead — skip it. A new F after they
		-- stop is the next swing.
		if not rt.fCueLit(npc) then
			rt.fFollowParryAt = 0
			rt.fAwaitFollow = 0
			rt.fNoFollow = true
		end
	end)
	-- The red F over a boss is Parry_Notification.Fire: hit lands ~0.50s after it
	-- lights. Pressing on that flag is what the game is asking for.
	local function hookParryNotif(part)
		if not part or part:GetAttribute('Fire') == nil then
			return
		end
		local lastFire = part:GetAttribute('Fire')
		local function onFire(v)
			if v == true then
				if not enemyInRange(npc) then
					return
				end
				rt.fOnAt = os.clock()
				-- Only skip F that lights with the dash itself. After a relocate
				-- the next F is a real swing (often 1s later, F before CanAttack).
				if os.clock() - lastDashAt < 0.12 and not rt.recentCanAttack(npc, 0.6) then
					rt.pdbg('skip F — %s dashed', npc.Name)
					rt.fSkipFollow = true
					return
				end
				rt.fSkipFollow = false
				rt.fAwaitFollow = 0
				rt.fLongUntil = 0
				rt.fNoFollow = false
				if npc:GetAttribute('Unblockable') == true then
					rt.dodgeOnlyUntil = math.max(rt.dodgeOnlyUntil or 0, os.clock() + 0.9)
					return
				end
				-- Do not press yet. 60s probe: every F+0.07 press was early;
				-- the swing clip starts ~F+0.35 (short 0.28s / long 2.28s).
				-- Fallback if Animator misses the clip.
				local now = os.clock()
				rt.fFollowParryAt = now + 0.50
				rt.fFollowParryUntil = now + 0.85
			elseif lastFire == true then
				-- Do not press on a blind timer: that was the too-early 2nd.
				-- Short combo plays the follow-up clip ~0.36s after F hides;
				-- a dash/walk instead means they moved — wait for the next F.
				if rt.fSkipFollow then
					rt.fSkipFollow = false
					return
				end
				local now = os.clock()
				rt.fLetterHeld = now - (rt.fOnAt or now)
				if now - (rt.fParriedAt or 0) < 6.5 then
					rt.fAwaitFollow = now
					rt.fFollowParryAt = 0
				end
			end
		end
		if lastFire == true then
			onFire(true)
		end
		bag[#bag + 1] = part:GetAttributeChangedSignal('Fire'):Connect(function()
			local v = part:GetAttribute('Fire')
			if v ~= lastFire then
				onFire(v)
			end
			lastFire = v
		end)
	end
	hookParryNotif(npc:FindFirstChild('Parry_Notification', true))
	bag[#bag + 1] = npc.DescendantAdded:Connect(function(d)
		if d.Name == 'Telegraph_Root' then
			hookTelegraphRoot(d, true)
		elseif d.Name == 'Parry_Notification' then
			hookParryNotif(d)
		end
	end)
	local function onAttackAnim(track)
		if rt.parryNotif(npc) then
			rt.noteFCueAnim(npc, track)
			return
		end
		local isAttack, guessed = isAttackAnim(track, bossy)
		if not isAttack then
			return
		end
		-- A guess is just "non-looped clip of plausible length" — these mobs play
		-- plenty of those with no attack behind them, and that is what fired F at
		-- nothing. Only trust a guess while the mob is in its attack window.
		if guessed and npc:GetAttribute('CanAttack') ~= true then
			return
		end
		if bossy and track.GetMarkerReachedSignal then
			for _, marker in ipairs({ 'Hit', 'hit', 'Impact', 'Swing', 'Damage' }) do
				local ok, sig = pcall(function()
					return track:GetMarkerReachedSignal(marker)
				end)
				if ok and sig then
					bag[#bag + 1] = sig:Connect(function()
						maybeArm(0.02, 'hit')
					end)
				end
			end
		end
		local tpos, len = 0, 0
		pcall(function()
			tpos = track.TimePosition or 0
			len = track.Length or 0
		end)
		if bossy and len > 0.28 then
			local wait, nowHit = rt.bossAnimHitWait(len, tpos)
			if nowHit then
				maybeArm(0.02, 'hit')
			else
				maybeArm(wait, 'anim')
			end
			return
		end
		if tpos > 0.18 then
			return
		end
		maybeArm(windDelay(), 'anim')
	end
	local function hookHum(hum)
		bag[#bag + 1] = hum.AnimationPlayed:Connect(onAttackAnim)
		local animator = hum:FindFirstChildOfClass('Animator')
		if animator then
			bag[#bag + 1] = animator.AnimationPlayed:Connect(onAttackAnim)
		end
	end
	local function hookAnimCtrl(ctrl)
		bag[#bag + 1] = ctrl.AnimationPlayed:Connect(onAttackAnim)
		local animator = ctrl:FindFirstChildOfClass('Animator')
		if animator then
			bag[#bag + 1] = animator.AnimationPlayed:Connect(onAttackAnim)
		end
		bag[#bag + 1] = ctrl.DescendantAdded:Connect(function(d)
			if d:IsA('Animator') then
				bag[#bag + 1] = d.AnimationPlayed:Connect(onAttackAnim)
			end
		end)
	end
	local hum = enemyHumanoid(npc)
	if hum then
		hookHum(hum)
	end
	local animCtrl = npc:FindFirstChildOfClass('AnimationController') or npc:FindFirstChildWhichIsA('AnimationController', true)
	if animCtrl then
		hookAnimCtrl(animCtrl)
	end
	bag[#bag + 1] = npc.ChildAdded:Connect(function(ch)
		if ch:IsA('Humanoid') then
			hookHum(ch)
		elseif ch:IsA('AnimationController') then
			hookAnimCtrl(ch)
		end
	end)
	bag[#bag + 1] = npc:GetAttributeChangedSignal('State'):Connect(function()
		local st = string.lower(tostring(npc:GetAttribute('State') or ''))
		if st:find('attack', 1, true)
			or st:find('wind', 1, true)
			or st:find('cast', 1, true)
			or st:find('slash', 1, true)
			or st:find('swing', 1, true)
			or st:find('slam', 1, true)
			or st:find('lunge', 1, true)
			or st:find('telegraph', 1, true)
			or st:find('skill', 1, true)
		then
			maybeArm(bossy and bossParryDelay() or 0.08, 'state')
		end
	end)
	-- CanAttack is the only attack cue these mobs actually expose: fodder carries no
	-- Telegraph_Root, State sits on 'Aggro' straight through the swing, and every
	-- clip is named 'Animation' / 'Animation1'. Live probe: rising edge = wind-up
	-- start, falling edge lands within ~0.35s of the damage. This hook used to be
	-- boss-only, so every fodder swing was invisible and parry never armed for it.
	do
		local lastCan = npc:GetAttribute('CanAttack')
		local lastCanArm = 0
		bag[#bag + 1] = npc:GetAttributeChangedSignal('CanAttack'):Connect(function()
			local v = npc:GetAttribute('CanAttack')
			local prev = lastCan
			lastCan = v
			if not enemyInRange(npc) then
				return
			end
			local now = os.clock()
			lastCanEdge = now
			-- Fodder at max parry range cannot reach us; only bosses get the full
			-- ring. 26 studs covers the archers (they fire from ~11-18).
			if not bossy then
				local root = enemyRoot(npc)
				local me = myRootPart()
				if root and me then
					local dx = root.Position.X - me.Position.X
					local dz = root.Position.Z - me.Position.Z
					if math.sqrt(dx * dx + dz * dz) > 26 then
						return
					end
				end
			end
			if npc:GetAttribute('Unblockable') == true then
				-- Unblockable swings cannot be parried; leave the window to the dash.
				rt.dodgeOnlyUntil = math.max(rt.dodgeOnlyUntil or 0, now + 0.9)
			end
			-- Same red F can cover a second swing after the parry cooldown refunds.
			-- Only arm off a fresh CanAttack pulse while F is still up — re-arming
			-- the instant CD came back was the extra tap after a good parry.
			if rt.parryNotif(npc) then
				if v == true and prev ~= true then
					rt.noteCanRise(npc)
				end
				return
			end
			if v == true and prev ~= true then
				if now - lastCanArm < 0.25 then
					return
				end
				lastCanArm = now
				rt.noteCanRise(npc)
				local lead = rt.learnedLead(npc.Name)
				if lead then
					-- Timed off this mob's own measured hit lag.
					armParry(lead, bossy and 'boss-wind' or nil, npc.Name .. '/can-rise', true)
				elseif bossy then
					armParry(windDelay(), 'boss-wind', npc.Name .. '/can-rise')
				else
					-- No samples yet: fodder wind-ups run ~0.06-0.5s, so fire almost at
					-- once and let the hold cover the impact.
					armParry(0.04, nil, npc.Name .. '/can-rise')
				end
			elseif v == false and prev == true then
				-- Falling edge is the impact. Retime onto it if we have not fired.
				if bossy then
					armParry(0, 'boss-hit', npc.Name .. '/can-fall')
				else
					armParry(0, nil, npc.Name .. '/can-fall')
				end
			end
		end)
	end
	-- HighlightState often stays lit after the swing. Do not arm from it.
	-- First attach often happens mid-windup (farm cache / late watch). Rising-edge
	-- hooks already missed that cue, so read playing attack anims once. Do not
	-- arm from a leftover State string — that sticks after the swing.
	if hum then
		pcall(function()
			for _, track in ipairs(hum:GetPlayingAnimationTracks()) do
				onAttackAnim(track)
			end
		end)
	end
	if animCtrl then
		pcall(function()
			local animator = animCtrl:FindFirstChildOfClass('Animator') or animCtrl
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				onAttackAnim(track)
			end
		end)
	end
	npc.Destroying:Once(function()
		unwatchEnemy(npc)
	end)
end

local function rebuildEnemyCache()
	enemyCache = {}
	local seen = {}
	-- A Humanoid is not the test for "is this an enemy" — bosses have none. Accept
	-- anything with a body part that either has a Humanoid, drives an
	-- AnimationController, or carries the enemy stat attributes.
	local function looksLikeEnemy(inst)
		if inst:FindFirstChildOfClass('Humanoid') then
			return true
		end
		if inst:FindFirstChildOfClass('AnimationController') then
			return true
		end
		if inst:FindFirstChild('HumanoidRootPart') then
			return true
		end
		return inst:GetAttribute('IsBoss') ~= nil
			or inst:GetAttribute('HealthOverride') ~= nil
			or inst:GetAttribute('IsFodder') ~= nil
	end
	local function consider(inst)
		if seen[inst] or not isWorldEnemy(inst) then
			return
		end
		local p = inst.Parent
		local pn = p and p.Name or ''
		if pn == 'Enemies' or pn == 'CharacterWorld' or pn == 'RUSH_SPAWN' or pn == 'Prefab' or pn == 'Boss_Rush' then
			return
		end
		if not inst:IsA('Model') or not looksLikeEnemy(inst) or not enemyRoot(inst) then
			return
		end
		seen[inst] = true
		enemyCache[#enemyCache + 1] = inst
	end
	for _, tag in ipairs({ 'Enemy', 'Boss', 'Elite', 'MiniBoss', 'Miniboss' }) do
		local tagged = CollectionService:GetTagged(tag)
		if type(tagged) == 'table' then
			for _, inst in ipairs(tagged) do
				consider(inst)
			end
		end
	end
	for _, root in ipairs(workspace:GetChildren()) do
		if root.Name:sub(1, 10) == 'Generated_' then
			local folder = root:FindFirstChild('NPCs')
			if folder then
				for _, npc in ipairs(folder:GetChildren()) do
					consider(npc)
				end
			end
			-- Do NOT GetDescendants the Generated_ map — that walk is 100ms+ and
			-- ran every enemy-cache rebuild (~0.4s). Tags + NPCs folder cover combat.
		end
	end
	local raidNpcs = workspace:FindFirstChild('Raid_NPCs')
	if raidNpcs then
		for _, npc in ipairs(raidNpcs:GetChildren()) do
			consider(npc)
		end
	end
	local rush = workspace:FindFirstChild('BossRush_NPCs')
	if rush then
		for _, npc in ipairs(rush:GetChildren()) do
			consider(npc)
		end
	end
	enemyCacheAt = os.clock()
end

local function eachEnemy(fn)
	local gap = farmBusy and 0.35 or 0.55
	if os.clock() - enemyCacheAt > gap then
		rebuildEnemyCache()
	end
	for _, npc in ipairs(enemyCache) do
		if npc and npc.Parent then
			fn(npc)
		end
	end
end

local function scanParryThreats()
	local myRoot = myRootPart()
	if not myRoot then
		return
	end
	local range = math.max(parryRange(), 52)
	eachEnemy(function(npc)
		if not npc or not npc.Parent then
			return
		end
		if not enemyInRange(npc) then
			unwatchEnemy(npc)
			return
		end
		watchEnemy(npc)
	end)
	-- New projectile only. SpellTelegraphs are floor discs (dodge) — never parry them.
	-- Old code mistook cylinder telegraphs (tall Y) for melee cues and burned F constantly.
	rt.parryTelSeen = rt.parryTelSeen or {}
	local function considerNew(inst, delay)
		if not inst or rt.parryTelSeen[inst] then
			return
		end
		local part = getPart(inst)
		if not part then
			return
		end
		if part.Transparency and part.Transparency >= 0.95 then
			return
		end
		local nm = string.lower(part.Name .. ' ' .. (part.Parent and part.Parent.Name or ''))
		if nm:find('spelltelegraph', 1, true)
			or nm:find('telegraph', 1, true)
			or nm:find('circle', 1, true)
			or nm:find('airstrike', 1, true)
			or nm:find('aoe', 1, true)
			or nm:find('ring', 1, true)
		then
			return
		end
		local sz = part.Size
		local thick = math.min(sz.X, sz.Y, sz.Z)
		local span = math.max(sz.X, sz.Y, sz.Z)
		local flat = thick < 8 and span >= 5
		local colOk, col = pcall(function()
			return part.Color
		end)
		local hot = colOk and col and (
			(col.R > 0.55 and col.G < 0.42 and col.B < 0.42)
			or (col.R > 0.7 and col.G > 0.45 and col.B < 0.35)
		)
		if flat and hot then
			return
		end
		-- Only clear melee / projectile cues: slash volumes, bolts, etc.
		local meleeish = nm:find('slash', 1, true)
			or nm:find('swing', 1, true)
			or nm:find('blade', 1, true)
			or nm:find('projectile', 1, true)
			or nm:find('bolt', 1, true)
			or nm:find('orb', 1, true)
			or nm:find('missile', 1, true)
			or nm:find('beam', 1, true)
		if not meleeish and not (part.Parent and part.Parent.Name == 'ActiveProjectiles') then
			return
		end
		local dx = part.Position.X - myRoot.Position.X
		local dz = part.Position.Z - myRoot.Position.Z
		if math.sqrt(dx * dx + dz * dz) > range then
			return
		end
		rt.parryTelSeen[inst] = true
		local bossNear = false
		local fCueNear = false
		for npc in pairs(enemyWatches) do
			if enemyInRange(npc) and rt.parryNotif(npc) then
				fCueNear = true
				break
			end
			if isBossEnemy(npc) and enemyInRange(npc) then
				bossNear = true
			end
		end
		if fCueNear then
			return
		end
		if bossNear then
			armParry(bossParryDelay(), 'boss-wind', 'projectile:' .. part.Name)
		else
			armParry(delay, nil, 'projectile:' .. part.Name)
		end
	end
	local function sweepFolder(folder, delay)
		if not folder then
			return
		end
		for _, child in ipairs(folder:GetChildren()) do
			considerNew(child, delay)
		end
	end
	-- Do NOT sweep SpellTelegraphs — those are dodge discs.
	sweepFolder(workspace:FindFirstChild('ActiveProjectiles'), 0.08)
	for _, root in ipairs(workspace:GetChildren()) do
		if root.Name:sub(1, 10) == 'Generated_' then
			sweepFolder(root:FindFirstChild('ActiveProjectiles'), 0.08)
		end
	end
	local n = 0
	for inst in pairs(rt.parryTelSeen) do
		n += 1
		if not inst.Parent then
			rt.parryTelSeen[inst] = nil
		end
		if n > 80 then
			break
		end
	end
end

local function autoParryTick()
	local wantParry = on('DLAutoParry')
	local wantDodge = on('DLAutoDodge')
	-- Farm still has to step out of floor discs when both combat toggles are off.
	if not wantParry and not wantDodge then
		if next(enemyWatches) then
			clearEnemyWatches()
		end
		rt.parryArmed = 0
		rt.parryDelay = 0
		if farmBusy then
			pcall(rt.avoidFloorAoe)
			-- holdOnEnemy already returns aoeGoal — do not Pin.at here (rebinds + thrash).
		end
		return
	end
	local now = os.clock()
	-- Full threat scan is the heavy part (watch hooks + folder walks). Idle at
	-- ~6Hz; stay hot while a swing is already queued.
	local hot = now < rt.parryArmed or now < rt.parryDelay
	if hot or now - rt.parryScan >= (farmBusy and 0.08 or 0.12) then
		rt.parryScan = now
		pcall(scanParryThreats)
	end
	-- Airstrike discs (Dark Professor). Walk into a gap — do not Q-dash.
	local aoeOk, aoeHit = pcall(rt.avoidFloorAoe)
	if (wantDodge or farmBusy) and aoeOk and aoeHit then
		if not farmBusy and typeof(rt.aoeGoal) == 'Vector3' then
			Pin.at(rt.aoeGoal, true)
		end
		return
	end
	-- Boss clips often start before we hook AnimationPlayed. Poll remaining
	-- time so the parry sits just before impact instead of at wind-up start.
	if wantParry then
		rt.bossAnim = rt.bossAnim or {}
		for npc in pairs(enemyWatches) do
			if npc.Parent and isBossEnemy(npc) and enemyInRange(npc) then
				rt.bossNearAt = now
			end
			-- One press per red-F appearance. Re-arming while Fire stayed true
			-- spent the refunded cooldown on a second tap and left the follow-up
			-- swing uncovered.
			-- Timed / F-cue mobs are not armed from leftover anim or telegraph poll.
			if npc.Parent and isBossEnemy(npc) and enemyInRange(npc)
				and not rt.parryNotif(npc)
				and not rt.learnedLead(npc.Name)
			then
				local an = rt.bossAnim[npc]
				if not an or an.Parent == nil then
					local ctrl = npc:FindFirstChildOfClass('AnimationController')
					an = (ctrl and ctrl:FindFirstChildOfClass('Animator'))
						or npc:FindFirstChildOfClass('Animator')
					rt.bossAnim[npc] = an
				end
				if an then
					pcall(function()
						for _, track in ipairs(an:GetPlayingAnimationTracks()) do
							local isAttack, guessed = isAttackAnim(track, true)
							if isAttack then
								-- Prefer CanAttack-gated timing when the boss exposes it.
								-- An unnamed clip is only a guess, so it needs CanAttack
								-- true; a name-matched clip may arm on its own.
								local can = npc:GetAttribute('CanAttack')
								if can == false or (guessed and can ~= true) then
									-- Not in an attack window — skip anim noise.
								else
									local len = track.Length or 0
									local tpos = track.TimePosition or 0
									if len > 0.28 then
										local wait, nowHit = rt.bossAnimHitWait(len, tpos)
										if nowHit then
											armParry(0, 'boss-hit', npc.Name .. '/poll-anim ' .. tostring(track.Name))
										elseif wait < 2.2 then
											armParry(wait, 'boss-wind', npc.Name .. '/poll-anim ' .. tostring(track.Name))
										end
									end
								end
							end
						end
					end)
				end
				-- Rising edge only — continuous lit telegraphs were false-parrying.
				-- No CanAttack requirement here: a boss telegraph precedes its attack
				-- window, so gating on it left bosses unparried entirely.
				if rt.telegraphRose(npc) then
					local delay = (npc:GetAttribute('IsSpecialBoss') == true) and 0.16 or bossParryDelay()
					armParry(delay, 'boss-wind', npc.Name .. '/poll-tel')
				end
			end
		end
	end
	local function spendWindow()
		rt.parryDelay = now + 0.05
		rt.parryArmed = now + 0.05
		rt.parryLock = 0
		rt.learnedUntil = 0
		rt.fCueUntil = 0
		rt.parryScan = now
		pcall(scanParryThreats)
	end
	local function panicDodge()
		-- Bleeding in a pack: spend the dash for an i-frame even without a telegraph.
		-- Never steal a ready parry — that covers the actual swing better.
		if not wantDodge or not rt.dodgeReady() then
			return false
		end
		if wantParry and parryReady() and now >= (rt.dodgeOnlyUntil or 0) then
			return false
		end
		local pct = rt.hpPct()
		if not rt.updateHealWait(pct) then
			return false
		end
		local near = false
		eachEnemy(function(npc)
			if not near and enemyInRange(npc) then
				near = true
			end
		end)
		if not near then
			return false
		end
		rt.dodgeFire = now
		pcall(rt.fireDodge)
		spendWindow()
		return true
	end
	local followP = rt.fFollowParryAt or 0
	local followUntil = rt.fFollowParryUntil or 0
	if followP > 0 and now >= followP and now < followUntil then
		if wantParry and parryReady() then
			rt.pdbg('FIRE cue=F2')
			rt.parryFire = now
			rt.fParriedAt = now
			rt.fFollowDodgeAt = 0
			if now < (rt.fLongUntil or 0) then
				rt.fFollowParryAt = now + 0.72
			else
				rt.fFollowParryAt = 0
				rt.fFollowParryUntil = 0
			end
			pcall(parryRemote)
			spendWindow()
			return
		end
		if wantDodge and (rt.fLongUntil or 0) <= now and now >= followUntil - 0.12 and rt.dodgeReady(true) then
			rt.dodgeFire = now
			rt.fFollowParryAt = 0
			rt.fFollowDodgeAt = 0
			pcall(rt.fireDodge)
			return
		end
	end
	local followAt = rt.fFollowDodgeAt or 0
	if wantDodge and followAt > 0 and now >= followAt and now < followAt + 0.8 then
		if rt.dodgeReady(true) then
			rt.dodgeFire = now
			rt.fFollowDodgeAt = 0
			pcall(rt.fireDodge)
			return
		end
	end
	if now < rt.parryDelay then
		return
	end
	if now >= rt.parryArmed then
		panicDodge()
		return
	end
	local char = character()
	-- An Unblockable swing ignores parry entirely, so hand that window to the dash.
	-- SkillIFrame is auto-skill immunity and sits up for half the fight; it used
	-- to eat a ready F the moment cooldown refunded. Real i-frames / an active
	-- parry window still skip.
	if char and (
		char:GetAttribute('Parry') == true
		or char:GetAttribute('iFrame') == true
		or char:GetAttribute('HitIFrame') == true
		or LocalPlayer:GetAttribute('iFrame') == true
	) then
		local cap = (rt.parryDelay or now) + 0.45
		if rt.parryCue ~= 'F' and now < cap then
			rt.parryArmed = math.max(rt.parryArmed, math.min(now + 0.1, cap))
		end
		return
	end
	if wantParry and parryReady() and now >= (rt.dodgeOnlyUntil or 0) then
		rt.pdbg('FIRE cue=%s cueAge=%.2fs armLeft=%.2fs', tostring(rt.parryCue), now - (rt.parryDelay or now), (rt.parryArmed or now) - now)
		rt.parryFire = now
		if rt.parryCue == 'F' then
			rt.fParriedAt = now
		end
		pcall(parryRemote)
		spendWindow()
		return
	end
	if wantDodge and rt.dodgeReady() then
		rt.dodgeFire = now
		pcall(rt.fireDodge)
		spendWindow()
		return
	end
	if panicDodge() then
		return
	end
	-- Do not stretch the window until parry CD is up — that fired F after the
	-- swing already landed. Dodge covers the hit if parry is still cooling.
end

local function skillIsReady(n)
	if not on('DLSkill' .. n) then
		return false
	end
	local prefix = 'Skill' .. n
	local charges = tonumber(LocalPlayer:GetAttribute(prefix .. '_Charges'))
	local maxC = tonumber(LocalPlayer:GetAttribute(prefix .. '_MaxCharges'))
	if type(maxC) == 'number' and maxC > 1 then
		return (type(charges) == 'number' and charges or 0) >= 1
	end
	if LocalPlayer:GetAttribute(prefix .. '_OnCooldown') == true then
		local rem = tonumber(LocalPlayer:GetAttribute(prefix .. '_CooldownRemaining')) or 0
		local ends = tonumber(LocalPlayer:GetAttribute(prefix .. '_CooldownEnd'))
		if type(ends) == 'number' then
			rem = math.max(0, ends - os.clock())
		end
		return rem <= 0.08
	end
	return true
end

local function anyEnemyInRange()
	local found = false
	eachEnemy(function(npc)
		if not found and enemyInRange(npc) then
			found = true
		end
	end)
	return found
end

local function fireSkill(slot)
	local rem = combatRemote('Skill')
	if not rem then
		return false
	end
	-- New weapons (Awakened Devil EX, etc.) want press/release. Skill2 is a hold.
	-- Old weapons ignore the boolean. Do not yield here — this runs on Heartbeat.
	local hold = false
	if type(slot) == 'number' then
		hold = LocalPlayer:GetAttribute('Skill' .. slot .. '_HasHold') == true
	elseif type(slot) == 'string' then
		hold = LocalPlayer:GetAttribute('Skill' .. slot .. '_HasHold') == true
	end
	-- Bare FireServer(slot) is what 1–4 actually consume. Extra true/false used
	-- to cancel the same cast 60ms later (release) on press/hold weapons.
	pcall(function()
		rem:FireServer(slot)
	end)
	if hold then
		pcall(function()
			rem:FireServer(slot, true)
		end)
		task.delay(0.45, function()
			pcall(function()
				rem:FireServer(slot, false)
			end)
		end)
	end
	return true
end

local function autoSkillTick()
	local wantUlt = on('DLAutoSkill') or on('DLAutoFarm')
	if not wantUlt then
		return
	end
	if LocalPlayer:GetAttribute('InNoCombatZone') == true then
		return
	end
	if LocalPlayer:GetAttribute('InDungeon') ~= true and LocalPlayer:GetAttribute('DungeonRun') ~= true then
		return
	end
	-- Do not gate on char Parry attr — it can stick true mid-farm and starve skills
	-- for the whole boss. Server still rejects casts during a real parry window.
	local char = character()
	local hum = char and char:FindFirstChildOfClass('Humanoid')
	if not hum or hum.Health <= 0 then
		return
	end
	if rt.refillBusy or rt.refillUrgent then
		return
	end
	-- Wait out the current skill's iframe so the next FireServer is not ignored.
	-- Cap it: SkillIFrame has stuck true before and would starve Auto skill.
	if char:GetAttribute('SkillIFrame') == true and os.clock() - lastSkillFire < 0.85 then
		return
	end
	-- Ultimate first. Skill 1–4 used to set lastSkillFire every tick and starve G.
	-- Farm-on also dumps G so it still pops if Auto skill was left off.
	if wantUlt and type(rt.tryFarmUlt) == 'function' then
		pcall(rt.tryFarmUlt)
	end
	if not on('DLAutoSkill') then
		return
	end
	if os.clock() - lastSkillFire < 0.16 then
		return
	end
	if routeBusy then
		return
	end
	-- Only while standing on a live target. farmBusy stays true during chest
	-- sweeps / room hops, so that flag is not "on a mob".
	if not rt.farmFighting and not anyEnemyInRange() then
		return
	end
	-- One skill per tick. Dumping 1–4 on the same Heartbeat made the server
	-- eat the rest; skipping fodder (rank < 3) left Auto skill idle all dungeon.
	for i = 0, 3 do
		local slot = ((nextSkillSlot + i - 1) % 4) + 1
		if skillIsReady(slot) then
			nextSkillSlot = (slot % 4) + 1
			lastSkillFire = os.clock()
			pcall(fireSkill, slot)
			return
		end
	end
end

-- Auto farm. Same shape as the PlayerTools farm: a spawned loop owns movement and
-- target choice, while attacks/parry/skills stay on their own tick. Nothing here
-- deals damage directly — it fires Inputs.Attack, the same remote your mouse does,
-- so the server still resolves the hitbox from where the character actually stands.
local FARM_KILL_TIMEOUT = 45
local FARM_BOSS_TIMEOUT = 240
local FARM_STALL_TIMEOUT = 18
local FARM_FINISHED_COOLDOWN = 3

local function fireAttack()
	local rem = combatRemote('Attack')
	if not rem then
		return false
	end
	rem:FireServer()
	return true
end

local function attackDelay()
	local slider = Options.DLFarmDelay and tonumber(Options.DLFarmDelay.Value)
	if slider and slider > 0 then
		return slider
	end
	-- Stat_AttackSpeed is swings per second, so its reciprocal is the real cadence.
	local speed = tonumber(LocalPlayer:GetAttribute('Stat_AttackSpeed')) or 0
	if speed <= 0 then
		return 0.35
	end
	return math.max(0.14, 1 / speed)
end

-- Live Boss Rush fights sit in workspace.BossRush_NPCs, not Generated_*/NPCs.
-- Farm used to ignore that folder, so auto farm never pinned on those bosses.
local function bossRushNpcFolder()
	return workspace:FindFirstChild('BossRush_NPCs')
end

local function inBossRushFarm()
	-- Folder leftovers (corpses, spawners) used to keep this true after leaving
	-- rush, so Endless stood still at Next Area instead of walking rooms.
	if inEndlessFarm() then
		return false
	end
	local d = string.lower(tostring(LocalPlayer:GetAttribute('CurrentDungeon') or ''))
	if d == '' then
		return false
	end
	return d:find('bossrush', 1, true) ~= nil
		or d:find('boss_rush', 1, true) ~= nil
		or d:find('boss rush', 1, true) ~= nil
end

local function inDungeonFarm()
	if inBossRushFarm() then
		rt.farmDungeonMiss = nil
		return true
	end
	if LocalPlayer:GetAttribute('InDungeon') == true then
		rt.farmDungeonMiss = nil
		return true
	end
	-- Room hops / key unlocks can drop InDungeon for a beat. Exiting the farm
	-- loop there dumps noclip+pin and the skills start walking you on the floor.
	if farmBusy then
		rt.farmDungeonMiss = rt.farmDungeonMiss or os.clock()
		return os.clock() - rt.farmDungeonMiss < 8
	end
	return false
end

local function farmActive()
	-- A farm loop from a superseded instance must not keep driving the character.
	if not currentInstance() then
		return false
	end
	if not on('DLAutoFarm') then
		return false
	end
	if not inDungeonFarm() then
		return false
	end
	local char = character()
	local hum = char and char:FindFirstChildOfClass('Humanoid')
	return hum ~= nil and hum.Health > 0
end

-- The global 'Enemy' tag is not a safe target list: the map has props wearing it
-- (Boss_Rush.RUSH_SPAWN holds meme models tagged Enemy with a Humanoid). Scope the
-- farm to the NPCs folder of the dungeon we are actually running.
local function activeDungeonRoot()
	local want = tostring(LocalPlayer:GetAttribute('CurrentDungeon') or '')
	local fallback = nil
	for _, root in ipairs(workspace:GetChildren()) do
		if root.Name:sub(1, 10) == 'Generated_' then
			fallback = fallback or root
			if want ~= '' and root.Name:find(want, 1, true) then
				return root
			end
		end
	end
	return fallback
end

-- Rooms only wake when the server sees the character inside their Zone part, and
-- ZoneEntered is a server->client notification so it cannot be faked from here.
-- Until a room wakes, its enemies sit at IsDormant=true and take no damage — which
-- is why teleporting straight onto a sleeping pack looked like they never loaded.
-- Horde rooms are worse: no NPC exists at all until you stand in the Zone, so a
-- dormant scan skips them entirely and the old enter() treated "0 dormant" as
-- already awake and walked away before the wave spawned.
-- Every NPC and chest carries a RoomIndex, so pair them to Room_<index>.
local Rooms = (function()
	local WAKE_TIMEOUT = 5
	local SPAWN_TIMEOUT = 4
	local api = {}
	local hudHasOpenStar
	-- Rooms we have seen host at least one awake enemy this run. Empty rooms not
	-- in this set are candidates for a walk-in activation (hordes).
	local visited = {}
	local retryAt = {}
	local emptyHop = {} -- walked in, no pack — do not send Endless back here
	local armed = {}
	local repaired = {} -- one softlock pass: do not re-sweep these rooms
	local lastPushAt = 0
	local lastEnterIdx = nil
	local enterFlip = 0
	local lastArmAt = 0

	local function sessionInfo()
		local now = os.clock()
		if rt.session and now - (rt.sessionAt or 0) < 1.25 then
			return rt.session
		end
		-- Cached remote only — never ReplicatedStorage:GetDescendants (50–150ms hitch).
		local rf = rt.sessionRF
		if not rf or not rf.Parent then
			rf = nil
			pcall(function()
				rf = game:GetService('ReplicatedStorage').Packages._Index['sleitnick_knit@1.7.0']
					.knit.Services.DungeonRunService.RF.GetSessionInfo
			end)
			rt.sessionRF = rf
		end
		if not rf then
			return rt.session
		end
		local ok, res = pcall(function()
			return rf:InvokeServer()
		end)
		if ok and type(res) == 'table' then
			rt.session = res
			rt.sessionAt = now
			return res
		end
		rt.sessionAt = now
		return rt.session
	end

	local function touchPart(root, part)
		if not root or not part or not part:IsA('BasePart') then
			return
		end
		if type(firetouchinterest) == 'function' then
			pcall(firetouchinterest, root, part, 0)
			pcall(firetouchinterest, root, part, 1)
		end
	end

	function api.zone(dungeon, idx)
		local room = dungeon and dungeon:FindFirstChild('Room_' .. tostring(idx))
		local zone = room and room:FindFirstChild('Zone')
		if zone and zone:IsA('BasePart') then
			return zone
		end
		return nil
	end

	function api.indexOf(inst)
		return inst and tonumber(inst:GetAttribute('RoomIndex')) or nil
	end

	local function eachNpc(dungeon, fn)
		local npcs = dungeon and dungeon:FindFirstChild('NPCs')
		for _, npc in ipairs(npcs and npcs:GetChildren() or {}) do
			fn(npc)
		end
	end

	local function connectorPart(dungeon, idx, which)
		local room = dungeon and dungeon:FindFirstChild('Room_' .. tostring(idx))
		local connectors = room and room:FindFirstChild('Connectors')
		if not connectors then
			return nil
		end
		local part = connectors:FindFirstChild(which)
		if part and part:IsA('BasePart') then
			return part
		end
		part = connectors:FindFirstChild(which, true)
		return (part and part:IsA('BasePart')) and part or nil
	end

	-- Must be declared before armRoom/enter/pushForward — a later local is invisible
	-- to those closures and became `attempt to call a nil value` on repair.
	local function entryPoint(dungeon, idx)
		local zone = api.zone(dungeon, idx)
		if zone then
			-- Zone center at roughly standing height — standingSpot raycasts the floor.
			return zone.Position + Vector3.new(0, 4, 0)
		end
		-- Connectors.Entry/Exit sit in the hallway. Standing there is how farm
		-- kept walking corridors that are also named Room_N.
		return nil
	end

	function api.livingNpc(dungeon)
		local n = 0
		eachNpc(dungeon, function(npc)
			if isWorldEnemy(npc) and enemyAlive(npc) then
				n += 1
			end
		end)
		return n
	end

	function api.dormantCount(dungeon, idx)
		local n = 0
		eachNpc(dungeon, function(npc)
			if api.indexOf(npc) == idx and npc:GetAttribute('IsDormant') == true and enemyAlive(npc) then
				n += 1
			end
		end)
		return n
	end

	function api.aliveCount(dungeon, idx)
		local n = 0
		eachNpc(dungeon, function(npc)
			if api.npcInRoom(dungeon, npc, idx) and isWorldEnemy(npc) and enemyAlive(npc) then
				n += 1
			end
		end)
		return n
	end

	function api.markVisited(idx)
		if idx then
			visited[idx] = true
		end
	end

	function api.maxVisited()
		local m = 0
		for idx in pairs(visited) do
			if type(idx) == 'number' and idx > m then
				m = idx
			end
		end
		return m
	end

	function api.nearestIdx(dungeon, fromPos)
		if not dungeon or not fromPos then
			return nil
		end
		local bestIdx, bestD
		for _, child in ipairs(dungeon:GetChildren()) do
			local idx = tonumber(tostring(child.Name):match('^Room_(%d+)$'))
			local zone = idx and api.zone(dungeon, idx)
			if zone then
				local d = (zone.Position - fromPos).Magnitude
				if not bestD or d < bestD then
					bestIdx, bestD = idx, d
				end
			end
		end
		return bestIdx, bestD
	end

	-- Note any room that currently has awake enemies so we do not re-enter it as
	-- an "empty horde" candidate later.
	function api.noteAlive(dungeon)
		eachNpc(dungeon, function(npc)
			if isWorldEnemy(npc) and enemyAlive(npc) and npc:GetAttribute('IsDormant') ~= true then
				visited[api.indexOf(npc) or -1] = true
			end
		end)
	end

	-- Room that still holds sleeping enemies. When the map is idle, always take the
	-- lowest Room_N first — nearest-first hop between 3 mid-dungeon packs forever.
	function api.nextDormant(dungeon, fromPos)
		local now = os.clock()
		local awake = 0
		eachNpc(dungeon, function(npc)
			if isWorldEnemy(npc) and enemyAlive(npc) and npc:GetAttribute('IsDormant') ~= true then
				awake += 1
			end
		end)
		local info = sessionInfo()
		local soft = info and tonumber(info.CurrentRoom) == 0
		local forward = awake == 0 or soft
		local maxDist = (forward or farmBusy) and 2000 or 350
		local bestIdx, bestD
		eachNpc(dungeon, function(npc)
			if npc:GetAttribute('IsDormant') == true and enemyAlive(npc) then
				local idx = api.indexOf(npc)
				local pos = idx and entryPoint(dungeon, idx)
				if pos and (retryAt[idx] or 0) <= now then
					local d = (pos - fromPos).Magnitude
					if d <= maxDist then
						if forward then
							if not bestIdx or idx < bestIdx then
								bestIdx, bestD = idx, d
							end
						elseif not bestD or d < bestD then
							bestIdx, bestD = idx, d
						end
					end
				end
			end
		end)
		return bestIdx
	end

	function api.sessionCurrentRoom()
		local info = sessionInfo()
		return info and tonumber(info.CurrentRoom) or nil
	end

	function api.sessionPhase()
		local info = sessionInfo()
		return info and tostring(info.Phase or '') or ''
	end

	function api.awakeCount(dungeon)
		local n = 0
		eachNpc(dungeon, function(npc)
			-- Streamed-out shells have no body — counting them as awake made the
			-- farm sit idle in Room_27 while Room_9 "had" 9 fightable mobs.
			if isWorldEnemy(npc)
				and enemyAlive(npc)
				and npc:GetAttribute('IsDormant') ~= true
				and enemyRoot(npc)
			then
				n += 1
			end
		end)
		return n
	end

	-- Horde rooms have zero NPCs until you stand in the Zone. Only try the next
	-- sequential Room_N so we do not ping-pong every empty shell in the layout.
	function api.nextEmpty(dungeon, fromPos, gatePos)
		if not dungeon or not fromPos then
			return nil
		end
		api.noteAlive(dungeon)
		local now = os.clock()
		local gateD = gatePos and (gatePos - fromPos).Magnitude or nil
		local want = api.maxVisited() + 1
		if want < 1 then
			want = (api.nearestIdx(dungeon, fromPos) or 0) + 1
		end
		local zone = api.zone(dungeon, want)
		-- Special / horde waves start with 0 NPCs. emptyHop used to skip them
		-- forever after one short stand.
		local special = api.roomIsSpecial(dungeon, want)
		local starsHold = hudHasOpenStar() or api.specialStarOpen()
		if not zone then
			return nil
		end
		if not starsHold and (visited[want] or (emptyHop[want] and not special) or (retryAt[want] or 0) > now) then
			return nil
		end
		if api.dormantCount(dungeon, want) > 0 or api.aliveCount(dungeon, want) > 0 then
			return nil
		end
		local d = (zone.Position - fromPos).Magnitude
		-- Courtyard spawn can be 600+ studs from Room_2. A 550 cap left farm idle
		-- on empty stars (Knights yard with 3 open circles).
		local maxDist = 220
		if starsHold then
			maxDist = 4000
		elseif api.livingNpc(dungeon) == 0 then
			maxDist = 2500
		end
		if d > maxDist then
			return nil
		end
		-- Standing at Next Area made gateD tiny, so the next room looked "too far"
		-- and farm walked the gate with empty stars still on the bar.
		if not starsHold and gateD and d > gateD + 8 then
			return nil
		end
		return want
	end

	function api.park(idx, seconds)
		if not idx then
			return
		end
		rt.parkN = rt.parkN or {}
		local n = (rt.parkN[idx] or 0) + 1
		rt.parkN[idx] = n
		-- Escalate so a pack that will not wake stops the hop — keep it short.
		local wait = seconds or math.min(14, 2.5 + n * 3)
		retryAt[idx] = os.clock() + wait
	end

	function api.reset()
		visited = {}
		retryAt = {}
		emptyHop = {}
		armed = {}
		repaired = {}
		lastPushAt = 0
		lastEnterIdx = nil
		enterFlip = 0
		lastArmAt = 0
		rt.softlockAt = 0
		rt.softlockN = 0
		rt.repairIdx = nil
		rt.repairDone = nil
		rt.parkN = {}
		rt.flipAt = nil
		rt.starLock = nil
		rt.zoneLayout = nil
		rt.zoneCurrent = nil
		rt.zoneFromGc = nil
		rt.farmRoomIdx = 1
		rt.farmRoomPhase = 'wait'
		rt.farmRoomFilter = nil
		rt.farmDungeonId = nil
		rt.shrineUsed = {}
		rt.chestDone = {}
		rt.chestDoneUid = {}
		rt.roomSweepDone = {}
		rt.roomSweepDonePos = {}
	end

	function api.maxRoom(dungeon)
		local m = 0
		if not dungeon then
			return 0
		end
		for _, child in ipairs(dungeon:GetChildren()) do
			local idx = tonumber(tostring(child.Name):match('^Room_(%d+)$'))
			if idx and idx > m then
				m = idx
			end
		end
		return m
	end

	-- Skinny Zones are hallways even when tagged Checkpoint / Loot.
	function api.isCorridor(dungeon, idx)
		local room = dungeon and dungeon:FindFirstChild('Room_' .. tostring(idx))
		if not room then
			return false
		end
		local function skinny(x, z)
			local mn = math.min(x, z)
			-- Long 36xN halls used to fail mx<=80 and get toured as rooms.
			return mn > 0 and mn <= 42
		end
		local zone = room:FindFirstChild('Zone')
		if zone and zone:IsA('BasePart') and skinny(zone.Size.X, zone.Size.Z) then
			return true
		end
		-- Small Entry+Exit pads (Room_9 ~75x79) are landings, not combat rooms.
		local con = room:FindFirstChild('Connectors')
		if zone and zone:IsA('BasePart') and con
			and con:FindFirstChild('Entry') and con:FindFirstChild('Exit')
			and not con:FindFirstChild('Side')
		then
			local mn, mx = math.min(zone.Size.X, zone.Size.Z), math.max(zone.Size.X, zone.Size.Z)
			if mn <= 82 and mx <= 88 then
				if room:GetAttribute('IsLootRoom') ~= true
					and room:GetAttribute('IsSpecial') ~= true
					and room:GetAttribute('IsSpecialBoss') ~= true
					and room:GetAttribute('IsBoss') ~= true
					and room:GetAttribute('IsHorde') ~= true
				then
					return true
				end
			end
		end
		if room:GetAttribute('IsLootRoom') == true
			or room:GetAttribute('IsSpecial') == true
			or room:GetAttribute('IsSpecialBoss') == true
			or room:GetAttribute('IsBoss') == true
			or room:GetAttribute('IsHorde') == true
			or room:GetAttribute('IsEvent') == true
		then
			return false
		end
		-- Wide checkpoints are rest rooms. Skinny ones already returned true.
		if room:GetAttribute('IsCheckpoint') == true then
			return false
		end
		local ok, _, sz = pcall(function()
			return room:GetBoundingBox()
		end)
		if ok and typeof(sz) == 'Vector3' and sz.Magnitude > 1 then
			local mn, mx = math.min(sz.X, sz.Z), math.max(sz.X, sz.Z)
			if mn <= 14 and mx >= 40 then
				return true
			end
			return skinny(sz.X, sz.Z)
		end
		return false
	end

	function api.isBossRoom(dungeon, idx)
		local room = dungeon and dungeon:FindFirstChild('Room_' .. tostring(idx))
		if not room then
			return false
		end
		if room:GetAttribute('IsBoss') == true then
			return true
		end
		local spawns = room:FindFirstChild('Spawns')
		local part = spawns and (spawns:FindFirstChild('Boss_Spawn') or spawns:FindFirstChild('BossSpawn'))
		return part ~= nil
	end

	local function inZoneXZ(zone, pos)
		if not zone or typeof(pos) ~= 'Vector3' then
			return false
		end
		local lp = zone.CFrame:PointToObjectSpace(pos)
		return math.abs(lp.X) <= zone.Size.X * 0.5 + 1.5
			and math.abs(lp.Z) <= zone.Size.Z * 0.5 + 1.5
	end

	function api.posInCorridor(dungeon, pos)
		if not dungeon or typeof(pos) ~= 'Vector3' then
			return false
		end
		for _, child in ipairs(dungeon:GetChildren()) do
			local idx = tonumber(tostring(child.Name):match('^Room_(%d+)$'))
			if idx and api.isCorridor(dungeon, idx) then
				local zone = api.zone(dungeon, idx)
				if zone and inZoneXZ(zone, pos) then
					return true
				end
			end
		end
		return false
	end

	function api.posInRoom(dungeon, idx, pos)
		if not dungeon or not idx or typeof(pos) ~= 'Vector3' then
			return false
		end
		local zone = api.zone(dungeon, idx)
		return zone ~= nil and inZoneXZ(zone, pos)
	end

	-- Floor boss often has no RoomIndex. It still belongs to the Boss_Spawn room.
	function api.npcInRoom(dungeon, npc, idx)
		if not npc or not idx then
			return false
		end
		if api.indexOf(npc) == idx then
			return true
		end
		if npc:GetAttribute('IsBoss') == true
			and npc:GetAttribute('IsSpecialBoss') ~= true
			and npc:GetAttribute('IsMiniBoss') ~= true
			and npc:GetAttribute('IsLootRoomGuard') ~= true
			and api.isBossRoom(dungeon, idx)
		then
			return true
		end
		return false
	end

	-- Lowest room we have not yet touch-armed. Skipping ahead with noclip left
	-- CurrentRoom=0 on the server so the boss never spawned.
	function api.nextArm(dungeon)
		local maxR = api.maxRoom(dungeon)
		for i = 1, maxR do
			if api.zone(dungeon, i) and not armed[i] and not repaired[i] then
				return i
			end
		end
		return nil
	end

	function api.repairFinished()
		return rt.repairDone == true
	end

	-- Progress bar left an empty first star: walk each Zone room once until the
	-- server sets CurrentRoom or a pack spawns. Never restart the sweep in the
	-- same softlock — that was the multi-pass Room_1→N teleport loop.
	function api.repairSkip(dungeon)
		if not dungeon then
			return false
		end
		if rt.repairDone then
			return false
		end
		if os.clock() - lastArmAt < 1.0 then
			return false
		end
		local info = sessionInfo()
		local cur = info and tonumber(info.CurrentRoom)
		local phase = info and tostring(info.Phase or '')
		if phase == 'BossPhase' or phase == 'Boss' then
			rt.repairDone = true
			rt.repairIdx = nil
			return false
		end
		if not info or (cur and cur > 0) then
			-- Softlock cleared mid-pass.
			repaired = {}
			rt.repairIdx = nil
			rt.repairDone = nil
			return false
		end
		local maxR = api.maxRoom(dungeon)
		local start = math.max(1, tonumber(rt.repairIdx) or 1)
		for i = start, maxR do
			if api.zone(dungeon, i) and not repaired[i] then
				repaired[i] = true
				armed[i] = true
				rt.repairIdx = i
				lastArmAt = os.clock()
				local woke = api.enter(dungeon, i)
				if api.awakeCount(dungeon) > 0 then
					visited[i] = true
					rt.repairIdx = nil
					rt.repairDone = true
					return true
				end
				info = sessionInfo()
				cur = info and tonumber(info.CurrentRoom)
				if cur and cur > 0 then
					visited[cur] = true
					armed[cur] = true
					rt.repairIdx = nil
					rt.repairDone = true
					return true
				end
				if not woke then
					-- enter already waited; a second armRoom just re-teleports the same room.
					armed[i] = true
				end
				visited[i] = true
				rt.repairIdx = i + 1
				return true
			end
		end
		-- One full pass done — stop. Boss/gates can proceed without another sweep.
		rt.repairDone = true
		rt.repairIdx = nil
		return false
	end

	function api.bossSpawn(dungeon)
		if not dungeon then
			return nil
		end
		local function spawnIn(room)
			local spawns = room and room:FindFirstChild('Spawns')
			local part = spawns and (spawns:FindFirstChild('Boss_Spawn') or spawns:FindFirstChild('BossSpawn'))
			return (part and part:IsA('BasePart')) and part or nil
		end
		local maxR = api.maxRoom(dungeon)
		if maxR >= 1 then
			local part = spawnIn(dungeon:FindFirstChild('Room_' .. tostring(maxR)))
			if part then
				return part
			end
		end
		for _, child in ipairs(dungeon:GetChildren()) do
			if tostring(child.Name):match('^Room_%d+$') then
				local part = spawnIn(child)
				if part then
					return part
				end
			end
		end
		return nil
	end

	-- Stand mid-Zone and fire touch so the server arms CurrentRoom / spawns.
	function api.armRoom(dungeon, idx)
		if not dungeon or not idx then
			return false
		end
		if os.clock() - lastArmAt < 0.2 then
			return false
		end
		local root = routeRoot()
		local zone = api.zone(dungeon, idx)
		if not root or not zone then
			armed[idx] = true
			return false
		end
		lastArmAt = os.clock()
		api.noteEnter(idx)
		local goal = entryPoint(dungeon, idx)
		if not goal then
			Pin.stop()
			return false
		end
		Pin.at(standingSpot(goal, 0), true)
		if type(firetouchinterest) == 'function' then
			pcall(firetouchinterest, root, zone, 0)
			pcall(firetouchinterest, root, zone, 1)
		end
		pcall(function()
			root.AssemblyLinearVelocity = Vector3.new(5, 0, 3)
		end)
		task.wait(0.12)
		pcall(function()
			root.AssemblyLinearVelocity = Vector3.zero
		end)
		local deadline = os.clock() + 1.1
		while os.clock() < deadline do
			if not farmActive() then
				Pin.stop()
				return false
			end
			-- livingNpc counts dormants too — only awake packs / CurrentRoom mean armed.
			if api.awakeCount(dungeon) > 0 then
				armed[idx] = true
				visited[idx] = true
				enterFlip = 0
				Pin.stop()
				pcall(function()
					KeyDoor.unlockForRoom(idx)
				end)
				return true
			end
			local info = sessionInfo()
			if info and tonumber(info.CurrentRoom) == idx then
				armed[idx] = true
				visited[idx] = true
				enterFlip = 0
				Pin.stop()
				pcall(function()
					KeyDoor.unlockForRoom(idx)
				end)
				return true
			end
			task.wait(0.2)
		end
		-- Do NOT mark armed on failure — that permanently skipped Room_1 and
		-- blocked boss spawn after a softlock.
		Pin.stop()
		local info = sessionInfo()
		local ok = (info and tonumber(info.CurrentRoom) == idx) or api.awakeCount(dungeon) > 0
		if ok then
			pcall(function()
				KeyDoor.unlockForRoom(idx)
			end)
		end
		return ok
	end

	-- True when enter() has been flip-flopping two room indices (the hover).
	function api.noteEnter(idx)
		if not idx then
			return false
		end
		if lastEnterIdx and lastEnterIdx ~= idx then
			enterFlip += 1
			-- Two-room ping-pong (Snow 2↔9): lock the lower index and park the other
			-- so streaming the far room does not yank us off the pack we just woke.
			if enterFlip >= 2 then
				local keep = math.min(lastEnterIdx, idx)
				local drop = math.max(lastEnterIdx, idx)
				api.park(drop, 50)
				rt.starLock = keep
				rt.flipAt = rt.flipAt or os.clock()
			end
		elseif lastEnterIdx == idx then
			enterFlip = 0
			rt.flipAt = nil
		end
		lastEnterIdx = idx
		if enterFlip >= 3 then
			rt.flipAt = rt.flipAt or os.clock()
		end
		return enterFlip >= 3
	end

	function api.flipping()
		if enterFlip < 3 then
			return false
		end
		-- Permanent lockout made farm ignore Room_6 dormants and spam Next Area.
		if os.clock() - (rt.flipAt or 0) > 10 then
			enterFlip = 0
			rt.flipAt = nil
			return false
		end
		return true
	end

	function api.lastEnter()
		return lastEnterIdx
	end

	-- Step into the next room's Zone center (not the Entry pad in the hallway).
	function api.pushForward(dungeon, fromPos)
		if not dungeon or not fromPos then
			return false
		end
		local gap = api.livingNpc(dungeon) == 0 and 3.8 or 2.3
		if os.clock() - lastPushAt < gap then
			return false
		end
		local idx = api.nearestIdx(dungeon, fromPos) or api.maxVisited()
		if not idx or idx < 1 then
			return false
		end
		local nextIdx = idx + 1
		local goal = entryPoint(dungeon, nextIdx) or entryPoint(dungeon, idx)
		local exit = connectorPart(dungeon, idx, 'Exit')
		if not goal then
			return false
		end
		lastPushAt = os.clock()
		enterFlip = 0
		visited[idx] = true
		-- Brush the Exit pad so open-world streaming can catch up, then sit mid-room.
		if exit then
			Pin.at(standingSpot(exit.Position + Vector3.new(0, 3, 0), 0), true)
			task.wait(0.25)
		end
		Pin.at(standingSpot(goal, 0), true)
		if type(firetouchinterest) == 'function' then
			local zone = api.zone(dungeon, nextIdx) or api.zone(dungeon, idx)
			local root = routeRoot()
			if zone and root then
				pcall(firetouchinterest, root, zone, 0)
				pcall(firetouchinterest, root, zone, 1)
			end
		end
		task.wait(0.2)
		Pin.stop()
		return true
	end

	-- Hold until the pack is visible, then return immediately so farm can kill.
	function api.enter(dungeon, idx)
		local goal = entryPoint(dungeon, idx)
		local root = routeRoot()
		if not goal or not root then
			return false
		end
		api.noteEnter(idx)
		local expectingSpawn = api.dormantCount(dungeon, idx) == 0
		local special = api.roomIsSpecial(dungeon, idx)
		local zone = api.zone(dungeon, idx)
		Pin.at(standingSpot(goal, 0), true)
		-- Special / horde waves only start after ZoneEntered. Noclip skips that
		-- touch, the room stays empty, and farm hopped to the next star.
		local function pokeZone()
			local my = routeRoot()
			if not my then
				return
			end
			pcall(function()
				my.CanCollide = true
			end)
			if zone and type(firetouchinterest) == 'function' then
				pcall(firetouchinterest, my, zone, 0)
				pcall(firetouchinterest, my, zone, 1)
			end
		end
		rt.holdCollideUntil = os.clock() + (special and 9 or 6)
		pokeZone()
		local function packReady()
			local n = 0
			eachNpc(dungeon, function(npc)
				if api.indexOf(npc) ~= idx then
					return
				end
				if isWorldEnemy(npc)
					and enemyAlive(npc)
					and npc:GetAttribute('IsDormant') ~= true
					and enemyRoot(npc)
				then
					n += 1
				end
			end)
			return n > 0
		end
		local function grabbed()
			visited[idx] = true
			emptyHop[idx] = nil
			enterFlip = 0
			rt.holdCollideUntil = 0
			Pin.stop()
			enemyCacheAt = 0
			if noclipOn then
				pcall(setCharNoclip, true)
			end
			pcall(function()
				KeyDoor.unlockForRoom(idx)
			end)
			return true
		end
		if packReady() then
			return grabbed()
		end
		-- Empty connector rooms can leave fast. Special / horde waves spawn late.
		local waitFor = special and 8 or (expectingSpawn and 5.5 or 1.2)
		local deadline = os.clock() + waitFor
		local bumped = false
		local poked = 0
		while os.clock() < deadline do
			if not routeRoot() or not farmActive() then
				rt.holdCollideUntil = 0
				Pin.stop()
				return false
			end
			if packReady() then
				return grabbed()
			end
			if not expectingSpawn and api.dormantCount(dungeon, idx) == 0 and api.aliveCount(dungeon, idx) > 0 then
				return grabbed()
			end
			if os.clock() - poked > 0.35 then
				poked = os.clock()
				pokeZone()
			end
			if not bumped then
				bumped = true
				pcall(function()
					local live = routeRoot()
					if live then
						live.AssemblyLinearVelocity = Vector3.new(5, 0, 3)
					end
				end)
			end
			task.wait(0.05)
		end
		Pin.stop()
		rt.holdCollideUntil = 0
		if noclipOn then
			pcall(setCharNoclip, true)
		end
		if packReady() or api.aliveCount(dungeon, idx) > 0 then
			return grabbed()
		end
		if expectingSpawn then
			-- HUD still has empty circles — this room may be a late special/horde
			-- wave. emptyHop + Next Area is how Depth 1 skipped a star.
			local starsOpen = false
			pcall(function()
				starsOpen = (hudHasOpenStar and hudHasOpenStar())
					or (type(api.specialStarOpen) == 'function' and api.specialStarOpen())
			end)
			if not special and not starsOpen then
				emptyHop[idx] = true
			end
			return false
		end
		local woke = api.dormantCount(dungeon, idx) == 0
		if woke then
			pcall(function()
				KeyDoor.unlockForRoom(idx)
			end)
		end
		return woke
	end

	-- Stand in the Zone for `seconds`. Return true as soon as THIS room has
	-- an awake pack so farm can kill with the usual hover stand.
	function api.holdRoom(dungeon, idx, seconds)
		local goal = entryPoint(dungeon, idx)
		local root = routeRoot()
		if not goal or not root then
			return false
		end
		local zone = api.zone(dungeon, idx)
		Pin.at(standingSpot(goal, 0), true)
		local function pokeZone()
			local my = routeRoot()
			if not my then
				return
			end
			pcall(function()
				my.CanCollide = true
			end)
			if zone and type(firetouchinterest) == 'function' then
				pcall(firetouchinterest, my, zone, 0)
				pcall(firetouchinterest, my, zone, 1)
			end
		end
		rt.holdCollideUntil = os.clock() + (tonumber(seconds) or 1) + 1
		pokeZone()
		local function awakeHere()
			local n = 0
			eachNpc(dungeon, function(npc)
				if api.npcInRoom(dungeon, npc, idx)
					and isWorldEnemy(npc)
					and enemyAlive(npc)
					and npc:GetAttribute('IsDormant') ~= true
					and enemyRoot(npc)
				then
					n += 1
				end
			end)
			return n > 0
		end
		if awakeHere() then
			return true
		end
		local deadline = os.clock() + (tonumber(seconds) or 1)
		local poked = 0
		while os.clock() < deadline do
			if not farmActive() or not routeRoot() then
				rt.holdCollideUntil = 0
				return false
			end
			if awakeHere() then
				return true
			end
			if os.clock() - poked > 0.35 then
				poked = os.clock()
				pokeZone()
			end
			task.wait(0.1)
		end
		return awakeHere()
	end

	-- Completion_Progress stars: each ZoneSlot is a room Index from RoomLayoutUpdate.
	-- Empty circle (Completed not visible, not Boss) → that room still needs a clear.
	local function zoneLooksSpecial(z)
		if type(z) ~= 'table' then
			return false
		end
		if z.IsSpecial == true or z.HasSpecial == true or z.IsSpecialBoss == true
			or z.IsHorde == true or z.IsEvent == true or z.IsWave == true
		then
			return true
		end
		local t = string.lower(tostring(z.Type or z.RoomType or z.Kind or z.WaveType or ''))
		return t:find('special', 1, true)
			or t:find('horde', 1, true)
			or t:find('event', 1, true)
			or t:find('wave', 1, true)
			or false
	end

	local function copyZone(z)
		if type(z) ~= 'table' then
			return nil
		end
		return {
			Index = tonumber(z.Index),
			IsBoss = z.IsBoss == true,
			IsSpecial = zoneLooksSpecial(z),
			Completed = z.Completed == true or z.Done == true,
			HasTreasure = z.HasTreasure == true,
			Type = z.Type or z.RoomType or z.Kind,
		}
	end

	function api.ingestLayout(zones, current)
		if type(zones) ~= 'table' then
			return
		end
		local copy = {}
		for i, z in ipairs(zones) do
			copy[i] = copyZone(z)
		end
		rt.zoneLayout = copy
		rt.zoneCurrent = current
		rt.zoneAt = os.clock()
		rt.zoneFromGc = true
	end

	local function progressList()
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		local main = pg and pg:FindFirstChild('Main')
		local hud = main and main:FindFirstChild('HUD')
		if not hud then
			return nil
		end
		local function listOf(name)
			local cont = hud:FindFirstChild(name)
			local frame = cont and cont:FindFirstChild('Completion_Progress')
			return frame and frame:FindFirstChild('List'), cont
		end
		local dungeonList, dungeonCont = listOf('Dungeon_Container')
		local endlessList, endlessCont = listOf('Endless_Container')
		-- Depth / Enemies Left HUD is Endless. Reading Dungeon_Container first
		-- treated a finished bar as "no stars" and farm took Next Area early.
		if endlessCont and endlessCont:IsA('GuiObject') and endlessCont.Visible then
			return endlessList or dungeonList
		end
		return dungeonList or endlessList
	end

	local function hudSlots()
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		local main = pg and pg:FindFirstChild('Main')
		local hud = main and main:FindFirstChild('HUD')
		if not hud then
			return {}
		end
		local function collect(visibleOnly)
			local slots = {}
			for _, c in ipairs(hud:GetDescendants()) do
				if c.Name == 'ZoneSlot' then
					if visibleOnly then
						local hidden = false
						local p = c
						while p and p ~= hud do
							if p:IsA('GuiObject') and p.Visible == false then
								hidden = true
								break
							end
							p = p.Parent
						end
						if hidden then
							continue
						end
					end
					slots[#slots + 1] = c
				end
			end
			table.sort(slots, function(a, b)
				return (a.LayoutOrder or 0) < (b.LayoutOrder or 0)
			end)
			return slots
		end
		local vis = collect(true)
		if #vis > 0 then
			return vis
		end
		-- Endless Depth HUD can hide Dungeon_Container while the star row is
		-- still the one we must honor. Fall back to every ZoneSlot.
		local list = progressList()
		if list then
			local slots = {}
			for _, c in ipairs(list:GetChildren()) do
				if c.Name == 'ZoneSlot' then
					slots[#slots + 1] = c
				end
			end
			table.sort(slots, function(a, b)
				return (a.LayoutOrder or 0) < (b.LayoutOrder or 0)
			end)
			if #slots > 0 then
				return slots
			end
		end
		return collect(false)
	end

	-- HUD LayoutOrder is the star slot (1–7), not Room_N. Do not map slot 2 → Room_2.
	local function seedLayoutFromHud()
		return false
	end

	hudHasOpenStar = function()
		for _, slot in ipairs(hudSlots()) do
			local boss = slot:FindFirstChild('Boss')
			local completed = slot:FindFirstChild('Completed')
			if not (boss and boss.Visible) and not (completed and completed.Visible) then
				return true
			end
		end
		return false
	end

	-- Last star is the floor boss. nextGapRoom skips IsBoss, so Endless used to
	-- tour empty Room_1→N and sit in the last hallway instead of the boss pad.
	function api.hudHasOpenStar()
		return hudHasOpenStar()
	end

	function api.starsHold()
		return hudHasOpenStar() or api.specialStarOpen()
	end

	function api.bossStarOpen()
		for _, slot in ipairs(hudSlots()) do
			local boss = slot:FindFirstChild('Boss')
			local completed = slot:FindFirstChild('Completed')
			if boss and boss.Visible == true and not (completed and completed.Visible) then
				return true
			end
		end
		return false
	end

	function api.specialStarOpen()
		for _, slot in ipairs(hudSlots()) do
			local completed = slot:FindFirstChild('Completed')
			if completed and completed.Visible then
				continue
			end
			for _, name in ipairs({ 'Special', 'Event', 'Horde', 'SpecialBoss', 'SpecialWave', 'HordeWave', 'Modifier', 'MiniBoss', 'Challenge' }) do
				local ch = slot:FindFirstChild(name)
				if ch and ch.Visible == true then
					return true
				end
			end
		end
		return false
	end

	function api.roomIsSpecial(dungeon, idx)
		if not idx then
			return false
		end
		if type(rt.zoneLayout) == 'table' then
			for _, z in ipairs(rt.zoneLayout) do
				if z and tonumber(z.Index) == idx and z.IsSpecial then
					return true
				end
			end
		end
		local room = dungeon and dungeon:FindFirstChild('Room_' .. tostring(idx))
		if not room then
			return false
		end
		if room:GetAttribute('IsSpecial') == true
			or room:GetAttribute('HasSpecial') == true
			or room:GetAttribute('IsHorde') == true
			or room:GetAttribute('IsEvent') == true
			or room:GetAttribute('IsWave') == true
		then
			return true
		end
		local t = string.lower(tostring(room:GetAttribute('Type') or room:GetAttribute('RoomType') or ''))
		return t:find('special', 1, true)
			or t:find('horde', 1, true)
			or t:find('event', 1, true)
			or t:find('wave', 1, true)
			or false
	end

	-- Incomplete special / horde rooms still have 0 NPCs until the wave starts.
	function api.nextSpecialRoom(dungeon)
		if not dungeon then
			return nil
		end
		local now = os.clock()
		local function okRoom(i)
			if not i or (retryAt[i] or 0) > now then
				return false
			end
			if not entryPoint(dungeon, i) then
				return false
			end
			if api.aliveCount(dungeon, i) > 0 or api.dormantCount(dungeon, i) > 0 then
				return false
			end
			return true
		end
		if type(rt.zoneLayout) == 'table' then
			for _, z in ipairs(rt.zoneLayout) do
				local i = z and tonumber(z.Index)
				if i and z.IsSpecial and not z.Completed and not z.IsBoss and okRoom(i) then
					return i
				end
			end
		end
		local maxR = api.maxRoom(dungeon)
		for i = 1, maxR do
			if api.roomIsSpecial(dungeon, i) and okRoom(i) then
				return i
			end
		end
		return nil
	end

	-- HUD still has empty circles but RoomLayout didn't map an Index. Walk
	-- sequential Room_N from the courtyard instead of standing idle.
	function api.nextOpenRoom(dungeon, fromPos)
		if not dungeon or not (hudHasOpenStar() or api.specialStarOpen()) then
			return nil
		end
		local now = os.clock()
		local want = api.maxVisited() + 1
		if want < 1 then
			want = (fromPos and api.nearestIdx(dungeon, fromPos) or 0) + 1
		end
		if want < 1 then
			want = 1
		end
		local maxR = api.maxRoom(dungeon)
		local function take(i)
			if not i or i < 1 or i > maxR then
				return nil
			end
			if (retryAt[i] or 0) > now then
				return nil
			end
			if not entryPoint(dungeon, i) then
				return nil
			end
			emptyHop[i] = nil
			rt.starLock = i
			return i
		end
		for i = want, maxR do
			local got = take(i)
			if got then
				return got
			end
		end
		for i = 1, want - 1 do
			if not visited[i] then
				local got = take(i)
				if got then
					return got
				end
			end
		end
		-- retryAt parked every room. Still do not return nil or Endless walks
		-- Next Area with empty stars on the bar.
		local soonest, soonT
		for i = 1, maxR do
			if entryPoint(dungeon, i) then
				local t = retryAt[i] or 0
				if not soonest or t < soonT then
					soonest, soonT = i, t
				end
			end
		end
		if soonest then
			retryAt[soonest] = 0
			emptyHop[soonest] = nil
			rt.starLock = soonest
			return soonest
		end
		return nil
	end

	local function seedLayoutFromController(force)
		-- Stale Done flags left Endless idle↔next-gate while Room_6 was still open.
		local fresh = os.clock() - (rt.zoneAt or 0) < 3.5
		if not force and rt.zoneFromGc and type(rt.zoneLayout) == 'table' and #rt.zoneLayout > 0 and fresh then
			return true
		end
		if not force and os.clock() - (rt.zoneSeedAt or 0) < 2.5 then
			return type(rt.zoneLayout) == 'table' and #rt.zoneLayout > 0
		end
		rt.zoneSeedAt = os.clock()
		if type(getgc) ~= 'function' then
			return type(rt.zoneLayout) == 'table' and #rt.zoneLayout > 0
		end
		pcall(function()
			for _, v in ipairs(getgc(true)) do
				if type(v) == 'table'
					and rawget(v, 'ByIndex')
					and rawget(v, 'Zones')
					and type(v.Zones) == 'table'
					and #v.Zones > 0
				then
					local copy = {}
					for i, z in ipairs(v.Zones) do
						copy[i] = copyZone(z)
					end
					rt.zoneLayout = copy
					rt.zoneFromGc = true
					rt.zoneAt = os.clock()
					break
				end
			end
		end)
		return type(rt.zoneLayout) == 'table' and #rt.zoneLayout > 0
	end

	-- First incomplete star, then sequential empty rooms. A leftover special
	-- with NPCs used to win via starLock / nextGapRoom and skip the rest.
	function api.nextStarRoom(dungeon, fromPos)
		seedLayoutFromController()
		local layout = rt.zoneLayout
		local now = os.clock()
		local lock = tonumber(rt.starLock)
		if lock and (retryAt[lock] or 0) <= now and dungeon and entryPoint(dungeon, lock) then
			return lock
		end
		local function layoutOpen()
			if type(layout) ~= 'table' then
				return false
			end
			for _, z in ipairs(layout) do
				if z and not z.IsBoss and z.Completed ~= true and z.Done ~= true then
					return true
				end
			end
			return false
		end
		if hudHasOpenStar() and not layoutOpen() then
			seedLayoutFromHud()
			layout = rt.zoneLayout
		end
		local now = os.clock()
		if type(layout) == 'table' and #layout > 0 then
			local slots = {}
			local list = progressList()
			if list then
				for _, c in ipairs(list:GetChildren()) do
					if c.Name == 'ZoneSlot' then
						slots[#slots + 1] = c
					end
				end
				table.sort(slots, function(a, b)
					return (a.LayoutOrder or 0) < (b.LayoutOrder or 0)
				end)
			end
			local function starOpen(i, z)
				if not z or not z.Index or z.IsBoss then
					return false
				end
				local done = z.Completed == true or z.Done == true
				local slot = slots[i]
				if slot then
					local boss = slot:FindFirstChild('Boss')
					local completed = slot:FindFirstChild('Completed')
					if boss and boss.Visible then
						done = true
					elseif completed then
						done = completed.Visible == true
					end
				end
				return not done
			end
			local lock = tonumber(rt.starLock)
			if lock and (retryAt[lock] or 0) <= now and (not dungeon or entryPoint(dungeon, lock)) then
				-- Stay in the room we already picked. Retargeting every tick
				-- was the overhead hop across empty zones.
				local still = true
				for _, z in ipairs(layout) do
					if z and tonumber(z.Index) == lock then
						still = not (z.Completed == true or z.Done == true)
						break
					end
				end
				if still then
					return lock
				end
				rt.starLock = nil
			elseif lock then
				rt.starLock = nil
			end
			for i, z in ipairs(layout) do
				local idx = z and z.Index
				if starOpen(i, z) and (retryAt[idx] or 0) <= now then
					if not dungeon or entryPoint(dungeon, idx) then
						rt.starLock = idx
						return idx
					end
				end
			end
		end
		if hudHasOpenStar() or api.specialStarOpen() then
			return api.nextOpenRoom(dungeon, fromPos)
				or api.nextEmpty(dungeon, fromPos, nil)
				or api.nextGapRoom(dungeon)
		end
		return api.nextGapRoom(dungeon) or api.nextOpenRoom(dungeon, fromPos)
	end

	function api.lowestDormant(dungeon)
		local best
		eachNpc(dungeon, function(npc)
			if isWorldEnemy(npc) and enemyAlive(npc) and npc:GetAttribute('IsDormant') == true then
				local i = api.indexOf(npc)
				if i and (not best or i < best) then
					best = i
				end
			end
		end)
		return best
	end

	-- HUD still has an empty circle but the mapped room is parked / missing.
	-- Walk other Room_N until that star fills (Endless often has no layout).
	function api.nextGapRoom(dungeon)
		if not dungeon then
			return nil
		end
		local now = os.clock()
		local maxR = api.maxRoom(dungeon)
		local withNpc = {}
		local anyLive = false
		eachNpc(dungeon, function(npc)
			local i = api.indexOf(npc)
			if i and enemyAlive(npc) then
				withNpc[i] = true
				emptyHop[i] = nil
				anyLive = true
			end
		end)
		local dorm = api.lowestDormant(dungeon)
		if dorm and (retryAt[dorm] or 0) <= now and entryPoint(dungeon, dorm) then
			rt.starLock = dorm
			return dorm
		end
		for i = 1, maxR do
			if withNpc[i] and (retryAt[i] or 0) <= now and entryPoint(dungeon, i) then
				rt.starLock = i
				return i
			end
		end
		-- Force-refresh Done flags when the map is empty — stale cache + park
		-- is the Endless idle↔next-gate loop with an open star elsewhere.
		seedLayoutFromController(not anyLive)
		if rt.zoneFromGc and type(rt.zoneLayout) == 'table' then
			for _, z in ipairs(rt.zoneLayout) do
				local i = z and tonumber(z.Index)
				local done = z and (z.Completed == true or z.Done == true)
				if i and not z.IsBoss and not done and entryPoint(dungeon, i) then
					-- Incomplete stars always win over park/retry. Empty hop parks
					-- used to softlock Room_6 while NextArea spun forever.
					if not anyLive then
						retryAt[i] = 0
						emptyHop[i] = nil
					elseif (retryAt[i] or 0) > now then
						continue
					end
					rt.starLock = i
					return i
				end
			end
		end
		rt.starLock = nil
		return nil
	end

	return api
end)()

-- "Next Area" gates and Locked_ key doors between rooms. Cleared rooms often leave
-- no dormant NPCs in the folder until you cross — and key gates are a separate
-- blocker the old idle path ignored entirely (it only looked for "Next Area" text).
-- Prefer firing Use Key when a prompt is up so the server unlocks the room; then
-- step through either way so a missing key cannot softlock the farm.
local NextArea = (function()
	local api = {}
	local lastAt = 0

	local function markerFromPrompt(prompt)
		local part = prompt.Parent
		if part and part:IsA('BasePart') then
			return part.Position, prompt
		end
		local model = part and part:FindFirstAncestorOfClass('Model')
		if model then
			local ok, pos = pcall(function()
				return model:GetPivot().Position
			end)
			if ok then
				return pos, prompt
			end
		end
		return nil, prompt
	end

	local function isNextText(text)
		local t = tostring(text):lower()
		return t:find('next', 1, true) and t:find('area', 1, true)
	end

	local function isKeyPrompt(prompt)
		if not prompt or not prompt:IsA('ProximityPrompt') then
			return false
		end
		local blob = (tostring(prompt.ActionText) .. ' ' .. tostring(prompt.ObjectText)):lower()
		return blob:find('key', 1, true) ~= nil or blob:find('unlock', 1, true) ~= nil
	end

	local function doorPos(door)
		if not door or not door.Parent then
			return nil
		end
		local part = getPart(door)
		if part then
			return part.Position
		end
		local ok, pos = pcall(function()
			return door:GetPivot().Position
		end)
		return ok and pos or nil
	end

	function api.find(fromPos)
		-- Full dungeon GetDescendants spikes frame time 100–200ms on Generated_
		-- maps. Cache misses used to re-walk the whole tree from the farm idle loop.
		local now = os.clock()
		local cacheFor = rt.gatePos and 0.85 or 1.4
		if now - rt.gateAt < cacheFor and rt.gateFrom then
			if (fromPos - rt.gateFrom).Magnitude < 70 then
				return rt.gatePos, rt.gatePrompt, rt.gateDoor, rt.gateDist
			end
		end
		local bestPos, bestPrompt, bestDoor, bestDist = nil, nil, nil, 450
		for _, door in ipairs(keyDoors) do
			local pos = doorPos(door)
			if pos then
				local dist = (pos - fromPos).Magnitude
				if dist < bestDist then
					bestPos, bestDoor, bestDist = pos, door, dist
					bestPrompt = door:FindFirstChildWhichIsA('ProximityPrompt', true)
				end
			end
		end
		local function considerPrompt(d)
			if not (d:IsA('ProximityPrompt') and d.Enabled) then
				return
			end
			local blob = (tostring(d.ActionText) .. ' ' .. tostring(d.ObjectText) .. ' ' .. d.Name):lower()
			local keyLike = isKeyPrompt(d)
			local nextLike = isNextText(blob) or blob:find('next area', 1, true)
			if not (keyLike or nextLike) then
				return
			end
			local pos = select(1, markerFromPrompt(d))
			if not pos then
				return
			end
			local score = (pos - fromPos).Magnitude - (keyLike and 5 or 0)
			if score < bestDist then
				bestPos, bestPrompt, bestDist = pos, d, score
				bestDoor = d:FindFirstAncestorOfClass('Model')
			end
		end
		local function considerText(d)
			if not ((d:IsA('TextLabel') or d:IsA('TextButton')) and isNextText(d.Text)) then
				return
			end
			local gui = d:FindFirstAncestorOfClass('BillboardGui') or d:FindFirstAncestorOfClass('SurfaceGui')
			local adornee = gui and (gui.Adornee or gui.Parent)
			local pos
			if adornee and adornee:IsA('BasePart') then
				pos = adornee.Position
			elseif adornee and adornee:IsA('Attachment') then
				pos = adornee.WorldPosition
			elseif gui and gui.Parent and gui.Parent:IsA('BasePart') then
				pos = gui.Parent.Position
			end
			if not pos then
				return
			end
			local dist = (pos - fromPos).Magnitude
			if dist < bestDist then
				bestPos, bestPrompt, bestDoor, bestDist = pos, nil, nil, dist
			end
		end
		local function considerContinue(d)
			if d.Name ~= 'ContinuePath' then
				return
			end
			local pos
			if d:IsA('BasePart') then
				pos = d.Position
			elseif d:IsA('Attachment') then
				pos = d.WorldPosition
			else
				local part = d:FindFirstAncestorWhichIsA('BasePart')
					or (d.Parent and d.Parent:IsA('BasePart') and d.Parent)
				if part then
					pos = part.Position
				elseif d:IsA('BillboardGui') then
					local a = d.Adornee or d.Parent
					if a and a:IsA('BasePart') then
						pos = a.Position
					elseif a and a:IsA('Attachment') then
						pos = a.WorldPosition
					end
				end
			end
			if not pos then
				return
			end
			local score = (pos - fromPos).Magnitude - 15
			if score < bestDist then
				bestPos, bestPrompt, bestDoor, bestDist = pos, nil, nil, score
			end
		end
		-- Only Room_N.Connectors (+ direct prompts on Locked_ already handled).
		local dungeon = activeDungeonRoot()
		if dungeon then
			for _, child in ipairs(dungeon:GetChildren()) do
				if tostring(child.Name):match('^Room_') then
					local connectors = child:FindFirstChild('Connectors')
					if connectors then
						for _, d in ipairs(connectors:GetDescendants()) do
							considerPrompt(d)
							considerText(d)
							considerContinue(d)
						end
					end
				end
			end
		end
		-- Courtyard / "Next Area" arches often sit on the Generated_ root, not
		-- inside Room_N.Connectors. Only walk those siblings when connectors
		-- did not already find a nearby pad.
		if dungeon and (not bestPos or bestDist > 70) then
			for _, child in ipairs(dungeon:GetChildren()) do
				local n = tostring(child.Name)
				if not n:match('^Room_') then
					local ln = n:lower()
					local gateLike = ln:find('next', 1, true)
						or ln:find('gate', 1, true)
						or ln:find('exit', 1, true)
						or ln:find('continue', 1, true)
						or ln:find('portal', 1, true)
						or ln:find('door', 1, true)
						or ln:find('area', 1, true)
					if gateLike or child:FindFirstChildWhichIsA('ProximityPrompt')
						or child:FindFirstChildWhichIsA('BillboardGui')
					then
						for _, d in ipairs(child:GetDescendants()) do
							considerPrompt(d)
							considerText(d)
							considerContinue(d)
						end
					end
				end
			end
		end
		-- Billboard on the arch the player is standing under (90-stud radius).
		if not bestPos or bestDist > 40 then
			local okParts, parts = pcall(function()
				return workspace:GetPartBoundsInRadius(fromPos, 90)
			end)
			if okParts and type(parts) == 'table' then
				local n = math.min(#parts, 80)
				for i = 1, n do
					local part = parts[i]
					if part then
						for _, ch in ipairs(part:GetChildren()) do
							considerPrompt(ch)
							considerText(ch)
							considerContinue(ch)
							if ch:IsA('BillboardGui') or ch:IsA('SurfaceGui') then
								for _, t in ipairs(ch:GetDescendants()) do
									considerText(t)
									considerPrompt(t)
								end
							end
						end
					end
				end
			end
		end
		rt.gateAt = now
		rt.gateFrom = fromPos
		rt.gatePos = bestPos
		rt.gatePrompt = bestPrompt
		rt.gateDoor = bestDoor
		rt.gateDist = bestDist
		return bestPos, bestPrompt, bestDoor, bestDist
	end

	-- Returns true when we actually moved, so the farm can re-scan for targets.
	function api.advance()
		if os.clock() - lastAt < 2.5 then
			return false
		end
		local root = routeRoot()
		if not root then
			return false
		end
		-- Fresh door list: Locked_ models appear as rooms stream in.
		pcall(scanEspThrottled, 2.5)
		local pos, prompt, door = api.find(root.Position)
		if not pos then
			return false
		end
		lastAt = os.clock()
		if door then
			ghostDoor(door)
		end
		-- Key prompts sit on KeyModel beside the gate — stand there first, then fire.
		if prompt and prompt.Enabled and isKeyPrompt(prompt) and wantOpenGates() then
			local blob = (tostring(prompt.ActionText) .. ' ' .. tostring(prompt.ObjectText)):lower()
			local skipSpecial = blob:find('special boss', 1, true)
				or blob:find('platinum', 1, true)
				or blob:find('summon', 1, true)
			if not skipSpecial then
				local keyModel = prompt.Parent
				local stand = promptStandPos(prompt, (keyModel and keyModel:IsA('Model')) and keyModel or door)
				if stand then
					Pin.at(stand, true)
					task.wait(0.12)
				end
				local hold = math.max(tonumber(prompt.HoldDuration) or 0, 0)
				if type(fireproximityprompt) == 'function' then
					pcall(fireproximityprompt, prompt, hold)
					pcall(fireproximityprompt, prompt, 0, hold)
					pcall(fireproximityprompt, prompt)
				end
				fireChestPrompt(prompt)
				task.wait(0.12)
			end
		elseif prompt and prompt.Enabled then
			fireChestPrompt(prompt)
			task.wait(0.35)
		end
		-- Stand on the pad first so TouchInterest / area load fires, then step through.
		Pin.at(standingSpot(pos, 0), true)
		task.wait(0.18)
		local live = routeRoot()
		if live then
			local flat = Vector3.new(pos.X - live.Position.X, 0, pos.Z - live.Position.Z)
			local dir = flat.Magnitude > 0.5 and flat.Unit or live.CFrame.LookVector
			local beyond = pos + Vector3.new(dir.X, 0, dir.Z) * 18
			Pin.at(standingSpot(beyond), true)
			task.wait(0.25)
		end
		Pin.stop()
		return true
	end

	return api
end)()

-- Farm / roll / potion / codes: own function scope (Luau 200-local main-chunk cap).
local RunLoops = (function()
local function isRangedEnemy(npc)
	local id = string.lower(tostring(npc:GetAttribute('ItemId') or npc.Name or ''))
	return id:find('archer', 1, true)
		or id:find('bow', 1, true)
		or id:find('ranger', 1, true)
		or id:find('marksman', 1, true)
		or id:find('sniper', 1, true)
		or id:find('crossbow', 1, true)
		or id:find('gunner', 1, true)
		or id:find('mage', 1, true)
		or id:find('caster', 1, true)
		or id:find('wizard', 1, true)
		or id:find('sorcer', 1, true)
		or id:find('ranged', 1, true)
end

-- Floor boss only. Room specials / minibosses are cleared with the rest of the map.
local function isFinalBoss(npc)
	if not npc then
		return false
	end
	if npc:GetAttribute('IsMiniBoss') == true or isMiniBossEnemy(npc) then
		return false
	end
	if npc:GetAttribute('IsSpecialBoss') == true or npc:GetAttribute('IsSpecial') == true then
		return false
	end
	if npc:GetAttribute('IsBoss') == true then
		return true
	end
	local phase = Rooms.sessionPhase()
	return (phase == 'BossPhase' or phase == 'Boss') and isBossEnemy(npc)
end

local function eachFarmNpc(fn)
	local dungeon = activeDungeonRoot()
	local seen = {}
	local function take(npc)
		if not npc or not npc.Parent or seen[npc] or not isWorldEnemy(npc) then
			return
		end
		if npc:IsA('BasePart') then
			local id = string.lower(tostring(npc:GetAttribute('ItemId') or npc.Name or ''))
			if npc:GetAttribute('IsCrystal') ~= true and not id:find('crystal', 1, true) then
				return
			end
		elseif not npc:IsA('Model') then
			return
		end
		seen[npc] = true
		fn(npc)
	end
	local npcs = dungeon and dungeon:FindFirstChild('NPCs')
	if npcs then
		for _, npc in ipairs(npcs:GetChildren()) do
			take(npc)
		end
	end
	if dungeon then
		for _, tag in ipairs({ 'Enemy', 'Boss', 'Elite', 'MiniBoss', 'Miniboss' }) do
			local tagged = CollectionService:GetTagged(tag)
			if type(tagged) == 'table' then
				for _, inst in ipairs(tagged) do
					if inst:IsDescendantOf(dungeon) then
						take(inst)
					end
				end
			end
		end
	end
	-- The First Test / Magic Unleashed lives in Raid_NPCs, not Generated_.
	local raidNpcs = workspace:FindFirstChild('Raid_NPCs')
	if raidNpcs then
		for _, npc in ipairs(raidNpcs:GetChildren()) do
			take(npc)
			if npc:IsA('Model') or npc:IsA('Folder') then
				for _, ch in ipairs(npc:GetChildren()) do
					local n = string.lower(ch.Name)
					if n:find('crystal', 1, true) or ch:GetAttribute('IsCrystal') == true then
						take(ch)
					end
				end
			end
		end
	end
	local chall = workspace:FindFirstChild('Challenge_Dungeons')
	if chall then
		for _, room in ipairs(chall:GetChildren()) do
			for _, ch in ipairs(room:GetChildren()) do
				local n = string.lower(ch.Name)
				if n:find('crystal', 1, true) or ch:GetAttribute('IsCrystal') == true then
					take(ch)
				end
			end
		end
	end
	-- Only while CurrentDungeon is actually Boss Rush. Leftover folder children
	-- in Endless / raids used to steal the target and freeze room walking.
	if inBossRushFarm() then
		local rush = bossRushNpcFolder()
		if rush then
			for _, npc in ipairs(rush:GetChildren()) do
				take(npc)
			end
		end
	end
end

local function countFarmSides()
	local trash, bosses = 0, 0
	eachFarmNpc(function(npc)
		if enemyAlive(npc) then
			if isFinalBoss(npc) then
				bosses += 1
			elseif enemyRoot(npc) then
				-- Dormant special leftovers (no HRP) are not trash — they made
				-- skipFinal hide the floor boss and bounce you off it.
				trash += 1
			end
		end
	end)
	return trash, bosses
end

-- Summons around a room special (Scarlet Knight). Dormant leftovers elsewhere
-- must not count — that used to skip the special forever.
local ADD_NEAR = 140

local function isRaidBossNpc(npc)
	if not npc or npc:GetAttribute('IsBoss') ~= true then
		return false
	end
	if npc:GetAttribute('DungeonRun') == 'Raids' or npc:GetAttribute('ChallengeDungeon') == 'Raids' then
		return true
	end
	local p = npc.Parent
	return p ~= nil and p.Name == 'Raid_NPCs'
end

-- Dark Professor crystals. Breaking them late is a wipe. Ignore Boss_Rush spawn pads.
local function isRaidCrystal(npc)
	if not npc or not npc.Parent then
		return false
	end
	local p = npc.Parent
	if p.Name == 'Boss_Rush' or (p.Parent and p.Parent.Name == 'Boss_Rush') then
		return false
	end
	local id = string.lower(tostring(npc:GetAttribute('ItemId') or npc.Name or ''))
	if id:find('spawn', 1, true) then
		return false
	end
	if npc:GetAttribute('IsCrystal') == true or id:find('crystal', 1, true) then
		return enemyAlive(npc) and enemyRoot(npc) ~= nil
	end
	return false
end

local function nearestCrystal()
	local me = routeRoot()
	local best, bestD = nil, nil
	eachFarmNpc(function(npc)
		if not isRaidCrystal(npc) then
			return
		end
		local part = enemyRoot(npc)
		if not part then
			return
		end
		local d = me and (part.Position - me.Position).Magnitude or 0
		if not bestD or d < bestD then
			best, bestD = npc, d
		end
	end)
	return best, bestD
end

local function listRaidCrystals()
	local out = {}
	eachFarmNpc(function(npc)
		if isRaidCrystal(npc) then
			out[#out + 1] = npc
		end
	end)
	return out
end

local function crystalCentroid(list)
	local sx, sy, sz, n = 0, 0, 0, 0
	for i = 1, #(list or {}) do
		local part = enemyRoot(list[i])
		if part then
			local p = part.Position
			sx += p.X
			sy += p.Y
			sz += p.Z
			n += 1
		end
	end
	if n < 1 then
		return nil
	end
	return Vector3.new(sx / n, sy / n, sz / n)
end

-- Dark Professor: hold G for the crystal phase. Dumping it on his body wastes the wipe clear.
local function savesUltForCrystals(npc)
	if not npc then
		return false
	end
	local id = string.lower(tostring(npc:GetAttribute('ItemId') or npc.Name or ''))
	return id:find('professor', 1, true) ~= nil
end

local function holdOnCrystalPack()
	Pin.follow(function()
		if os.clock() - (rt.aoeScanAt or 0) > 0.12 then
			rt.aoeScanAt = os.clock()
			pcall(rt.avoidFloorAoe)
		end
		if typeof(rt.aoeGoal) == 'Vector3' and os.clock() < (rt.aoeUntil or 0) then
			return rt.aoeGoal
		end
		local list = listRaidCrystals()
		local mid = crystalCentroid(list)
		if not mid then
			return nil
		end
		-- Stand in the middle so one ult / hitbox catches every crystal.
		return mid, mid
	end)
end

rt.tryFarmUlt = function()
	if not on('DLAutoSkill') and not on('DLAutoFarm') then
		return false
	end
	local ultCharge = tonumber(LocalPlayer:GetAttribute('UltimateCharge')) or 0
	local ultMax = tonumber(LocalPlayer:GetAttribute('UltimateChargeMax')) or 100
	local ultReady = LocalPlayer:GetAttribute('HasUltimate') == true
		and (
			LocalPlayer:GetAttribute('UltimateReady') == true
			or ultCharge >= ultMax
			or (ultMax > 0 and ultCharge / ultMax >= 0.95)
		)
	if not ultReady or os.clock() - (rt.lastUltFire or 0) <= 0.4 then
		return false
	end
	local crystals = listRaidCrystals()
	local npc = rt.farmFightNpc
	local onCrystals = #crystals > 0 and (rt.crystalPack == true or (npc and isRaidCrystal(npc)))
	-- Dark Professor: G on his body wastes the wipe. Hold until the 4 crystals
	-- are out, then dump from the pack center. Everything else fires immediately.
	if onCrystals then
		local mid = crystalCentroid(crystals)
		local me = routeRoot()
		if not (mid and me and (me.Position - mid).Magnitude <= 16) then
			return false
		end
	elseif npc and enemyAlive(npc) and savesUltForCrystals(npc) then
		return false
	end
	rt.lastUltFire = os.clock()
	rt.ultLockUntil = os.clock() + 0.4
	pcall(fireSkill, 'E')
	pcall(fireSkill, 'G')
	pcall(fireSkill, 'Ultimate')
	pcall(function()
		local vim = game:GetService('VirtualInputManager')
		vim:SendKeyEvent(true, Enum.KeyCode.G, false, game)
		task.delay(0.08, function()
			pcall(function()
				vim:SendKeyEvent(false, Enum.KeyCode.G, false, game)
			end)
		end)
	end)
	pcall(function()
		if type(keypress) == 'function' then
			keypress(0x47)
			task.delay(0.08, function()
				if type(keyrelease) == 'function' then
					keyrelease(0x47)
				end
			end)
		end
	end)
	pcall(function()
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		local ult = pg
			and pg:FindFirstChild('Main')
			and pg.Main:FindFirstChild('HUD')
			and pg.Main.HUD:FindFirstChild('Actions')
			and pg.Main.HUD.Actions:FindFirstChild('Bottom')
			and pg.Main.HUD.Actions.Bottom:FindFirstChild('Bars')
			and pg.Main.HUD.Actions.Bottom.Bars:FindFirstChild('Ultimate')
		local btn = ult and (ult:FindFirstChild('MobileInput', true) or ult:FindFirstChildWhichIsA('GuiButton', true))
		if btn and type(firesignal) == 'function' then
			pcall(firesignal, btn.MouseButton1Click)
			pcall(firesignal, btn.Activated)
		end
	end)
	return true
end

local function isAwakeAdd(npc)
	if not npc or not enemyAlive(npc) or farmSkipped(npc) then
		return false
	end
	if npc:GetAttribute('IsDormant') == true then
		return false
	end
	if enemyRank(npc) >= 4 or isFinalBoss(npc) then
		return false
	end
	return enemyRoot(npc) ~= nil
end

local function addsNearSpecial(anchor)
	local me = routeRoot()
	local ap = anchor and enemyRoot(anchor)
	local from = (ap and ap.Position) or (me and me.Position)
	if not from then
		return nil
	end
	local best, bestD = nil, nil
	eachFarmNpc(function(npc)
		if npc == anchor or not isAwakeAdd(npc) then
			return
		end
		local part = enemyRoot(npc)
		if not part then
			return
		end
		local d = (part.Position - from).Magnitude
		if d <= ADD_NEAR and (not bestD or d < bestD) then
			best, bestD = npc, d
		end
	end)
	return best, bestD
end

local function listAddsNearSpecial(anchor)
	local out = {}
	local ap = anchor and enemyRoot(anchor)
	local me = routeRoot()
	local from = (ap and ap.Position) or (me and me.Position)
	if not from then
		return out
	end
	eachFarmNpc(function(npc)
		if npc == anchor or not isAwakeAdd(npc) then
			return
		end
		local part = enemyRoot(npc)
		if not part then
			return
		end
		if (part.Position - from).Magnitude <= ADD_NEAR then
			out[#out + 1] = npc
		end
	end)
	return out
end

local function raidSpecialAnchor()
	local best
	eachFarmNpc(function(npc)
		if not enemyAlive(npc) then
			return
		end
		if isRaidBossNpc(npc) or (enemyRank(npc) >= 4 and savesUltForCrystals(npc)) then
			best = npc
		elseif enemyRank(npc) >= 4 and not best then
			best = npc
		end
	end)
	return best
end

local function holdOnAddPack(anchor)
	Pin.follow(function()
		if os.clock() - (rt.aoeScanAt or 0) > 0.12 then
			rt.aoeScanAt = os.clock()
			pcall(rt.avoidFloorAoe)
		end
		if typeof(rt.aoeGoal) == 'Vector3' and os.clock() < (rt.aoeUntil or 0) then
			return rt.aoeGoal
		end
		local list = listAddsNearSpecial(anchor)
		local mid = crystalCentroid(list)
		if not mid then
			return nil
		end
		-- Center of the summon wave so M1 / skills splash the whole pack.
		return mid, mid
	end)
end

-- Sticky lock: minis / floor bosses stay selected until they die. Specials
-- are not locked — their summoned pack has to be cleared first.
local farmLock = nil

rt.npcInCorridor = function(npc)
	if not npc or isFinalBoss(npc) then
		return false
	end
	local d = activeDungeonRoot()
	if not d then
		return false
	end
	local idx = Rooms.indexOf(npc)
	if idx and Rooms.isCorridor(d, idx) then
		return true
	end
	local p = enemyRoot(npc)
	return p ~= nil and Rooms.posInCorridor(d, p.Position) == true
end

local function pickFarmTarget()
	local root = routeRoot()
	if not root then
		return nil
	end
	local preferBoss = on('DLFarmBoss')
	local preferRanged = on('DLFarmRanged')
	local trash, bosses = countFarmSides()
	local skipFinal = trash > 0
	-- Boss Rush is a 1v1 arena. Do not skip the rush boss as a "floor boss"
	-- because leftover Generated_ trash from another run is still in the world.
	if inBossRushFarm() then
		skipFinal = false
	end
	-- Sequential room tour fights whatever is in THIS room, including the
	-- floor boss. skipFinal is map-wide leftover trash after the tour.
	if tonumber(rt.farmRoomFilter) then
		skipFinal = false
	end
	-- Crystals first (Dark Professor wipe if they finish). Hunt special next
	-- (Scarlet Knight loop), then raid / room special, then summoned adds.
	local crystal, crystalD = nearestCrystal()
	if crystal then
		farmLock = nil
		return crystal, crystalD
	end
	if on('DLHuntSpecial') then
		local hunt, huntD = findHuntTarget()
		if hunt then
			farmLock = nil
			return hunt, huntD
		end
	end
	if farmLock and (enemyRank(farmLock) >= 4 or isRaidBossNpc(farmLock))
		and select(1, addsNearSpecial(farmLock))
	then
		farmLock = nil
	end
	if farmLock then
		local keep = enemyAlive(farmLock)
			and not farmSkipped(farmLock)
			and not (skipFinal and isFinalBoss(farmLock))
			and not (enemyRank(farmLock) >= 4 and select(1, addsNearSpecial(farmLock)))
		local roomOnly = tonumber(rt.farmRoomFilter)
		if keep and roomOnly and not Rooms.npcInRoom(activeDungeonRoot(), farmLock, roomOnly) then
			keep = false
		end
		local part = keep and enemyRoot(farmLock)
		local d = part and (part.Position - root.Position).Magnitude
		if keep and part then
			return farmLock, d
		end
		farmLock = nil
	end
	local nearest, nearestD = nil, nil
	local top, topD, topRank = nil, nil, 0
	local ranged, rangedD = nil, nil
		eachFarmNpc(function(npc)
			if not enemyAlive(npc) or farmSkipped(npc) then
				return
			end
			local roomOnly = tonumber(rt.farmRoomFilter)
			local doneIdx = Rooms.indexOf(npc)
			if not roomOnly and doneIdx and roomIsSwept(activeDungeonRoot(), doneIdx) and not isFinalBoss(npc) then
				return
			end
			if roomOnly and not Rooms.npcInRoom(activeDungeonRoot(), npc, roomOnly) then
			return
		end
		if skipFinal and isFinalBoss(npc) then
			return
		end
		local part = enemyRoot(npc)
		if not part then
			return
		end
		local d = (part.Position - root.Position).Magnitude
		if not nearestD or d < nearestD then
			nearest, nearestD = npc, d
		end
		local rank = enemyRank(npc)
		if rank > topRank or (rank == topRank and (not topD or d < topD)) then
			top, topD, topRank = npc, d, rank
		end
		local asleep = npc:GetAttribute('IsDormant') == true
		if preferRanged and not asleep and isRangedEnemy(npc) and (not rangedD or d < rangedD) then
			ranged, rangedD = npc, d
		end
	end)
	local picked, pickedD = nearest, nearestD
	-- Raid Dark Professor / room specials over map fodder so we actually warp in.
	if top and isRaidBossNpc(top) then
		local add, addD = addsNearSpecial(top)
		if add then
			picked, pickedD = add, addD
		else
			picked, pickedD = top, topD
		end
	elseif top and topRank >= 3 and topRank < 4 then
		picked, pickedD = top, topD
	elseif preferBoss and top and topRank >= 2 and topRank < 4 then
		picked, pickedD = top, topD
	elseif preferRanged and ranged then
		picked, pickedD = ranged, rangedD
	end
	if picked and enemyRank(picked) >= 4 then
		local add, addD = addsNearSpecial(picked)
		if add then
			picked, pickedD = add, addD
		end
	elseif (not picked or enemyRank(picked) < 3) and top and topRank >= 4 then
		local add, addD = addsNearSpecial(top)
		if add then
			picked, pickedD = add, addD
		else
			picked, pickedD = top, topD
		end
	end
	if picked and enemyRank(picked) >= 3 and enemyRank(picked) < 4 and not isRaidBossNpc(picked) then
		farmLock = picked
	end
	-- Fodder: stand in the densest clump, not on a lone nearest beetle.
	if picked and enemyRank(picked) < 3 and not preferRanged then
		local CROWD_R = 22
		local best, bestN, bestD = picked, 0, pickedD or 9e9
		local counts = {}
		local parts = {}
		eachFarmNpc(function(npc)
			if not enemyAlive(npc) or farmSkipped(npc) or enemyRank(npc) >= 3 then
				return
			end
			local roomOnly = tonumber(rt.farmRoomFilter)
			if roomOnly and not Rooms.npcInRoom(activeDungeonRoot(), npc, roomOnly) then
				return
			end
			if skipFinal and isFinalBoss(npc) then
				return
			end
			local part = enemyRoot(npc)
			if not part then
				return
			end
			parts[npc] = part
		end)
		for npc, part in pairs(parts) do
			local n = 0
			local room = Rooms.indexOf(npc)
			for other, op in pairs(parts) do
				if (not room or Rooms.indexOf(other) == room)
					and (op.Position - part.Position).Magnitude <= CROWD_R
				then
					n += 1
				end
			end
			counts[npc] = n
			local d = (part.Position - root.Position).Magnitude
			if n > bestN or (n == bestN and d < bestD) then
				best, bestN, bestD = npc, n, d
			end
		end
		if best then
			picked, pickedD = best, bestD
		end
	end
	return picked, pickedD
end

-- One map-wide chest pass when trash is gone. Do not latch "swept" on an empty
-- or routeBusy miss — Snow chests enable a beat after the last kill, and a
-- special-summon route used to mark the sweep done before any prompt was fired.
local function openDungeonChests()
	local list = {}
	for _, gen in ipairs(workspace:GetChildren()) do
		if gen.Name:sub(1, 10) == 'Generated_' then
			for _, child in ipairs(gen:GetChildren()) do
				if child:GetAttribute('DungeonChest') == true or child.Name:sub(1, 13) == 'DungeonChest' then
					local idx = tonumber(child:GetAttribute('RoomIndex'))
					local d = activeDungeonRoot()
					if idx and d and Rooms.aliveCount(d, idx) > 0 then
						-- Pack still in this room — never queue the chest.
					elseif chestStillOpen(child) then
						list[#list + 1] = child
					elseif inEndlessFarm() and chestClaimCandidate(child) then
						local here = routeRoot()
						local anc = chestAnchor(child)
						local near = here and anc and (here.Position - anc).Magnitude < 280
						if near then
							list[#list + 1] = child
						end
					end
				end
			end
		end
	end
	return list
end

local function tryChestSweep(why)
	if not on('DLChestAnywhere') or not farmActive() then
		return false
	end
	local dungeon = activeDungeonRoot()
	-- Trash first. Empty NPCs folder (Endless between packs) must still sweep.
	local living = dungeon and Rooms.livingNpc(dungeon) or 0
	local trashLeft = 0
	if living > 0 then
		trashLeft = select(1, countFarmSides())
	end
	if trashLeft > 0 then
		return false
	end
	if not inEndlessFarm() and rt.farmChestSwept and #openDungeonChests() == 0 then
		return false
	end
	rt.farmChestSwept = false
	local waitUntil = os.clock() + (inEndlessFarm() and 0.8 or 4)
	while routeBusy and os.clock() < waitUntil and farmActive() do
		farmLabel = 'chest sweep · waiting'
		task.wait(0.08)
	end
	if routeBusy or not farmActive() then
		return false
	end
	local found = 0
	local tries = inEndlessFarm() and 8 or 12
	for _ = 1, tries do
		pcall(scanEsp)
		found = #openDungeonChests()
		if found > 0 then
			break
		end
		task.wait(inEndlessFarm() and 0.06 or 0.12)
	end
	if found == 0 then
		rt.farmChestSwept = true
		return false
	end
	farmLabel = why or 'chest sweep'
	rt.chestFast = true
	local looted = collectChestRoute(true, nil)
	rt.chestFast = false
	if #openDungeonChests() == 0 then
		rt.farmChestSwept = true
	end
	return looted
end

local function specialBossAlive()
	local found = false
	eachFarmNpc(function(npc)
		if not found and enemyAlive(npc) and enemyRank(npc) >= 4 then
			found = true
		end
	end)
	return found
end

local function huntTargetNeedle()
	local v = Options.DLHuntTarget and tostring(Options.DLHuntTarget.Value or '')
	if v == '' or v == 'nil' then
		v = 'Scarlet Knight'
	end
	return string.lower(v)
end

local function isHuntTarget(npc)
	if not npc or not on('DLHuntSpecial') then
		return false
	end
	local needle = huntTargetNeedle()
	local id = string.lower(tostring(npc:GetAttribute('ItemId') or ''))
	local name = string.lower(tostring(npc.Name or ''))
	if needle ~= '' and (id:find(needle, 1, true) or name:find(needle, 1, true)) then
		return true
	end
	-- Fallback: any room special / special boss while hunting.
	if npc:GetAttribute('IsSpecialBoss') == true or npc:GetAttribute('IsSpecial') == true then
		return true
	end
	return enemyRank(npc) >= 4 and not isFinalBoss(npc) and not isRaidBossNpc(npc)
end

local function findHuntTarget()
	local best, bestD = nil, nil
	local me = routeRoot()
	eachFarmNpc(function(npc)
		if not isHuntTarget(npc) or not enemyAlive(npc) then
			return
		end
		local part = enemyRoot(npc)
		if not part then
			return
		end
		local d = me and (part.Position - me.Position).Magnitude or 0
		if not bestD or d < bestD then
			best, bestD = npc, d
		end
	end)
	return best, bestD
end

local function readKeyCounts()
	local keys = {}
	pcall(function()
		local Knit = require(game:GetService('ReplicatedStorage').Packages.Knit)
		local d = Knit.Registry and Knit.Registry._Entries and Knit.Registry._Entries.PlayerData
		local data = d and d.Data
		if type(data) == 'table' and type(data.Keys) == 'table' then
			for k, v in pairs(data.Keys) do
				keys[tostring(k)] = tonumber(v) or 0
			end
		end
	end)
	return keys
end

-- Skull_Totem prompt: "Summon Special Boss" / "7x Platinum Key". Platinum is T4.
local function totemKeyCost(prompt)
	local blob = tostring(prompt and prompt.ObjectText or '')
	local n = tonumber(blob:match('(%d+)%s*[xX]')) or tonumber(blob:match('(%d+)')) or 7
	local low = blob:lower()
	local id = 'T4'
	if low:find('master', 1, true) then
		id = 'Master'
	elseif low:find('celestial', 1, true) then
		id = 'T5'
	elseif low:find('platinum', 1, true) then
		id = 'T4'
	elseif low:find('gold', 1, true) then
		id = 'T3'
	elseif low:find('silver', 1, true) then
		id = 'T2'
	elseif low:find('bronze', 1, true) then
		id = 'T1'
	end
	return n, id
end

local function findSpecialTotem()
	local dungeon = activeDungeonRoot()
	if not dungeon then
		return nil, nil
	end
	local totem = dungeon:FindFirstChild('Skull_Totem')
	local prompt = totem and totem:FindFirstChildWhichIsA('ProximityPrompt', true)
	if prompt then
		return prompt, totem
	end
	for _, child in ipairs(dungeon:GetChildren()) do
		local nm = string.lower(child.Name)
		if nm:find('skull', 1, true) or nm:find('totem', 1, true) then
			local p = child:FindFirstChildWhichIsA('ProximityPrompt', true)
			if p then
				local blob = (tostring(p.ActionText) .. ' ' .. tostring(p.ObjectText)):lower()
				if blob:find('special', 1, true) or blob:find('summon', 1, true) then
					return p, child
				end
			end
		end
	end
	return nil, nil
end

local function clickGuiButton(btn)
	if not btn or not btn:IsA('GuiButton') then
		return false
	end
	if type(firesignal) == 'function' then
		local ok = pcall(firesignal, btn.MouseButton1Click)
		if ok then
			return true
		end
	end
	local ok, conns = pcall(getconnections, btn.MouseButton1Click)
	if not ok or type(conns) ~= 'table' then
		return false
	end
	local fired = false
	for _, c in ipairs(conns) do
		if c.Function then
			task.spawn(c.Function)
			fired = true
		end
	end
	return fired
end

-- Totem prompt only opens HUD.Warning ("Consume 7x Platinum Key to summon …?").
-- The green Confirm / Summon button is what actually spends the keys.
local function confirmSpecialSummon()
	local pg = LocalPlayer:FindFirstChild('PlayerGui')
	local main = pg and pg:FindFirstChild('Main')
	local hud = main and main:FindFirstChild('HUD')
	local warn = hud and hud:FindFirstChild('Warning')
	if not warn or warn.Visible ~= true then
		return false
	end
	local lab = warn:FindFirstChild('Warning_Message', true)
	local msg = ''
	if lab and (lab:IsA('TextLabel') or lab:IsA('TextButton')) then
		msg = string.lower(tostring(lab.Text or ''))
	end
	if msg ~= '' and not (
		msg:find('summon', 1, true)
		or msg:find('platinum', 1, true)
		or msg:find('special', 1, true)
	) then
		return false
	end
	local btn = warn:FindFirstChild('Confirm')
	if not btn then
		for _, d in ipairs(warn:GetDescendants()) do
			if d:IsA('GuiButton') then
				local t = ''
				local title = d:FindFirstChildWhichIsA('TextLabel', true)
				if title then
					t = string.lower(tostring(title.Text or ''))
				end
				local n = string.lower(d.Name)
				if n:find('confirm', 1, true) or t == 'summon' or t == 'yes' then
					btn = d
					break
				end
			end
		end
	end
	if not clickGuiButton(btn) then
		return false
	end
	return true
end

local function trySummonSpecial()
	if rt.refillUrgent or rt.refillBusy then
		return false
	end
	if not on('DLAutoSpecial') then
		return false
	end
	if rt.specialBusy then
		return false
	end
	if os.clock() < (rt.specialNext or 0) then
		return false
	end
	local prompt, totem = findSpecialTotem()
	if not prompt or not prompt.Parent or prompt.Enabled ~= true then
		rt.specialHud = 'special  ·  totem not ready'
		rt.specialNext = os.clock() + 4
		return false
	end
	-- Totem still lit = not spent. Do not skip because a special model is already
	-- in NPCs — that cancelled the warp while Wayfarers kept the farm busy.
	local need, keyId = totemKeyCost(prompt)
	local counts = readKeyCounts()
	local have = counts[keyId]
	local label = keyId == 'T4' and 'Platinum' or (keyId == 'T5' and 'Celestial' or keyId)
	if type(have) == 'number' and have < need then
		rt.specialHud = ('special  ·  %d/%d %s'):format(have, need, label)
		if os.clock() - (rt.specialKeyWarn or 0) > 8 then
			rt.specialKeyWarn = os.clock()
			Library:Notify(('Special summon: %d/%d %s keys — warp skipped'):format(have, need, label))
		end
		rt.specialNext = os.clock() + 4
		return false
	end
	rt.specialHud = 'summon special'
	rt.specialBusy = true
	rt.specialNext = os.clock() + 8
	farmLabel = 'summon special'
	local wasRoute = routeBusy
	local wasNoclip = noclipOn
	routeBusy = true
	noclipOn = true
	pcall(setCharNoclip, true)
	task.spawn(function()
		pcall(function()
			prompt.MaxActivationDistance = math.max(tonumber(prompt.MaxActivationDistance) or 10, 24)
		end)
		local att = prompt.Parent
		local stand
		if att and att:IsA('Attachment') then
			stand = att.WorldPosition + Vector3.new(0, 3, 0)
		elseif att and att:IsA('BasePart') then
			stand = att.Position + Vector3.new(0, 3, 0)
		else
			stand = promptStandPos(prompt, totem)
		end
		if stand then
			Pin.at(stand, true)
			task.wait(0.4)
		end
		local deadline = os.clock() + 6
		while os.clock() < deadline and currentInstance() and on('DLAutoSpecial') do
			if rt.refillUrgent or rt.refillBusy then
				break
			end
			if not prompt.Parent or prompt.Enabled ~= true then
				break
			end
			if stand then
				Pin.at(stand, true)
			end
			chestFiredAt[prompt] = nil
			fireChestPrompt(prompt)
			pcall(confirmSpecialSummon)
			task.wait(0.12)
			if specialBossAlive() and prompt.Enabled ~= true then
				break
			end
		end
		local confirmUntil = os.clock() + 5
		while os.clock() < confirmUntil and currentInstance() and on('DLAutoSpecial') do
			if confirmSpecialSummon() then
				farmLabel = 'summon confirm'
			end
			if specialBossAlive() then
				break
			end
			local pg = LocalPlayer:FindFirstChild('PlayerGui')
			local warn = pg and pg:FindFirstChild('Main')
			warn = warn and warn:FindFirstChild('HUD')
			warn = warn and warn:FindFirstChild('Warning')
			if (not warn or warn.Visible ~= true) and specialBossAlive() then
				break
			end
			if not warn or warn.Visible ~= true then
				if not (prompt.Parent and prompt.Enabled) then
					break
				end
			end
			task.wait(0.15)
		end
		local ok = not (prompt.Parent and prompt.Enabled) or specialBossAlive()
		rt.specialNext = os.clock() + (ok and 20 or 3)
		if ok then
			rt.specialHud = 'special  ·  summoned'
			Library:Notify('Special boss summoned')
		else
			rt.specialHud = 'special  ·  totem ready'
		end
		if not wasNoclip and not farmBusy then
			noclipOn = false
			pcall(setCharNoclip, false)
		else
			noclipOn = true
		end
		if not wasRoute and not rt.refillBusy and not rt.refillUrgent then
			routeBusy = false
		end
		if farmBusy then
			Pin.station()
		else
			Pin.stop()
		end
		rt.specialBusy = false
	end)
	return true
end

local function wakeTarget(npc)
	local dungeon = activeDungeonRoot()
	local part = enemyRoot(npc)
	local idx = Rooms.indexOf(npc)
	if not idx and part and dungeon then
		idx = select(1, Rooms.nearestIdx(dungeon, part.Position))
	end
	local my = routeRoot()
	local far = part and my and (part.Position - my.Position).Magnitude > 42
	if far and idx and dungeon then
		pcall(Rooms.enter, dungeon, idx)
	end
	my = routeRoot()
	local zone = idx and dungeon and Rooms.zone(dungeon, idx)
	pcall(function()
		if my then
			my.CanCollide = true
		end
	end)
	if zone then
		Pin.at(standingSpot(zone.Position, 0), true)
		if my and type(firetouchinterest) == 'function' then
			pcall(firetouchinterest, my, zone, 0)
			pcall(firetouchinterest, my, zone, 1)
		end
		task.wait(0.3)
	end
	part = enemyRoot(npc)
	if part then
		Pin.at(part.Position + Vector3.new(0, 3.2, 0), true)
	end
	local untilAt = os.clock() + 2.4
	while os.clock() < untilAt and npc.Parent and npc:GetAttribute('IsDormant') == true and farmActive() do
		my = routeRoot()
		if zone and my and type(firetouchinterest) == 'function' then
			pcall(firetouchinterest, my, zone, 0)
			pcall(firetouchinterest, my, zone, 1)
		end
		task.wait(0.2)
	end
	noclipOn = true
	pcall(setCharNoclip, true)
end

-- Weapon_Data.HitboxSize is the real M1 volume (Y = vertical, Z = range). Cached
-- so the pin callback does not require() every Heartbeat.
local function equippedHitboxSize()
	local cached = rt.hitboxSize
	local at = rt.hitboxAt or 0
	if cached and os.clock() - at < 2.5 then
		return cached
	end
	local size = Vector3.new(10, 10, 14)
	pcall(function()
		local rs = game:GetService('ReplicatedStorage')
		local data = rt.weaponData
		if type(data) ~= 'table' then
			local ok, w = pcall(require, rs.Weapons.Weapon_Data)
			data = (ok and type(w) == 'table') and w or nil
			rt.weaponData = data
		end
		if type(data) ~= 'table' then
			return
		end
		local function take(name)
			if type(name) ~= 'string' or name == '' then
				return false
			end
			local w = data[name]
			if type(w) == 'table' and typeof(w.HitboxSize) == 'Vector3' then
				size = w.HitboxSize
				return true
			end
			return false
		end
		local cls = tostring(LocalPlayer:GetAttribute('Current_Class') or LocalPlayer:GetAttribute('Active_Class') or '')
		local folder = rs:FindFirstChild('Classes')
		local cf = folder and cls ~= '' and folder:FindFirstChild(cls)
		if cf then
			local def = cf:FindFirstChild('Definition')
			if def then
				local ok, t = pcall(require, def)
				if ok and type(t) == 'table' then
					if take(t.Weapon or t.WeaponName or t.DefaultWeapon or t.M1Weapon) then
						return
					end
				end
			end
			if take(cf:GetAttribute('Weapon')) then
				return
			end
		end
		local char = character()
		if char then
			for _, inst in ipairs(char:GetDescendants()) do
				if take(inst.Name) then
					return
				end
			end
		end
	end)
	rt.hitboxSize = size
	rt.hitboxAt = os.clock()
	return size
end

local function enemyBodyY(npc, part)
	local sy = (part.Size and part.Size.Y) or 5
	local minY = part.Position.Y - sy * 0.5
	local maxY = part.Position.Y + sy * 0.5
	for _, name in ipairs({ 'Torso', 'UpperTorso', 'LowerTorso', 'Head', 'Hitbox' }) do
		local p = npc:FindFirstChild(name)
		if p and p:IsA('BasePart') then
			local h = p.Size.Y * 0.5
			minY = math.min(minY, p.Position.Y - h)
			maxY = math.max(maxY, p.Position.Y + h)
		end
	end
	return minY, maxY
end

-- Visible enemy attack volumes (telegraphs + slash FX that have lit up).
local function enemyAttackY(npc)
	local atkMin, atkMax
	local function consider(p)
		if not p or not p:IsA('BasePart') then
			return
		end
		if p.Transparency >= 0.92 then
			return
		end
		local sx, sy, sz = p.Size.X, p.Size.Y, p.Size.Z
		if math.max(sx, sy, sz) < 1.5 then
			return
		end
		local y0 = p.Position.Y - sy * 0.5
		local y1 = p.Position.Y + sy * 0.5
		atkMin = atkMin and math.min(atkMin, y0) or y0
		atkMax = atkMax and math.max(atkMax, y1) or y1
	end
	local tel = npc:FindFirstChild('Telegraph_Root', true)
	if tel then
		consider(tel)
		for _, d in ipairs(tel:GetDescendants()) do
			consider(d)
		end
	end
	local hrp = npc:FindFirstChild('HumanoidRootPart')
	local fx = hrp and hrp:FindFirstChild('FX')
	if fx then
		for _, d in ipairs(fx:GetDescendants()) do
			consider(d)
		end
	end
	local holder = hrp and hrp:FindFirstChild('Holder')
	local hfx = holder and holder:FindFirstChild('FX')
	if hfx then
		for _, d in ipairs(hfx:GetDescendants()) do
			consider(d)
		end
	end
	return atkMin, atkMax
end

-- Hold station next to one enemy for the whole fight. The approach side is locked in
-- once here on purpose: the old code recomputed it from our own live position every
-- tick, which fed the previous write's error back into the next goal and made the
-- character oscillate around the enemy.
local function holdOnEnemy(npc)
	local myRoot = routeRoot()
	local part = enemyRoot(npc)
	local flat
	if part and myRoot then
		flat = Vector3.new(myRoot.Position.X - part.Position.X, 0, myRoot.Position.Z - part.Position.Z)
	end
	if not flat or flat.Magnitude < 0.1 then
		flat = Vector3.new(0, 0, 1)
	end
	local dir = flat.Unit
	local char = character()
	local hum = char and char:FindFirstChildOfClass('Humanoid')
	local rootPart = char and char:FindFirstChild('HumanoidRootPart')
	local hip = 3.5
	if hum and rootPart then
		hip = math.max(hip, (hum.HipHeight or 2) + rootPart.Size.Y * 0.5)
	end
	-- Floor Y only (no hover). Hover is added every tick so the slider can drop you
	-- into a pit / pack without recasting.
	local baseY
	if part then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { char, npc }
		params.IgnoreWater = true
		local hit = workspace:Raycast(part.Position + Vector3.new(0, 14, 0), Vector3.new(0, -80, 0), params)
		baseY = hit and (hit.Position.Y + hip) or part.Position.Y
	end
	local cachedOffY, cachedStand, cachedAt, cachedAim = 0, 5, 0, nil
	Pin.follow(function()
		local live = enemyRoot(npc)
		if not live then
			return nil
		end
		if os.clock() - (rt.aoeScanAt or 0) > 0.12 then
			rt.aoeScanAt = os.clock()
			pcall(rt.avoidFloorAoe)
		end
		-- Floor discs win over the boss stand pin for the whole telegraph lifetime.
		if typeof(rt.aoeGoal) == 'Vector3' and os.clock() < (rt.aoeUntil or 0) then
			return rt.aoeGoal
		end
		local now = os.clock()
		if now - cachedAt > 0.2 then
			cachedAt = now
		local stand = Options.DLFarmStand and tonumber(Options.DLFarmStand.Value) or 5
		local hover = Options.DLFarmHover and tonumber(Options.DLFarmHover.Value) or 0
		local autoLow = on('DLFarmAutoLow')
		local autoHigh = on('DLFarmAutoHigh')
		local y
		-- Special offset is the ice-dodge bury. Auto low/high must still apply
		-- or Scarlet Knight / Dark Professor sit 11.5 under the hurtbox and
		-- M1s never connect (ult never charges either).
		if enemyRank(npc) >= 4 and not autoLow and not autoHigh then
			local off = Options.DLFarmSpecialOff and tonumber(Options.DLFarmSpecialOff.Value) or -11.5
			y = live.Position.Y + off
		elseif autoLow or autoHigh then
			local hb = equippedHitboxSize()
			local halfH = math.clamp(hb.Y * 0.5, 3, 14)
			local eMin, eMax = enemyBodyY(npc, live)
			local margin = 1.25
			-- Floor bosses / tall packs: old under-ice bury. Fodder stays on the floor.
			local tall = (eMax - eMin) >= 12
			local bury = enemyRank(npc) >= 3 or tall
			local lowY = bury and (eMin - 7) or (baseY or (eMin - 1))
			local highY = eMax + halfH - margin
			if lowY > highY then
				local mid = (eMin + eMax) * 0.5
				lowY, highY = mid, mid
			end
			if autoHigh and autoLow then
				y = highY
				local aMin, aMax = enemyAttackY(npc)
				if aMin and aMax then
					local function overlaps(py)
						return py >= aMin - 1.5 and py <= aMax + 1.5
					end
					local hiHit, loHit = overlaps(highY), overlaps(lowY)
					if hiHit and not loHit then
						y = lowY
					elseif loHit and not hiHit then
						y = highY
					elseif hiHit and loHit then
						local mid = (aMin + aMax) * 0.5
						y = math.abs(highY - mid) >= math.abs(lowY - mid) and highY or lowY
					end
				end
			elseif autoHigh then
				y = highY
			else
				y = lowY
			end
			y += hover
		else
			y = (baseY or (live.Position.Y + hip)) + hover
		end
			cachedOffY = y - live.Position.Y
			cachedStand = stand
			cachedAim = nil
			-- Face the clump, not a stray on the edge. Same-room fodder within 22.
			if enemyRank(npc) < 3 then
				local sx, sz, n = live.Position.X, live.Position.Z, 1
				local room = Rooms.indexOf(npc)
				eachFarmNpc(function(other)
					if other == npc or not enemyAlive(other) or farmSkipped(other) then
						return
					end
					if enemyRank(other) >= 3 then
						return
					end
					local p = enemyRoot(other)
					if not p then
						return
					end
					if room and Rooms.indexOf(other) ~= room then
						return
					end
					if (p.Position - live.Position).Magnitude <= 22 then
						sx += p.Position.X
						sz += p.Position.Z
						n += 1
					end
				end)
				if n >= 2 then
					cachedAim = Vector3.new(sx / n, live.Position.Y, sz / n)
				end
			end
		end
		local y = live.Position.Y + cachedOffY
		local stand = cachedStand
		local aimAt = cachedAim or live.Position
		-- `dir` is locked at hold start. Live-position back orbited the pack.
		local goal = Vector3.new(aimAt.X, y, aimAt.Z) + Vector3.new(dir.X, 0, dir.Z) * stand
		local dungeon = activeDungeonRoot()
		if dungeon and Rooms.posInCorridor(dungeon, goal) then
			local idx = tonumber(rt.farmRoomFilter) or Rooms.indexOf(npc)
			if idx and not Rooms.isCorridor(dungeon, idx) then
				local zone = Rooms.zone(dungeon, idx)
				if zone then
					goal = Vector3.new(zone.Position.X, y, zone.Position.Z)
				end
			end
		end
		return goal, Vector3.new(aimAt.X, y, aimAt.Z)
	end)
end

local function farmKill(npc)
	local started = os.clock()
	local lastHp = enemyHealth(npc)
	local readable = lastHp ~= nil
	local sticky = enemyRank(npc) >= 3
	local timeout = (sticky or isBossEnemy(npc)) and FARM_BOSS_TIMEOUT or FARM_KILL_TIMEOUT
	local crystalPack = isRaidCrystal(npc)
	local addAnchor = nil
	local addPack = false
	if not crystalPack and isAwakeAdd(npc) then
		addAnchor = raidSpecialAnchor()
		if addAnchor and #listAddsNearSpecial(addAnchor) >= 2 then
			addPack = true
		end
	end
	if (tonumber(npc:GetAttribute('HealthOverride')) or 0) >= 1e7
		or isRaidBossNpc(npc)
		or (npc.Parent and npc.Parent.Name == 'BossRush_NPCs')
	then
		timeout = 1200
	elseif crystalPack then
		timeout = 90
		sticky = true
	elseif addPack then
		timeout = 120
		sticky = true
	end
	local lastDrop = started
	local lastHit = 0
	local dealt0 = tonumber(LocalPlayer:GetAttribute('Damage_Dealt')) or 0
	local hits0 = tonumber(LocalPlayer:GetAttribute('Hit_Count')) or 0
	-- Position is held on Heartbeat for the whole fight; this loop only swings and
	-- watches health, so its cadence no longer affects how smooth movement looks.
	rt.crystalPack = crystalPack == true
	rt.addPack = addPack == true
	if crystalPack then
		holdOnCrystalPack()
		farmLabel = ('crystals · %d'):format(#listRaidCrystals())
	elseif addPack then
		holdOnAddPack(addAnchor)
		farmLabel = ('adds · %d'):format(#listAddsNearSpecial(addAnchor))
	else
		holdOnEnemy(npc)
	end
	pcall(watchEnemy, npc)
	rt.farmFightNpc = npc
	rt.farmFighting = true
	local function packAlive()
		if crystalPack then
			return #listRaidCrystals() > 0
		end
		if addPack then
			return #listAddsNearSpecial(addAnchor) > 0
		end
		return enemyAlive(npc)
	end
	while farmActive() and packAlive() and not routeBusy do
		local now = os.clock()
		if rt.refillUrgent or rt.refillBusy then
			farmLabel = 'potion refill'
			break
		end
		if now - started > timeout then
			if not sticky then
				farmBan[npc] = os.clock() + 120
				farmLabel = ('skip · %s'):format(npc.Name)
			end
			break
		end
		local myPct = rt.hpPct()
		pcall(autoPotionTick)
		if myPct <= 0 then
			farmLabel = 'waiting · dead'
			runCompleteAt = runCompleteAt or os.clock()
			break
		elseif (on('DLAutoPotion') or on('DLAutoFlee')) and rt.updateHealWait(myPct) then
			farmLabel = ('heal · %d%% / %d%%'):format(math.floor(myPct + 0.5), rt.healResume())
			if on('DLAutoFlee') and type(rt.fleeNow) == 'function' then
				task.spawn(rt.fleeNow, true)
			end
			break
		end
		local myRoot = routeRoot()
		if not myRoot then
			task.wait(0.15)
		else
			if crystalPack then
				farmLabel = ('crystals · %d'):format(#listRaidCrystals())
			elseif addPack then
				-- Crystals still beat adds — break out so pickFarmTarget can swap.
				local crystal = select(1, nearestCrystal())
				if crystal then
					farmLabel = ('crystal · %s'):format(crystal.Name)
					break
				end
				farmLabel = ('adds · %d'):format(#listAddsNearSpecial(addAnchor))
			elseif (isRaidBossNpc(npc) or enemyRank(npc) >= 4) and now - (rt.addScanAt or 0) > 0.25 then
				-- Crystals wipe the raid if they finish. Adds after that. Then the boss.
				rt.addScanAt = now
				local crystal = select(1, nearestCrystal())
				if crystal and crystal ~= npc then
					farmLabel = ('crystal · %s'):format(crystal.Name)
					if farmLock == npc then
						farmLock = nil
					end
					break
				end
				local add = select(1, addsNearSpecial(npc))
				if add then
					farmLabel = ('adds · %s'):format(add.Name)
					if farmLock == npc then
						farmLock = nil
					end
					break
				end
			end
			if now - lastHit >= attackDelay() then
				lastHit = now
				local me = character()
				if not (me and me:GetAttribute('SkillIFrame') == true) then
					pcall(fireAttack)
				end
			end
			-- Stall detection needs a readable HP bar; a boss without one only gets
			-- the timeout above. Specials / minis are never stall-abandoned — that
			-- was warping onto nearby fodder mid-phase.
			if readable and not sticky and not crystalPack and not addPack then
				local hp = enemyHealth(npc)
				if hp and hp < lastHp - 0.5 then
					lastHp = hp
					lastDrop = now
				elseif now - started > FARM_STALL_TIMEOUT and now - lastDrop > FARM_STALL_TIMEOUT then
					farmBan[npc] = os.clock() + 120
					farmLabel = ('skip · %s'):format(npc.Name)
					break
				end
			elseif not readable and not sticky and not crystalPack and not addPack then
				-- HealthOverride fodder has no HP bar. HitReact still ticks on
				-- their own swings, so stall must watch OUR damage, not theirs.
				local stallFor = 6
				local dealt = tonumber(LocalPlayer:GetAttribute('Damage_Dealt')) or 0
				local hits = tonumber(LocalPlayer:GetAttribute('Hit_Count')) or 0
				if dealt > dealt0 + 0.5 or hits > hits0 then
					dealt0 = math.max(dealt0, dealt)
					hits0 = math.max(hits0, hits)
					lastDrop = now
				elseif now - started > stallFor and now - lastDrop > stallFor then
					farmBan[npc] = os.clock() + 120
					farmLabel = ('skip · %s'):format(npc.Name)
					break
				end
			end
			task.wait(0.05)
		end
	end
	rt.farmFighting = false
	rt.farmFightNpc = nil
	rt.crystalPack = false
	rt.addPack = false
	-- Stay put after a kill. Do not re-pin onto the pack after a heal break —
	-- that yanked flee back into the boss.
	if not rt.healWait then
		Pin.station()
	end
	if crystalPack then
		if #listRaidCrystals() == 0 then
			farmKills += 1
		end
	elseif addPack then
		if #listAddsNearSpecial(addAnchor) == 0 then
			farmKills += 1
		end
	elseif farmBan[npc] and os.clock() < farmBan[npc] then
		if farmLock == npc then
			farmLock = nil
		end
	elseif not enemyAlive(npc) then
		farmKills += 1
		if farmLock == npc then
			farmLock = nil
		end
		farmFinished[npc] = os.clock() + FARM_FINISHED_COOLDOWN
		if on('DLHuntSpecial') and isHuntTarget(npc) and type(rt.requestHuntReturn) == 'function' then
			pcall(rt.requestHuntReturn)
		end
	elseif not sticky then
		farmFinished[npc] = os.clock() + FARM_FINISHED_COOLDOWN
	end
end

local function findLiveSpecial()
	local best, bestD = nil, 9e9
	eachFarmNpc(function(npc)
		if not enemyAlive(npc) or farmSkipped(npc) or isFinalBoss(npc) then
			return
		end
		local special = enemyRank(npc) >= 4
			or npc:GetAttribute('IsSpecial') == true
			or npc:GetAttribute('IsSpecialBoss') == true
		if not special then
			return
		end
		local part = enemyRoot(npc)
		if not part then
			return
		end
		local me = routeRoot()
		local d = me and (part.Position - me.Position).Magnitude or 0
		if d < bestD then
			best, bestD = npc, d
		end
	end)
	return best
end

local function findFloorBoss()
	local best
	eachFarmNpc(function(npc)
		if not enemyAlive(npc) or farmSkipped(npc) or not isFinalBoss(npc) then
			return
		end
		if not enemyRoot(npc) then
			return
		end
		best = npc
	end)
	return best
end

local SWEEP_MARK = '_DLSweep'
local sweepMarks = {}

local function clearSweepMark(idx)
	local m = sweepMarks[idx]
	if not m then
		return
	end
	sweepMarks[idx] = nil
	pcall(function()
		if m.adorn then
			m.adorn:Destroy()
		end
	end)
	pcall(function()
		if m.hl then
			m.hl:Destroy()
		end
	end)
	pcall(function()
		if m.bb then
			m.bb:Destroy()
		end
	end)
end

local function clearAllSweepMarks()
	for idx in pairs(sweepMarks) do
		clearSweepMark(idx)
	end
end

local function roomPosKey(dungeon, idx)
	local zone = dungeon and Rooms.zone(dungeon, idx)
	if not zone then
		return nil
	end
	local p = zone.Position
	return string.format('z:%.0f:%.0f:%.0f', p.X, p.Y, p.Z)
end

local function markRoomSwept(dungeon, idx)
	if not idx then
		return
	end
	rt.roomSweepDone = rt.roomSweepDone or {}
	rt.roomSweepDone[idx] = true
	local key = roomPosKey(dungeon, idx)
	if key then
		rt.roomSweepDonePos = rt.roomSweepDonePos or {}
		rt.roomSweepDonePos[key] = true
	end
	clearSweepMark(idx)
end

local function roomIsSwept(dungeon, idx)
	if not idx then
		return false
	end
	if rt.roomSweepDone and rt.roomSweepDone[idx] then
		return true
	end
	local key = roomPosKey(dungeon, idx)
	return key ~= nil and rt.roomSweepDonePos and rt.roomSweepDonePos[key] == true
end

local function chestBelongsToRoom(dungeon, idx, model)
	if not model or not idx then
		return false
	end
	if tonumber(model:GetAttribute('RoomIndex')) == idx then
		return true
	end
	local pos = chestStandPos(model)
	return pos ~= nil and Rooms.posInRoom(dungeon, idx, pos)
end

local function roomHasPendingChest(dungeon, idx)
	if not dungeon or not idx then
		return false
	end
	for _, child in ipairs(dungeon:GetChildren()) do
		if child:GetAttribute('DungeonChest') == true or child.Name:sub(1, 13) == 'DungeonChest' then
			if chestBelongsToRoom(dungeon, idx, child) then
				if chestIsClaimed(child) then
					markChestDone(child)
					continue
				end
				if child:GetAttribute('LockedRoom') == true and not wantOpenGates() then
					local p = chestPrompt(child)
					if not (p and p.Enabled == true) then
						continue
					end
				end
				return true
			end
		end
	end
	return false
end

local function roomHasPendingGate(dungeon, idx)
	if not dungeon or not idx or not wantOpenGates() then
		return false
	end
	for _, child in ipairs(dungeon:GetChildren()) do
		if child.Name:sub(1, 7) == 'Locked_' then
			if tonumber(child:GetAttribute('ParentRoomIndex')) == idx then
				local p = child:FindFirstChildWhichIsA('ProximityPrompt', true)
				if p and p.Enabled == true then
					local blob = (tostring(p.ActionText) .. ' ' .. tostring(p.ObjectText)):lower()
					if blob:find('key', 1, true) or blob:find('unlock', 1, true) then
						return true
					end
				end
			end
		end
	end
	return false
end

local function roomSweepComplete(dungeon, idx)
	if not dungeon or not idx then
		return false
	end
	if Rooms.aliveCount(dungeon, idx) > 0 then
		return false
	end
	if roomHasPendingChest(dungeon, idx) then
		return false
	end
	if roomHasPendingGate(dungeon, idx) then
		return false
	end
	return true
end

-- Halls, claimed shrine pads, and empty checkpoints are not rooms to sweep.
local function skipTourRoom(dungeon, idx)
	if not dungeon or not idx then
		return nil
	end
	if Rooms.isCorridor(dungeon, idx) then
		return 'hall'
	end
	if roomIsSwept(dungeon, idx) then
		return 'done'
	end
	if type(rt.shrineRoomDone) == 'function' and rt.shrineRoomDone(dungeon, idx) then
		return 'shrine'
	end
	local room = dungeon:FindFirstChild('Room_' .. tostring(idx))
	if room and room:GetAttribute('IsCheckpoint') == true
		and Rooms.aliveCount(dungeon, idx) <= 0
		and not roomHasPendingChest(dungeon, idx)
		and not roomHasPendingGate(dungeon, idx)
	then
		return 'checkpoint'
	end
	return nil
end

local function sweepKindColor(dungeon, idx)
	if Rooms.isBossRoom(dungeon, idx) then
		return Color3.fromRGB(255, 72, 118)
	end
	local room = dungeon and dungeon:FindFirstChild('Room_' .. tostring(idx))
	if room and room:GetAttribute('IsLootRoom') == true then
		return Color3.fromRGB(255, 196, 64)
	end
	if room and room:GetAttribute('IsCheckpoint') == true then
		return Color3.fromRGB(86, 214, 141)
	end
	return Color3.fromRGB(72, 168, 255)
end

local function sweepMarksOn()
	if LocalPlayer:GetAttribute('InDungeon') == true or farmBusy then
		return true
	end
	local t = Toggles and Toggles.DLSweepMarks
	if t == nil then
		return true
	end
	return t.Value == true
end

local function ensureSweepMark(dungeon, idx)
	local room = dungeon and dungeon:FindFirstChild('Room_' .. tostring(idx))
	if not room then
		clearSweepMark(idx)
		return
	end
	local color = sweepKindColor(dungeon, idx)
	local zone = room:FindFirstChild('Zone')
	local adornee = (zone and zone:IsA('BasePart')) and zone
		or room:FindFirstChild('TileAnchor')
		or room:FindFirstChildWhichIsA('BasePart', true)
	if not adornee then
		clearSweepMark(idx)
		return
	end
	local m = sweepMarks[idx]
	if not m or not m.hl or not m.hl.Parent then
		clearSweepMark(idx)
		local box = Instance.new('SelectionBox')
		box.Name = SWEEP_MARK
		box.Adornee = adornee
		box.Color3 = color
		box.SurfaceColor3 = color
		box.LineThickness = 0.18
		box.SurfaceTransparency = 0.45
		box.Parent = adornee
		local adorn = Instance.new('BoxHandleAdornment')
		adorn.Name = SWEEP_MARK
		adorn.Adornee = adornee
		adorn.AlwaysOnTop = true
		adorn.ZIndex = 10
		adorn.Size = adornee.Size
		adorn.Color3 = color
		adorn.Transparency = 0.62
		adorn.Parent = adornee
		local bb = Instance.new('BillboardGui')
		bb.Name = SWEEP_MARK
		bb.AlwaysOnTop = true
		bb.Size = UDim2.fromOffset(140, 140)
		bb.StudsOffset = Vector3.new(0, math.max(12, adornee.Size.Y * 0.35), 0)
		bb.MaxDistance = 8000
		bb.Adornee = adornee
		bb.Parent = adornee
		local lab = Instance.new('TextLabel')
		lab.BackgroundTransparency = 0.05
		lab.BackgroundColor3 = Color3.fromRGB(8, 10, 16)
		lab.Size = UDim2.fromScale(1, 1)
		lab.Font = Enum.Font.SourceSansBold
		lab.TextScaled = true
		lab.Text = tostring(idx)
		lab.TextColor3 = color
		lab.TextStrokeTransparency = 0.1
		lab.Parent = bb
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0.2, 0)
		corner.Parent = lab
		m = { hl = box, bb = bb, lab = lab, adorn = adorn }
		sweepMarks[idx] = m
	end
	m.hl.Color3 = color
	m.hl.SurfaceColor3 = color
	m.hl.Adornee = adornee
	if m.adorn then
		m.adorn.Color3 = color
		m.adorn.Adornee = adornee
		m.adorn.Size = adornee.Size
	end
	m.bb.Adornee = adornee
	m.lab.Text = tostring(idx)
	m.lab.TextColor3 = color
end

local function tickRoomSweepMarks()
	if not sweepMarksOn() then
		clearAllSweepMarks()
		return
	end
	local dungeon = activeDungeonRoot()
	if not dungeon then
		clearAllSweepMarks()
		return
	end
	local maxR = Rooms.maxRoom(dungeon)
	local keep = {}
	for i = 1, maxR do
		local ok, why = pcall(skipTourRoom, dungeon, i)
		if ok and why then
			clearSweepMark(i)
		else
			keep[i] = true
			pcall(ensureSweepMark, dungeon, i)
		end
	end
	for idx in pairs(sweepMarks) do
		if not keep[idx] then
			clearSweepMark(idx)
		end
	end
end

local function farmKillNpc(npc)
	if not npc then
		return
	end
	farmLabel = ('%s · %d kills'):format(npc.Name, farmKills)
	Rooms.markVisited(Rooms.indexOf(npc))
	if npc:GetAttribute('IsDormant') == true then
		farmLabel = ('wake %s'):format(npc.Name)
		wakeTarget(npc)
	else
		local okKill, errKill = pcall(farmKill, npc)
		if not okKill then
			farmFinished[npc] = os.clock() + 2
			Library:Notify('Farm skip: ' .. tostring(errKill))
		end
	end
end

-- Room_1→N once: wait 1s (cut short if THIS room wakes), hover-kill, gate, chests.
local function tourFarmRooms(dungeon)
	if inBossRushFarm() and not dungeon then
		farmLabel = 'boss rush · waiting'
		task.wait(0.25)
		return
	end
	if not dungeon then
		farmLabel = ('idle · %d kills'):format(farmKills)
		task.wait(0.25)
		return
	end
	pcall(tickRoomSweepMarks)
	local dname = dungeon.Name
	if dname and rt.farmDungeonId ~= dname then
		rt.farmDungeonId = dname
		-- Tile re-parent can rename Generated_ without a new floor. Keep the
		-- sweep so we do not walk already-cleared rooms from 1 again.
		if not (rt.roomSweepDone and next(rt.roomSweepDone)) then
			rt.farmRoomIdx = 1
			rt.farmRoomPhase = 'wait'
			rt.farmRoomFilter = nil
		end
	end
	local maxRoom = Rooms.maxRoom(dungeon)
	local idx = tonumber(rt.farmRoomIdx) or 1
	if maxRoom < 1 then
		farmLabel = ('idle · %d kills'):format(farmKills)
		task.wait(0.25)
		return
	end
	if idx > maxRoom then
		rt.farmRoomFilter = nil
		local boss = findFloorBoss()
		if boss then
			farmKillNpc(boss)
			return
		end
		local leftover = pickFarmTarget()
		if leftover then
			farmKillNpc(leftover)
			return
		end
		farmLabel = ('idle · %d kills'):format(farmKills)
		task.wait(0.25)
		return
	end
	while idx <= maxRoom do
		local why = skipTourRoom(dungeon, idx)
		if not why then
			break
		end
		if why == 'hall' then
			farmLabel = ('skip hall Room_%d'):format(idx)
		elseif why == 'shrine' or why == 'checkpoint' then
			farmLabel = ('skip %s Room_%d'):format(why, idx)
			clearSweepMark(idx)
		else
			farmLabel = ('done Room_%d'):format(idx)
		end
		idx += 1
		rt.farmRoomIdx = idx
		rt.farmRoomPhase = 'wait'
		rt.farmRoomFilter = nil
	end
	if idx > maxRoom then
		return
	end
	local phase = rt.farmRoomPhase or 'wait'
	local roomModel = dungeon:FindFirstChild('Room_' .. tostring(idx))
	if roomModel and roomModel:GetAttribute('IsLootRoom') == true and Rooms.aliveCount(dungeon, idx) <= 0 then
		phase = 'loot'
		rt.farmRoomPhase = 'loot'
	end
	rt.farmRoomFilter = idx
	if phase == 'wait' then
		farmLabel = ('Room_%d · wait'):format(idx)
		local model = dungeon:FindFirstChild('Room_' .. tostring(idx))
		if not model or not Rooms.zone(dungeon, idx) then
			farmLabel = ('Room_%d · load'):format(idx)
			-- Do not pushForward to a neighboring streamed room — that was a
			-- ~100-stud snap every few seconds (the load-phase stutter).
			if model then
				local ok, pivot = pcall(function()
					return model:GetPivot().Position
				end)
				if ok and typeof(pivot) == 'Vector3' then
					local stand = standingSpot(pivot, 0)
					local here = routeRoot()
					if not here or (here.Position - stand).Magnitude > 8 then
						Pin.at(stand, true)
					end
				end
			end
			task.wait(0.35)
			return
		end
		local spawned = Rooms.holdRoom(dungeon, idx, 1)
		if spawned or Rooms.aliveCount(dungeon, idx) > 0 then
			rt.farmRoomPhase = 'fight'
		else
			rt.farmRoomPhase = 'loot'
		end
		return
	end
	if phase == 'fight' then
		if Rooms.aliveCount(dungeon, idx) <= 0 then
			rt.farmRoomPhase = 'loot'
			return
		end
		local target = pickFarmTarget()
		if not target then
			rt.farmRoomPhase = 'loot'
			return
		end
		farmLabel = ('Room_%d · %s'):format(idx, target.Name)
		farmKillNpc(target)
		if Rooms.aliveCount(dungeon, idx) <= 0 then
			rt.farmRoomPhase = 'loot'
		end
		return
	end
	if Rooms.aliveCount(dungeon, idx) > 0 then
		rt.farmRoomPhase = 'fight'
		return
	end
	farmLabel = ('Room_%d · loot'):format(idx)
	if wantOpenGates() then
		local opened = false
		pcall(function()
			opened = KeyDoor.unlockForRoom(idx) == true
		end)
		if opened then
			rt.chestRoomOpen = rt.chestRoomOpen or {}
			rt.chestRoomOpen[idx] = true
		end
	end
	if roomHasPendingChest(dungeon, idx) or on('DLChestAnywhere') then
		pcall(lootClearedRoom, idx, dungeon)
	end
	if roomSweepComplete(dungeon, idx) then
		markRoomSwept(dungeon, idx)
		rt.farmRoomIdx = idx + 1
		rt.farmRoomPhase = 'wait'
		rt.farmRoomFilter = nil
	else
		rt.farmRoomPhase = 'loot'
	end
end

local function farmLoop()
	local root = routeRoot()
	farmHome = root and root.CFrame or nil
	local wasNoclip = noclipOn
	farmBusy = true
	noclipOn = true
	pcall(setCharNoclip, true)
	while currentInstance() and on('DLAutoFarm') and inDungeonFarm() do
		pcall(setCharNoclip, true)
		noclipOn = true
		local aliveChar = character()
		local aliveHum = aliveChar and aliveChar:FindFirstChildOfClass('Humanoid')
		if not aliveHum or rt.hpPct() <= 0 then
			-- Stay in the loop across death so Return-on-stop does not yank home.
			farmLabel = 'waiting · respawn'
			if LocalPlayer:GetAttribute('InDungeon') == true then
				runCompleteAt = runCompleteAt or os.clock()
			end
			task.wait(0.45)
		elseif (rt.refillBusy or rt.refillUrgent) and not rt.clearRefillHold() then
			farmLabel = 'potion refill'
			task.wait(0.2)
		elseif routeBusy then
			farmLabel = 'paused · route'
			task.wait(0.3)
		elseif os.clock() < (rt.combatHold or 0) then
			farmLabel = 'waiting · recover'
			task.wait(0.35)
		else
			-- Stay out until HP is over the resume slider, not just the drink trigger.
			local pct = rt.hpPct()
			if (on('DLAutoPotion') or on('DLAutoFlee')) and rt.updateHealWait(pct) then
				farmLabel = ('waiting · %d%% / %d%%'):format(math.floor(pct + 0.5), rt.healResume())
				pcall(autoPotionTick)
				if on('DLAutoFlee') and type(rt.fleeNow) == 'function' then
					task.spawn(rt.fleeNow, true)
				end
				task.wait(0.4)
			else
			local blessHold = false
			pcall(function()
				if type(rt.blessFarmPriority) == 'function' then
					blessHold = rt.blessFarmPriority() == true
				end
			end)
			if blessHold then
				task.wait(0.2)
			else
				local aoeOk, aoeHit = pcall(rt.avoidFloorAoe)
				if aoeOk and aoeHit and typeof(rt.aoeGoal) == 'Vector3' then
					farmLabel = 'aoe gap'
					Pin.at(rt.aoeGoal, true)
				end
				local dungeon = activeDungeonRoot()
				local specialNpc = findLiveSpecial()
				if specialNpc then
					rt.farmRoomFilter = nil
					farmKillNpc(specialNpc)
				else
					tourFarmRooms(dungeon)
				end
			end
			end
		end
	end
	farmBusy = false
	farmLabel = nil
	-- Reload stole this copy's epoch so the new farm can take over. Do not
	-- drop noclip / pin / Return-on-stop or the character lands on the floor.
	if not currentInstance() or getgenv().DLResumeFarm then
		return
	end
	-- Release the pin only after farmBusy is false (stop() stations while farming).
	Pin.stop()
	pcall(function()
		local char = character()
		local hum = char and char:FindFirstChildOfClass('Humanoid')
		if hum then
			hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
		end
	end)
	-- Go home while still noclipped. Restoring collision first lets the rig land
	-- wedged in whatever geometry is at the home spot, which reads as being frozen.
	-- Only when the user turned the toggle off (still in dungeon) — never on death.
	local live = routeRoot()
	if live and farmHome and on('DLFarmReturn') and LocalPlayer:GetAttribute('InDungeon') == true then
		pcall(function()
			live.CFrame = farmHome
			live.AssemblyLinearVelocity = Vector3.zero
			live.AssemblyAngularVelocity = Vector3.zero
		end)
		task.wait(0.2)
	end
	if not wasNoclip then
		noclipOn = false
		pcall(setCharNoclip, false)
		pcall(fixMovement)
	end
end

local function startFarm()
	if farmThread then
		return
	end
	if not rt.farmStarted then
		farmKills = 0
		farmFinished = {}
		farmBan = {}
		farmLock = nil
		pcall(Rooms.reset)
		rt.farmStarted = true
		rt.farmChestSwept = false
		rt.bossSweepDone = false
		rt.chestFast = false
		rt.chestRoomTried = {}
		rt.chestRoomOpen = {}
		rt.specialNext = 0
	end
	farmThread = task.spawn(function()
		local ok, err = pcall(farmLoop)
		farmBusy = false
		farmLabel = nil
		farmThread = nil
		if not ok then
			Library:Notify('Auto farm stopped: ' .. tostring(err))
		end
	end)
end

-- Watchdog: if the farm thread dies while the toggle is still on, bring it back.
local function autoFarmTick()
	if on('DLAutoFarm') then
		if not farmThread then
			startFarm()
		end
	end
end

local function listClassNames()
	local names = {}
	local folder = game:GetService('ReplicatedStorage'):FindFirstChild('Classes')
	if folder then
		for _, c in ipairs(folder:GetChildren()) do
			if c:IsA('Folder') then
				names[#names + 1] = c.Name
			end
		end
	end
	table.sort(names)
	return names
end

local function currentClassName()
	return tostring(LocalPlayer:GetAttribute('Current_Class') or LocalPlayer:GetAttribute('Active_Class') or '')
end

local function wantedRollClasses()
	local v = Options.DLRollClasses and Options.DLRollClasses.Value
	local map = {}
	if type(v) == 'table' then
		for k, val in pairs(v) do
			if type(k) == 'string' and val == true then
				map[k] = true
			elseif type(val) == 'string' then
				map[val] = true
			end
		end
	elseif type(v) == 'string' and v ~= '' then
		map[v] = true
	end
	return map
end

local function classDataMod()
	if rt.classData == false then
		return nil
	end
	if rt.classData then
		return rt.classData
	end
	local folder = game:GetService('ReplicatedStorage'):FindFirstChild('Classes')
	local mod = folder and folder:FindFirstChild('Class_Data')
	if not mod then
		rt.classData = false
		return nil
	end
	local ok, data = pcall(require, mod)
	if ok and type(data) == 'table' then
		rt.classData = data
		return data
	end
	rt.classData = false
	return nil
end

local function classRarity(name)
	if type(name) ~= 'string' or name == '' then
		return nil
	end
	local data = classDataMod()
	if data and type(data.GetRarity) == 'function' then
		local ok, rar = pcall(data.GetRarity, name)
		if (not ok or type(rar) ~= 'string') and data.GetRarity then
			ok, rar = pcall(function()
				return data:GetRarity(name)
			end)
		end
		if ok and type(rar) == 'string' and rar ~= '' then
			return rar
		end
	end
	return nil
end

local function isExoticClass(name)
	local rar = string.lower(tostring(classRarity(name) or ''))
	return rar == 'exotic'
end

local function classIsWanted(name)
	if type(name) ~= 'string' or name == '' or name == '?' then
		return false
	end
	if on('DLStopExotic') and isExoticClass(name) then
		return true
	end
	local map = wantedRollClasses()
	if map[name] then
		return true
	end
	local low = string.lower(name)
	for k in pairs(map) do
		if string.lower(k) == low then
			return true
		end
	end
	return false
end

local function findKnitServices()
	local now = os.clock()
	if rt.knitList and now - (rt.knitListAt or 0) < 45 then
		return rt.knitList
	end
	local list = {}
	local packages = game:GetService('ReplicatedStorage'):FindFirstChild('Packages')
	local index = packages and packages:FindFirstChild('_Index')
	if not index then
		rt.knitList, rt.knitListAt = list, now
		return list
	end
	for _, pack in ipairs(index:GetChildren()) do
		local services = pack:FindFirstChild('knit') and pack.knit:FindFirstChild('Services')
		if services then
			for _, s in ipairs(services:GetChildren()) do
				list[#list + 1] = s
			end
		end
	end
	rt.knitList, rt.knitListAt = list, now
	return list
end

-- Class spins: SummoningService.Spin('Normal'|'Lucky'). Skip the reveal UI so
-- we can chain spins as fast as the server accepts.
local function summoningRF(name)
	for _, svc in ipairs(findKnitServices()) do
		if svc.Name == 'SummoningService' then
			local folder = svc:FindFirstChild('RF')
			local rem = folder and folder:FindFirstChild(name)
			if rem and rem:IsA('RemoteFunction') then
				return rem
			end
		end
	end
	return nil
end

local function findRollRemote()
	if rollRF and rollRF.Parent then
		return rollRF
	end
	rollRF = summoningRF('Spin')
	rollRFLabel = rollRF and 'SummoningService.Spin' or nil
	return rollRF
end

local function getSpinCounts()
	local rf = summoningRF('GetSpinCounts')
	if not rf then
		return { Normal = 0, Lucky = 0 }
	end
	local ok, res = pcall(function()
		return rf:InvokeServer()
	end)
	if ok and type(res) == 'table' then
		return {
			Normal = tonumber(res.Normal) or 0,
			Lucky = tonumber(res.Lucky) or 0,
		}
	end
	return { Normal = 0, Lucky = 0 }
end

local function pickSpinKind(counts)
	local mode = Options.DLSpinMode and tostring(Options.DLSpinMode.Value) or 'Lucky first'
	local n = counts and counts.Normal or 0
	local l = counts and counts.Lucky or 0
	if mode == 'Lucky only' then
		return l > 0 and 'Lucky' or nil
	end
	if mode == 'Normal only' then
		return n > 0 and 'Normal' or nil
	end
	-- Lucky first (default)
	if l > 0 then
		return 'Lucky'
	end
	if n > 0 then
		return 'Normal'
	end
	return nil
end

local function parseRolledClass(result)
	if type(result) == 'string' and result ~= '' then
		return result
	end
	if type(result) == 'table' then
		for _, key in ipairs({
			'Class', 'class', 'Name', 'name', 'ClassName', 'Hero', 'Result',
			'RolledClass', 'NewClass', 'Chosen',
		}) do
			if type(result[key]) == 'string' and result[key] ~= '' then
				return result[key], result.Rarity or result.rarity
			end
		end
		-- Nested { Class = { Name = ... } } shapes.
		for _, key in ipairs({ 'Class', 'class', 'Result', 'Data' }) do
			local inner = result[key]
			if type(inner) == 'table' then
				for _, k2 in ipairs({ 'Name', 'name', 'ClassName', 'Id', 'id' }) do
					if type(inner[k2]) == 'string' and inner[k2] ~= '' then
						return inner[k2]
					end
				end
			end
		end
	end
	return currentClassName()
end

local function skipSpinAnim()
	local pg = LocalPlayer:FindFirstChild('PlayerGui')
	local top = pg and pg:FindFirstChild('TopLevel')
	local sum = top and top:FindFirstChild('Summoning')
	if not sum then
		return
	end
	pcall(function()
		sum.Visible = false
	end)
	local skip = sum:FindFirstChild('Skip', true)
	if not skip then
		return
	end
	if type(getconnections) == 'function' then
		pcall(function()
			for _, c in ipairs(getconnections(skip.MouseButton1Click)) do
				if c.Fire then
					c:Fire()
				elseif c.Function then
					c.Function()
				end
			end
		end)
	end
	if type(firesignal) == 'function' then
		pcall(firesignal, skip.MouseButton1Click)
	end
	pcall(function()
		skip:Activate()
	end)
end

local function fireRoll(kind)
	local rem = findRollRemote()
	if not rem then
		return false, nil
	end
	kind = kind or 'Normal'
	local ok, result = pcall(function()
		return rem:InvokeServer(kind)
	end)
	if not ok then
		ok, result = pcall(function()
			return rem:InvokeServer(kind, true)
		end)
	end
	if not ok then
		ok, result = pcall(function()
			return rem:InvokeServer({ Type = kind, Skip = true })
		end)
	end
	return ok, result
end

local function stopAutoRoll(reason)
	if Toggles.DLAutoRoll and Toggles.DLAutoRoll.Value == true then
		Toggles.DLAutoRoll:SetValue(false)
	end
	if reason then
		Library:Notify(reason, 6)
	end
end

local function autoRollTick()
	if not on('DLAutoRoll') or rollBusy then
		return
	end
	if LocalPlayer:GetAttribute('InDungeon') == true or LocalPlayer:GetAttribute('DungeonRun') == true then
		return
	end
	local wanted = wantedRollClasses()
	if not next(wanted) and not on('DLStopExotic') then
		stopAutoRoll('Pick stop-on classes first (or enable Stop on Exotic)')
		return
	end
	if classIsWanted(currentClassName()) then
		local cur = currentClassName()
		local rar = classRarity(cur)
		stopAutoRoll(rar and ('Hit %s [%s]'):format(cur, rar) or ('Hit ' .. cur))
		return
	end
	if not findRollRemote() then
		stopAutoRoll('SummoningService.Spin not found')
		return
	end
	rollBusy = true
	lastRollAt = os.clock()
	task.spawn(function()
		local fails = 0
		while on('DLAutoRoll') and currentInstance() do
			if LocalPlayer:GetAttribute('InDungeon') == true then
				break
			end
			if classIsWanted(currentClassName()) then
				local cur = currentClassName()
				local rar = classRarity(cur)
				stopAutoRoll(rar and ('Hit %s [%s]'):format(cur, rar) or ('Hit ' .. cur))
				break
			end
			local counts = getSpinCounts()
			local kind = pickSpinKind(counts)
			if not kind then
				stopAutoRoll(('Out of spins (N=%d L=%d)'):format(counts.Normal, counts.Lucky))
				break
			end
			lastRollAt = os.clock()
			local ok, result = fireRoll(kind)
			-- Skip reveal immediately so the next InvokeServer is not blocked by UI.
			for _ = 1, 4 do
				skipSpinAnim()
				task.wait()
			end
			local got = parseRolledClass(result)
			if classIsWanted(got) or classIsWanted(currentClassName()) then
				local hit = classIsWanted(got) and got or currentClassName()
				local rar = classRarity(hit)
				stopAutoRoll(rar and ('Hit %s [%s]'):format(hit, rar) or ('Hit ' .. hit))
				break
			end
			if not ok then
				fails += 1
				if fails >= 3 then
					stopAutoRoll('Spin failed — try lobby / Summoning UI')
					break
				end
				task.wait(0.15)
			else
				fails = 0
			end
			-- Yield one frame only — animation is skipped client-side.
			task.wait()
		end
		rollBusy = false
	end)
end

local function findCodesService()
	local packages = game:GetService('ReplicatedStorage'):FindFirstChild('Packages')
	local index = packages and packages:FindFirstChild('_Index')
	if not index then
		return nil
	end
	for _, pack in ipairs(index:GetChildren()) do
		local services = pack:FindFirstChild('knit') and pack.knit:FindFirstChild('Services')
		local svc = services and services:FindFirstChild('CodesService')
		if svc then
			return svc
		end
	end
	return nil
end

local function listRedeemCodes()
	local seen = {}
	local names = {}
	local function add(code)
		if type(code) ~= 'string' or code == '' or seen[code] then
			return
		end
		seen[code] = true
		names[#names + 1] = code
	end
	local folder = game:GetService('ReplicatedStorage'):FindFirstChild('GameInfo')
	local mod = folder and folder:FindFirstChild('CodesData')
	if mod and mod:IsA('ModuleScript') then
		local ok, data = pcall(require, mod)
		if ok and type(data) == 'table' and type(data.Codes) == 'table' then
			for name, info in pairs(data.Codes) do
				if type(info) == 'table' and info.Active == true and type(info.RequiresRole) ~= 'string' then
					add(tostring(name))
				end
			end
		end
	end
	for _, code in ipairs(EXTRA_CODES) do
		add(code)
	end
	table.sort(names)
	return names
end

local function summarizeRedeem(result)
	if result == true then
		return 'claimed'
	end
	if result == false or result == nil then
		return 'failed'
	end
	if type(result) == 'string' then
		local low = string.lower(result)
		if low:find('already') or low:find('redeemed') or low:find('claimed') then
			return 'already'
		end
		if low:find('expir') or low:find('invalid') or low:find('unknown') then
			return 'expired'
		end
		if low:find('group') then
			return 'group'
		end
		if low:find('success') or low:find('reward') then
			return 'claimed'
		end
		return result
	end
	if type(result) == 'table' then
		if result.success == true or result.Success == true or result.ok == true then
			return 'claimed'
		end
		local msg = result.message or result.Message or result.error or result.Error
		if type(msg) == 'string' then
			return summarizeRedeem(msg)
		end
	end
	return tostring(result):sub(1, 40)
end

local redeemBusy = false
local function redeemAllCodes()
	if redeemBusy then
		Library:Notify('Codes already running')
		return
	end
	local svc = findCodesService()
	local rf = svc and svc:FindFirstChild('RF') and svc.RF:FindFirstChild('RedeemCode')
	if not rf or not rf:IsA('RemoteFunction') then
		Library:Notify('CodesService missing')
		return
	end
	local codes = listRedeemCodes()
	if #codes == 0 then
		Library:Notify('No codes found')
		return
	end
	redeemBusy = true
	Library:Notify(('Redeeming %s codes…'):format(#codes))
	task.spawn(function()
		local claimed, already, expired, failed, group = 0, 0, 0, 0, 0
		for i, code in ipairs(codes) do
			local ok, result = pcall(function()
				return rf:InvokeServer(code)
			end)
			local tag = ok and summarizeRedeem(result) or 'error'
			if tag == 'claimed' then
				claimed += 1
			elseif tag == 'already' then
				already += 1
			elseif tag == 'expired' then
				expired += 1
			elseif tag == 'group' then
				group += 1
			else
				failed += 1
			end
			print('[DL] code', code, ok, tag, ok and tostring(result):sub(1, 80))
			if i < #codes then
				task.wait(0.4)
			end
		end
		redeemBusy = false
		local msg = ('Codes  claimed %s  already %s  expired %s  fail %s'):format(
			fmtNum(claimed),
			fmtNum(already),
			fmtNum(expired),
			fmtNum(failed)
		)
		if group > 0 then
			msg = msg .. '  ·  join ClickBytes'
		end
		Library:Notify(msg, 8)
		print('[DL]', msg)
	end)
end

local questBusy = false
local lastQuestAuto = 0

local function knitRF(serviceName, rfName)
	rt.rfCache = rt.rfCache or {}
	local key = tostring(serviceName) .. '/' .. tostring(rfName)
	local cached = rt.rfCache[key]
	if cached and cached.Parent then
		return cached
	end
	for _, s in ipairs(findKnitServices()) do
		if s.Name == serviceName then
			local folder = s:FindFirstChild('RF')
			local rf = folder and folder:FindFirstChild(rfName)
			if rf and rf:IsA('RemoteFunction') then
				rt.rfCache[key] = rf
				return rf
			end
		end
	end
	return nil
end

rt.potionBusy = false
rt.potionNextTry = 0

local function potionCooldownLeft()
	local rf = knitRF('PotionService', 'GetCooldownRemaining')
	if not rf then
		return 0
	end
	local ok, left = pcall(function()
		return rf:InvokeServer()
	end)
	if ok and type(left) == 'number' then
		return left
	end
	return 0
end

local function usePotion()
	local rf = knitRF('PotionService', 'UsePotion')
	if not rf then
		return false, 'no UsePotion remote'
	end
	local ok, result = pcall(function()
		return rf:InvokeServer()
	end)
	if not ok then
		-- Some builds expect the hotbar slot (potion is key 5).
		ok, result = pcall(function()
			return rf:InvokeServer(5)
		end)
	end
	if not ok then
		return false, tostring(result)
	end
	if result == false then
		return false, 'server refused'
	end
	return true, result
end

local function autoPotionTick()
	if not on('DLAutoPotion') or rt.potionBusy then
		return
	end
	local now = os.clock()
	if now < rt.potionNextTry then
		return
	end
	local pct = rt.hpPct()
	if pct <= 0 then
		return
	end
	rt.updateHealWait(pct)
	if not rt.healWait and pct > rt.healTrigger() then
		return
	end
	rt.potionBusy = true
	task.spawn(function()
		local left = potionCooldownLeft()
		if left and left > 0.05 then
			rt.potionNextTry = os.clock() + math.min(left, 10)
			rt.potionBusy = false
			return
		end
		local ok, err = usePotion()
		if ok then
			rt.potionNextTry = os.clock() + 1.5
		else
			-- Out of potions or on an unknown signature; back off instead of spamming.
			rt.potionNextTry = os.clock() + 6
			if err and err ~= 'server refused' then
				Library:Notify('Auto potion: ' .. tostring(err))
			end
		end
		rt.potionBusy = false
	end)
end

return {
	usePotion = usePotion,
	autoFarmTick = autoFarmTick,
	startFarm = startFarm,
	autoRollTick = autoRollTick,
	autoPotionTick = autoPotionTick,
	trySummonSpecial = trySummonSpecial,
	confirmSpecialSummon = confirmSpecialSummon,
	listClassNames = listClassNames,
	redeemAllCodes = redeemAllCodes,
	knitRF = knitRF,
	findRollRemote = findRollRemote,
	wantedRollClasses = wantedRollClasses,
	currentClassName = currentClassName,
	classIsWanted = classIsWanted,
	listRedeemCodes = listRedeemCodes,
}
end)()


-- Cauldron refill: only when the equipped heal potion is x0. Takes the character
-- immediately — farm / special / chests / flee all yield while this runs.
rt.PotionRefill = (function()
	local api = {}
	local nextTry = 0
	local spent = setmetatable({}, { __mode = 'k' })
	local spentDungeon
	local emptyWarned = 0

	local function dungeonId()
		for _, root in ipairs(workspace:GetChildren()) do
			if type(root.Name) == 'string' and root.Name:sub(1, 10) == 'Generated_' then
				return root.Name
			end
		end
		return nil
	end

	local function resetSpent()
		local id = dungeonId()
		if id ~= spentDungeon then
			spentDungeon = id
			spent = setmetatable({}, { __mode = 'k' })
		end
	end

	local function markSpent(model)
		if model then
			spent[model] = true
		end
	end

	pcall(function()
		local re = game:GetService('ReplicatedStorage')
			.Packages._Index['sleitnick_knit@1.7.0']
			.knit.Services.DungeonRunService.RE.PotionStationUsed
		re.OnClientEvent:Connect(function(inst)
			if typeof(inst) ~= 'Instance' then
				return
			end
			local m = inst
			while m and m.Name ~= 'Potion_Station' do
				m = m.Parent
			end
			markSpent(m or inst)
		end)
	end)

	local knitCached
	local function playerData()
		if knitCached == false then
			return nil
		end
		local K = knitCached
		if type(K) ~= 'table' then
			local ok, got = pcall(function()
				return require(game:GetService('ReplicatedStorage').Packages.Knit)
			end)
			if not ok or type(got) ~= 'table' then
				knitCached = false
				return nil
			end
			knitCached = got
			K = got
		end
		local reg = rawget(K, 'Registry')
		local entries = (type(reg) == 'table') and reg._Entries or nil
		local pd = entries and entries.PlayerData
		local d = pd and pd.Data
		return (type(d) == 'table') and d or nil
	end

	function api.count()
		local d = playerData()
		if not d or type(d.Potions) ~= 'table' then
			return -1
		end
		local eq = d.EquippedPotion
		if type(eq) == 'string' and eq ~= '' then
			return tonumber(d.Potions[eq]) or 0
		end
		local n = 0
		for _, v in pairs(d.Potions) do
			n += tonumber(v) or 0
		end
		return n
	end

	local function stationPrompt(model)
		if not model or not model.Parent then
			return nil
		end
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA('ProximityPrompt') then
				local blob = (tostring(d.ActionText) .. ' ' .. tostring(d.ObjectText)):lower()
				if blob:find('refill', 1, true) or blob:find('potion', 1, true) then
					return d
				end
			end
		end
		return model:FindFirstChildWhichIsA('ProximityPrompt', true)
	end

	local function inGenerated(model)
		local root = model
		while root and root ~= workspace do
			if type(root.Name) == 'string' and root.Name:sub(1, 10) == 'Generated_' then
				return true
			end
			root = root.Parent
		end
		return false
	end

	local function nearestStation(from)
		resetSpent()
		local dungeon = LocalPlayer:GetAttribute('InDungeon') == true
			or LocalPlayer:GetAttribute('DungeonRun') == true
		local best, bestD
		for _, model in ipairs(potionStations) do
			if model and model.Parent and not spent[model] then
				if (not dungeon) or inGenerated(model) then
					local prompt = stationPrompt(model)
					if prompt and prompt.Enabled then
						local stand = promptStandPos(prompt, model)
						if stand then
							local dist = (stand - from).Magnitude
							if not bestD or dist < bestD then
								best, bestD = model, dist
							end
						end
					else
						markSpent(model)
					end
				end
			end
		end
		return best
	end

	function api.needs()
		if not on('DLAutoPotionRefill') then
			return false
		end
		if LocalPlayer:GetAttribute('InDungeon') ~= true
			and LocalPlayer:GetAttribute('DungeonRun') ~= true
		then
			return false
		end
		if api.count() ~= 0 then
			return false
		end
		local root = routeRoot()
		if not root then
			return false
		end
		if #potionStations == 0 then
			pcall(scanEsp)
		end
		return nearestStation(root.Position) ~= nil
	end

	function api.run(silent)
		if rt.refillBusy then
			return false
		end
		if api.count() ~= 0 then
			rt.refillUrgent = false
			return false
		end
		local root = routeRoot()
		if not root then
			return false
		end
		if #potionStations == 0 then
			pcall(scanEsp)
		end
		local station = nearestStation(root.Position)
		if not station then
			rt.refillUrgent = false
			if os.clock() - emptyWarned > 20 then
				emptyWarned = os.clock()
				Library:Notify('No unused cauldrons left')
			end
			nextTry = os.clock() + 12
			return false
		end
		local prompt = stationPrompt(station)
		local stand = prompt and promptStandPos(prompt, station)
		if not stand then
			return false
		end
		rt.refillBusy = true
		rt.refillUrgent = true
		rt.refillAt = os.clock()
		routeBusy = true
		noclipOn = true
		pcall(setCharNoclip, true)
		farmLabel = 'potion refill'
		routeLabel = 'potion refill'
		local home = root.CFrame
		task.spawn(function()
			local before = api.count()
			Pin.at(stand, true)
			pcall(function()
				prompt.MaxActivationDistance = math.max(tonumber(prompt.MaxActivationDistance) or 10, 18)
			end)
			local deadline = os.clock() + 10
			while os.clock() < deadline and currentInstance() and api.count() == 0 do
				Pin.at(stand, true)
				if prompt and prompt.Parent then
					chestFiredAt[prompt] = nil
					pcall(fireChestPrompt, prompt)
				end
				task.wait(0.2)
			end
			local after = api.count()
			local filled = after > 0
			if filled then
				Library:Notify(('Potions refilled  ·  x%s'):format(tostring(after)))
			end
			-- One trip per cauldron this run. The map only has a few, and
			-- PotionStationUsed / a disabled prompt also mark them spent.
			markSpent(station)
			if not filled and not silent then
				Library:Notify('Potion refill failed')
			end
			routeLabel = nil
			rt.refillBusy = false
			rt.refillAt = nil
			local stillEmpty = api.count() == 0
			local more = stillEmpty and nearestStation((routeRoot() and routeRoot().Position) or stand)
			rt.refillUrgent = stillEmpty and more ~= nil
			routeBusy = false
			-- Do not pin on the cauldron. farmBusy Pin.stop() would freeze you
			-- there; farm re-acquires the special on the next loop.
			if not farmBusy then
				pcall(function()
					local live = routeRoot()
					if live and home then
						live.CFrame = home
					end
				end)
				Pin.stop()
			end
			if filled then
				rt.healWait = false
			end
			nextTry = os.clock() + (filled and 2 or (more and 0.4 or 12))
		end)
		return true
	end

	function api.tick()
		if not on('DLAutoPotionRefill') then
			return
		end
		local now = os.clock()
		if now - (rt.potionRefillTickAt or 0) < 0.4 then
			return
		end
		rt.potionRefillTickAt = now
		if api.count() > 0 then
			rt.refillBusy = false
			rt.refillUrgent = false
			rt.refillAt = nil
			return
		end
		if rt.refillBusy then
			if type(rt.refillAt) == 'number' and os.clock() - rt.refillAt > 15 then
				rt.refillBusy = false
				rt.refillUrgent = false
				routeBusy = false
				return
			end
			rt.refillUrgent = true
			return
		end
		if os.clock() < nextTry then
			return
		end
		if not api.needs() then
			rt.refillUrgent = false
			return
		end
		rt.refillUrgent = true
		api.run(true)
	end

	return api
end)()

-- Warp off the pack when HP is under the potion threshold. Empty bottles go to
-- the cauldron first (PotionRefill); this is only a pack-distance heal park.
local Flee = (function()
	local api = {}
	local nextCheck = 0
	local lastFlee = 0

	local function hpPct()
		return rt.hpPct()
	end

	local function threshold()
		return rt.healResume()
	end

	function api.should()
		if rt.refillBusy or rt.refillUrgent then
			return false
		end
		if not on('DLAutoFlee') then
			return false
		end
		local pct = hpPct()
		-- Dead is a wipe, not a heal window. Replay / loop restart handles that.
		if pct <= 0 then
			return false
		end
		return rt.updateHealWait(pct)
	end

	local function extractSpot(from)
		local best, bestD
		local function consider(inst)
			if not inst then
				return
			end
			local ok, pos = pcall(function()
				if inst:IsA('BasePart') then
					return inst.Position
				end
				return inst:GetPivot().Position
			end)
			if ok and pos then
				local d = (pos - from).Magnitude
				if not bestD or d < bestD then
					best, bestD = pos, d
				end
			end
		end
		local portals = workspace:FindFirstChild('Portals')
		if portals then
			for _, c in ipairs(portals:GetChildren()) do
				consider(c)
			end
		end
		local dungeon = activeDungeonRoot()
		if dungeon then
			for _, c in ipairs(dungeon:GetChildren()) do
				local low = c.Name:lower()
				if low:find('extract', 1, true) or low:find('portal', 1, true) or low:find('exit', 1, true) then
					consider(c)
				end
			end
		end
		return best
	end

	function api.run(silent)
		if os.clock() - lastFlee < 1.2 then
			return false
		end
		if routeBusy then
			return false
		end
		local root = routeRoot()
		if not root then
			return false
		end
		lastFlee = os.clock()
		Pin.stop()
		pcall(scanEspThrottled, 1.0)
		routeBusy = true
		local wasNoclip = noclipOn
		noclipOn = true
		pcall(setCharNoclip, true)
		routeLabel = 'flee'
		local dest = extractSpot(root.Position)
		if not dest and farmHome then
			dest = farmHome.Position
		end
		if not dest then
			local away = root.Position
			local dungeon = activeDungeonRoot()
			local npcs = dungeon and dungeon:FindFirstChild('NPCs')
			local nearest
			if npcs then
				for _, npc in ipairs(npcs:GetChildren()) do
					if enemyAlive(npc) then
						local p = enemyRoot(npc)
						if p then
							local d = (p.Position - root.Position).Magnitude
							if not nearest or d < nearest then
								nearest = d
								local flat = Vector3.new(root.Position.X - p.Position.X, 0, root.Position.Z - p.Position.Z)
								if flat.Magnitude > 1 then
									away = root.Position + flat.Unit * 80
								end
							end
						end
					end
				end
			end
			dest = away
		end
		Pin.at(standingSpot(dest), true)
		local waitUntil = os.clock() + 45
		while currentInstance() and rt.updateHealWait(hpPct()) do
			if not farmBusy and os.clock() > waitUntil then
				break
			end
			routeLabel = ('flee · %d%% / %d%%'):format(math.floor(hpPct() + 0.5), rt.healResume())
			pcall(RunLoops.autoPotionTick)
			Pin.at(standingSpot(dest), true)
			task.wait(0.2)
		end
		Pin.stop()
		if not wasNoclip and not farmBusy then
			noclipOn = false
			pcall(setCharNoclip, false)
			pcall(fixMovement)
		elseif farmBusy then
			noclipOn = true
		end
		routeLabel = nil
		routeBusy = false
		if hpPct() <= threshold() then
			rt.combatHold = os.clock() + 8
		end
		if not silent then
			Library:Notify('Fled to heal')
		end
		return true
	end

	function api.tick()
		if not on('DLAutoFlee') or os.clock() < nextCheck then
			return
		end
		nextCheck = os.clock() + 0.08
		if api.should() then
			task.spawn(api.run, true)
		end
	end

	rt.fleeNow = api.run
	return api
end)()

-- Auto replay. RequestReplay is the same RemoteFunction the REPLAY button on the
-- completion screen invokes, so this is a menu click, not a run-state edit.
local function knitRE(serviceName, reName)
	for _, s in ipairs(findKnitServices()) do
		if s.Name == serviceName then
			local folder = s:FindFirstChild('RE')
			local re = folder and folder:FindFirstChild(reName)
			if re and re:IsA('RemoteEvent') then
				return re
			end
			for _, d in ipairs(s:GetDescendants()) do
				if d.Name == reName and d:IsA('RemoteEvent') then
					return d
				end
			end
		end
	end
	return nil
end

-- Keep Completion_Progress room Indexes in sync (star bar ↔ Room_N).
pcall(function()
	local re = knitRE('DungeonRunService', 'RoomLayoutUpdate')
	if re then
		track(re.OnClientEvent:Connect(function(zones, current)
			pcall(Rooms.ingestLayout, zones, current)
		end))
	end
end)

-- End-of-run reward pick ("SELECT 2 CHESTS: BOSS SLAIN"). The panel is
-- Main.HUD.Chest_Selection: a CanvasGroup holding Chest_1..3 image buttons, a Finish
-- button, and a header stating how many to take. Clicking the real buttons is
-- deliberate rather than calling SelectChests: the client decides between
-- SelectChests and SelectMidRunChests and enforces the selection cap itself, so
-- driving its own buttons keeps mid-run picks working for free.
local ChestPick = (function()
	local api = {}
	local lastAt = 0

	local function panel()
		local gui = LocalPlayer:FindFirstChild('PlayerGui')
		local main = gui and gui:FindFirstChild('Main')
		local hud = main and main:FindFirstChild('HUD')
		return hud and hud:FindFirstChild('Chest_Selection') or nil
	end

	-- The panel is never destroyed, just faded, so Visible alone is not enough.
	function api.open()
		local p = panel()
		if not p or p.Visible ~= true then
			return false
		end
		local ok, t = pcall(function()
			return p.GroupTransparency
		end)
		return (not ok) or t < 0.5
	end

	-- "SELECT 2 CHESTS:" -> 2. The third slot is a gamepass, so never assume 3.
	local function wanted(p)
		local lab = p and p:FindFirstChild('TextLabel')
		local n = lab and tostring(lab.Text):match('(%d+)')
		return math.clamp(tonumber(n) or 2, 1, 3)
	end

	local function click(btn)
		if not btn then
			return false
		end
		if type(firesignal) == 'function' then
			local ok = pcall(firesignal, btn.MouseButton1Click)
			if ok then
				return true
			end
		end
		local ok, conns = pcall(getconnections, btn.MouseButton1Click)
		if not ok then
			return false
		end
		local fired = false
		for _, c in ipairs(conns) do
			if c.Function then
				-- The handlers yield on a remote, so they must not run inline.
				task.spawn(c.Function)
				fired = true
			end
		end
		return fired
	end

	function api.run(silent)
		local p = panel()
		if not api.open() then
			if not silent then
				Library:Notify('No chest selection open')
			end
			return 0
		end
		if os.clock() - lastAt < 4 then
			return 0
		end
		lastAt = os.clock()
		local need = wanted(p)
		local took = 0
		for i = 1, 3 do
			if took >= need then
				break
			end
			local btn = p:FindFirstChild('Chest_' .. i)
			if btn and btn.Visible and click(btn) then
				took += 1
				task.wait(0.3)
			end
		end
		if took > 0 then
			task.wait(0.4)
			-- Only confirm if the panel is still up; the client may close itself once
			-- the cap is reached.
			if api.open() then
				click(p:FindFirstChild('Finish'))
			end
		end
		if not silent then
			Library:Notify(('Chest pick: took %d of %d'):format(took, need))
		end
		return took
	end

	function api.tick()
		if on('DLAutoChestPick') and api.open() then
			task.spawn(api.run, true)
		end
	end

	return api
end)()

-- Mid-run blessing shrine: three BuffData options, pick the one that most increases
-- damage. The panel is not always named the same across places, so discovery walks
-- PlayerGui for a visible card set whose titles match BuffData (Overwhelming Force,
-- Arcane Might, …) rather than hardcoding a HUD path. Damage ranking uses EffectType
-- from that same module — Overall Damage first, then skill damage / crit — so a
-- non-damage roll is only taken when no damage option is offered.
local BlessPick = (function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local DAMAGE_RANK = {
		DamagePct = 1000,
		SkillDamagePct = 800,
		SkillCritDamagePct = 600,
		CritRatePct = 500,
		SkillCritRatePct = 450,
		SkillCooldownPct = 200,
	}
	local api = {}
	local lastAt = 0
	local byTitle = nil

	local function buffIndex()
		if byTitle then
			return byTitle
		end
		byTitle = {}
		local ok, data = pcall(require, ReplicatedStorage.GameInfo.BuffData)
		if ok and type(data) == 'table' and type(data.Buffs) == 'table' then
			for _, buff in pairs(data.Buffs) do
				if type(buff) == 'table' and type(buff.Title) == 'string' then
					byTitle[buff.Title] = buff
				end
			end
		end
		return byTitle
	end

	local function scoreBuff(buff, magnitude)
		if type(buff) ~= 'table' then
			return -1
		end
		local rank = DAMAGE_RANK[buff.EffectType or ''] or 0
		-- Magnitude breaks ties within the same EffectType (e.g. +25% vs +10%).
		return rank * 1000 + (tonumber(magnitude) or 0)
	end

	local function parseMag(text)
		if type(text) ~= 'string' then
			return 0
		end
		-- "+15% Overall Damage" / "-0.1s Dodge Cooldown" — take the first number.
		local n = text:match('([%+%-]?%d+%.?%d*)')
		return math.abs(tonumber(n) or 0)
	end

	local function isVisible(gui)
		if not gui or not gui:IsA('GuiObject') then
			return false
		end
		if gui.Visible == false then
			return false
		end
		local ok, t = pcall(function()
			return gui.GroupTransparency
		end)
		if ok and type(t) == 'number' and t >= 0.95 then
			return false
		end
		local p = gui.Parent
		while p and p ~= LocalPlayer:FindFirstChild('PlayerGui') do
			if p:IsA('GuiObject') and p.Visible == false then
				return false
			end
			p = p.Parent
		end
		return true
	end

	local function click(btn)
		if not btn then
			return false
		end
		if type(firesignal) == 'function' then
			local ok = pcall(firesignal, btn.MouseButton1Click)
			if ok then
				return true
			end
		end
		local ok, conns = pcall(getconnections, btn.MouseButton1Click)
		if not ok then
			return false
		end
		local fired = false
		for _, c in ipairs(conns) do
			if c.Function then
				task.spawn(c.Function)
				fired = true
			end
		end
		return fired
	end

	-- A "card" is the nearest button ancestor of a BuffData title label, so one click
	-- selects that blessing the same way a player would.
	local function collectOptions()
		local index = buffIndex()
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		if not pg then
			return {}
		end
		local options = {}
		local seen = {}
		for _, d in ipairs(pg:GetDescendants()) do
			if (d:IsA('TextLabel') or d:IsA('TextButton')) and isVisible(d) then
				local title = tostring(d.Text)
				local buff = index[title]
				if buff and not seen[d] then
					seen[d] = true
					local btn = d
					if not btn:IsA('GuiButton') then
						local a = d.Parent
						while a and a ~= pg do
							if a:IsA('GuiButton') then
								btn = a
								break
							end
							a = a.Parent
						end
					end
					if btn and btn:IsA('GuiButton') and isVisible(btn) then
						local mag = 0
						-- Prefer a Desc sibling / child on the same card for magnitude.
						local card = btn
						for _, t in ipairs(card:GetDescendants()) do
							if (t:IsA('TextLabel') or t:IsA('TextButton')) and t ~= d then
								local tx = tostring(t.Text)
								if tx:find('%%') or tx:find('Damage') or tx:find('Crit') or tx:find('+') or tx:find('-') then
									mag = math.max(mag, parseMag(tx))
								end
							end
						end
						options[#options + 1] = {
							title = title,
							buff = buff,
							btn = btn,
							score = scoreBuff(buff, mag),
							mag = mag,
						}
					end
				end
			end
		end
		return options
	end

	function api.open()
		return #collectOptions() >= 2
	end

	function api.run(silent)
		local options = collectOptions()
		if #options < 2 then
			if not silent then
				Library:Notify('No blessing choices open')
			end
			return false
		end
		if os.clock() - lastAt < 3 then
			return false
		end
		lastAt = os.clock()
		table.sort(options, function(a, b)
			return a.score > b.score
		end)
		local best = options[1]
		-- If nothing is a damage buff, still pick the top of whatever was offered so
		-- the shrine does not block the run forever.
		if click(best.btn) then
			Library:Notify(('Blessing: %s'):format(best.title))
			return true
		end
		if not silent then
			Library:Notify('Blessing click failed')
		end
		return false
	end

	function api.tick()
		if on('DLAutoBless') and api.open() then
			task.spawn(api.run, true)
		end
	end

	-- Touch blessing altars so the choice UI appears. Live prompts sit on an
	-- Attachment (PromptAttachment), and altars are often hundreds of studs off the
	-- farm path — the old 45-stud BasePart-only scan never reached them.
	local shrineBusy, shrineNext = false, 0

	local function shrinePosKey(pos)
		if typeof(pos) ~= 'Vector3' then
			return nil
		end
		return string.format('s:%.0f:%.0f:%.0f', pos.X, pos.Y, pos.Z)
	end

	local function shrineLooksSpent(model, prompt)
		if prompt and prompt.Enabled == true then
			return false
		end
		-- Unused template keeps emitters on and Enabled=true. Claimed live
		-- altars disable Receive Blessing and turn every ParticleEmitter off.
		if model then
			local onN, saw = 0, false
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA('ParticleEmitter') then
					saw = true
					if d.Enabled then
						onN += 1
						break
					end
				end
			end
			if saw and onN == 0 then
				return true
			end
		end
		return false
	end

	local function shrineAlreadyUsed(model, pos)
		rt.shrineUsed = rt.shrineUsed or {}
		if model and rt.shrineUsed[model] then
			return true
		end
		if model and rt.shrineUsed['name:' .. model.Name] then
			return true
		end
		local key = shrinePosKey(pos)
		if key and rt.shrineUsed[key] == true then
			return true
		end
		return shrineLooksSpent(model, model and model:FindFirstChildWhichIsA('ProximityPrompt', true) or nil)
	end

	local function markShrineUsed(model, pos)
		rt.shrineUsed = rt.shrineUsed or {}
		if model then
			rt.shrineUsed[model] = true
			rt.shrineUsed['name:' .. model.Name] = true
		end
		local key = shrinePosKey(pos)
		if key then
			rt.shrineUsed[key] = true
		end
	end

	function api.shrineTick()
		if not on('DLAutoBless') or shrineBusy or routeBusy or rt.refillBusy or rt.refillUrgent or os.clock() < shrineNext then
			return
		end
		-- Farm loop calls farmPriority instead so shrines beat rooms.
		if farmBusy and rt.blessFromFarm ~= true then
			return
		end
		local root = routeRoot()
		if not root then
			return
		end
		if api.open() then
			return
		end
		local maxDist = 4000
		local bestPos, bestDist, bestPrompt, bestModel = nil, maxDist, nil, nil
		local function consider(model, prompt)
			local part = prompt and prompt.Parent
			local pos
			if part and part:IsA('Attachment') then
				pos = part.WorldPosition
			elseif part and part:IsA('BasePart') then
				pos = part.Position
			elseif model then
				local ok, p = pcall(function()
					return model:GetPivot().Position
				end)
				pos = ok and p or nil
			end
			if not pos or shrineAlreadyUsed(model, pos) then
				if pos then
					markShrineUsed(model, pos)
				end
				return
			end
			local dist = (pos - root.Position).Magnitude
			if dist < bestDist then
				bestPos, bestDist, bestPrompt, bestModel = pos, dist, prompt, model
			end
		end
		for _, gen in ipairs(workspace:GetChildren()) do
			if type(gen.Name) == 'string' and gen.Name:sub(1, 10) == 'Generated_' then
				for _, child in ipairs(gen:GetChildren()) do
					local low = string.lower(child.Name)
					if low:find('bless', 1, true) or low:find('shrine', 1, true) then
						consider(child, child:FindFirstChildWhichIsA('ProximityPrompt', true))
					end
				end
			end
		end
		-- Fallback: prompt text under the active dungeon (expensive). Skip while
		-- autofarm is moving — top-level Bless/Shrine names are enough mid-run.
		if not bestModel and not farmBusy then
			local dungeon = activeDungeonRoot()
			if dungeon and os.clock() - (rt.shrineDeepAt or 0) > 8 then
				rt.shrineDeepAt = os.clock()
				for _, d in ipairs(dungeon:GetDescendants()) do
					if d:IsA('ProximityPrompt') then
						local action = (tostring(d.ActionText) .. ' ' .. tostring(d.ObjectText)):lower()
						if action:find('bless', 1, true) or action:find('shrine', 1, true) or action:find('pray', 1, true) or action:find('boon', 1, true) then
							consider(d:FindFirstAncestorOfClass('Model'), d)
						end
					end
				end
			end
		end
		if not bestPos then
			return
		end
		shrineBusy = true
		task.spawn(function()
			local home = root.CFrame
			local wasNoclip = noclipOn
			routeBusy = true
			noclipOn = true
			pcall(setCharNoclip, true)
			routeLabel = 'blessing shrine'
			farmLabel = 'blessing shrine'
			-- Stand on the PromptAttachment itself — altar mesh has CanQuery=false so
			-- floor snaps can miss and leave you out of the 10-stud hold range.
			local stand = bestPos + Vector3.new(0, 3, 0)
			if bestPrompt then
				local ranged = promptStandPos(bestPrompt, bestModel)
				if ranged and (ranged - bestPos).Magnitude <= 8 then
					stand = ranged
				end
			end
			Pin.at(stand, true)
			task.wait(0.55)
			local deadline = os.clock() + 5.5
			local opened = false
			while os.clock() < deadline and currentInstance() do
				if api.open() then
					opened = true
					break
				end
				if bestPrompt and bestPrompt.Parent and bestPrompt.Enabled then
					chestFiredAt[bestPrompt] = nil
					fireChestPrompt(bestPrompt)
				elseif bestModel then
					local p = bestModel:FindFirstChildWhichIsA('ProximityPrompt', true)
					if p and p.Enabled then
						bestPrompt = p
						chestFiredAt[p] = nil
						fireChestPrompt(p)
					end
				end
				task.wait(0.35)
			end
			local picked = false
			if opened or api.open() then
				picked = api.run(true) == true
				task.wait(0.45)
			end
			if picked or opened or shrineLooksSpent(bestModel, bestPrompt)
				or (bestPrompt and bestPrompt.Parent and bestPrompt.Enabled ~= true)
			then
				markShrineUsed(bestModel, bestPos)
			end
			local live = routeRoot()
			if live then
				pcall(function()
					live.CFrame = home
					live.AssemblyLinearVelocity = Vector3.zero
					live.AssemblyAngularVelocity = Vector3.zero
				end)
				Pin.at(home.Position, true)
				task.wait(0.3)
			end
			if not wasNoclip and not farmBusy then
				noclipOn = false
				pcall(setCharNoclip, false)
				pcall(fixMovement)
			elseif farmBusy then
				noclipOn = true
			end
			Pin.stop()
			routeLabel = nil
			routeBusy = false
			shrineBusy = false
			if shrineAlreadyUsed(bestModel, bestPos) then
				shrineNext = os.clock() + 8
			else
				-- Hold missed — try again shortly, do not immediately re-warp.
				shrineNext = os.clock() + 2.5
			end
		end)
	end

	function api.busy()
		return shrineBusy == true
	end

	-- True = farm must yield. Blessings beat specials and room walking.
	function api.farmPriority()
		if not on('DLAutoBless') then
			return false
		end
		if shrineBusy then
			farmLabel = 'blessing shrine'
			return true
		end
		if api.open() then
			farmLabel = 'blessing'
			local picked = api.run(true) == true
			if picked then
				local root = routeRoot()
				local bestM, bestP, bestD = nil, nil, 9e9
				for _, gen in ipairs(workspace:GetChildren()) do
					if type(gen.Name) == 'string' and gen.Name:sub(1, 10) == 'Generated_' then
						for _, child in ipairs(gen:GetChildren()) do
							local low = string.lower(child.Name)
							if low:find('bless', 1, true) or low:find('shrine', 1, true) then
								local ok, pos = pcall(function()
									return child:GetPivot().Position
								end)
								if ok and pos and root then
									local d = (pos - root.Position).Magnitude
									if d < bestD then
										bestM, bestP, bestD = child, pos, d
									end
								end
							end
						end
					end
				end
				markShrineUsed(bestM, bestP)
			end
			return true
		end
		rt.blessFromFarm = true
		pcall(api.shrineTick)
		rt.blessFromFarm = nil
		if shrineBusy then
			farmLabel = 'blessing shrine'
			return true
		end
		return false
	end

	-- Checkpoint that only hosts a claimed altar: do not walk it again.
	function api.roomIsSpent(dungeon, idx)
		if not dungeon or not idx then
			return false
		end
		local room = dungeon:FindFirstChild('Room_' .. tostring(idx))
		if not room or room:GetAttribute('IsCheckpoint') ~= true then
			return false
		end
		local spawns = room:FindFirstChild('Spawns')
		if not (spawns and spawns:FindFirstChild('Altar_Spawn')) then
			return false
		end
		if Rooms.aliveCount(dungeon, idx) > 0 then
			return false
		end
		if roomHasPendingChest(dungeon, idx) or roomHasPendingGate(dungeon, idx) then
			return false
		end
		local altar = dungeon:FindFirstChild('Blessing_Altar')
		if not altar then
			return false
		end
		local prompt = altar:FindFirstChildWhichIsA('ProximityPrompt', true)
		local ok, pos = pcall(function()
			return altar:GetPivot().Position
		end)
		if shrineAlreadyUsed(altar, ok and pos or nil) or shrineLooksSpent(altar, prompt) then
			markShrineUsed(altar, ok and pos or nil)
			return true
		end
		return false
	end

	rt.blessFarmPriority = api.farmPriority
	rt.shrineRoomDone = api.roomIsSpent

	return api
end)()

local Replay = (function()
	local MAX_TRIES = 6
	local api = {}

	local function completionFrame()
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		if not pg then
			return nil
		end
		-- Live path is Main.HUD.Dungeon_Container.Completion_Info (not under a "ui" folder).
		-- Endless floor-clear lives on Endless_Container. Reading Dungeon_Container first
		-- hid Continue_Frame so Loop specific never pressed it.
		local main = pg:FindFirstChild('Main')
		local hud = main and main:FindFirstChild('HUD')
		if hud then
			local names = { 'Dungeon_Container', 'Endless_Container' }
			if inEndlessFarm() then
				names = { 'Endless_Container', 'Dungeon_Container' }
			end
			local fallback
			for _, name in ipairs(names) do
				local cont = hud:FindFirstChild(name)
				local frame = cont and cont:FindFirstChild('Completion_Info')
				if frame then
					local shown = frame.Visible == true
						or (cont:IsA('GuiObject') and cont.Visible == true and frame.Visible ~= false)
					if shown then
						return frame
					end
					fallback = fallback or frame
				end
			end
			if fallback then
				return fallback
			end
		end
		return pg:FindFirstChild('Completion_Info', true)
	end

	local function completionShowing()
		local frame = completionFrame()
		if frame then
			if frame.Visible == true then
				return true
			end
			local ok, t = pcall(function()
				return frame.GroupTransparency
			end)
			if ok and type(t) == 'number' and t < 0.9 and frame.Visible ~= false then
				local parent = frame.Parent
				if parent and parent:IsA('GuiObject') and parent.Visible == true then
					return true
				end
			end
			local title = frame:FindFirstChild('Title', true)
			if title and title:IsA('TextLabel') then
				local tx = string.upper(tostring(title.Text or ''))
				if tx:find('FAIL', 1, true) or tx:find('DEFEAT', 1, true) or tx:find('COMPLETE', 1, true) then
					if frame.Visible ~= false then
						return true
					end
				end
			end
		end
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		local main = pg and pg:FindFirstChild('Main')
		local hud = main and main:FindFirstChild('HUD')
		local cont = hud and (hud:FindFirstChild('Dungeon_Container') or hud:FindFirstChild('Endless_Container'))
		local spec = cont and cont:FindFirstChild('Spectate_Info')
		if spec and spec.Visible == true then
			return true
		end
		return false
	end

	local function guiChainVisible(inst)
		local n = inst
		while n and n ~= game do
			if n:IsA('GuiObject') and n.Visible == false then
				return false
			end
			if n:IsA('CanvasGroup') and (tonumber(n.GroupTransparency) or 0) >= 0.9 then
				return false
			end
			n = n.Parent
		end
		return inst ~= nil
	end

	local function findReplayButton()
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		local main = pg and pg:FindFirstChild('Main')
		local hud = main and main:FindFirstChild('HUD')
		if not hud then
			return nil
		end
		local best
		local function consider(btn)
			if not btn or not btn:IsA('GuiButton') or not guiChainVisible(btn) then
				return
			end
			best = best or btn
		end
		consider(hud:FindFirstChild('ReplayButton', true))
		local frame = completionFrame()
		consider(frame and frame:FindFirstChild('ReplayButton', true))
		for _, d in ipairs(hud:GetDescendants()) do
			if d:IsA('GuiButton') then
				local n = string.lower(d.Name)
				local lab = d:FindFirstChildWhichIsA('TextLabel', true)
				local tx = string.lower(tostring(lab and lab.Text or ''))
				if n:find('replay', 1, true) or tx:find('replay', 1, true) then
					consider(d)
				end
			end
		end
		return best
	end

	local function rushReplayShowing()
		return findReplayButton() ~= nil
	end

	local function clickBtn(btn)
		if not btn or not btn:IsA('GuiButton') then
			return false
		end
		if type(firesignal) == 'function' then
			for _, ev in ipairs({ btn.MouseButton1Click, btn.Activated, btn.MouseButton1Down }) do
				if ev and pcall(firesignal, ev) then
					return true
				end
			end
		end
		local ok, conns = pcall(getconnections, btn.MouseButton1Click)
		if ok then
			for _, c in ipairs(conns) do
				if c.Function then
					task.spawn(c.Function)
					return true
				end
			end
		end
		ok, conns = pcall(getconnections, btn.Activated)
		if ok then
			for _, c in ipairs(conns) do
				if c.Function then
					task.spawn(c.Function)
					return true
				end
			end
		end
		return false
	end

	local function clickReplayButton()
		return clickBtn(findReplayButton())
	end

	local function hudWarning()
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		local main = pg and pg:FindFirstChild('Main')
		local hud = main and main:FindFirstChild('HUD')
		return hud and hud:FindFirstChild('Warning') or nil
	end

	local function loopingEndless()
		if not on('DLLoopSpecific') then
			return false
		end
		local wantDiff = Options.DLLoopDifficulty and tostring(Options.DLLoopDifficulty.Value or '')
		if string.lower(wantDiff):find('endless', 1, true) then
			return true
		end
		-- Dropdown can say Endless while CurrentDifficultyMode is blank mid-floor.
		return inEndlessFarm()
	end

	-- Checkpoint confirm: Endless floors and Boss Rush wave 100 both use HUD.Warning
	-- with green Confirm (not Completion_Info). Do not match chest / summon dialogs.
	local function continueWarningShowing()
		local w = hudWarning()
		if not w or w.Visible ~= true then
			return false
		end
		local msg = w:FindFirstChild('Warning_Message', true)
		local tx = string.lower(tostring(msg and msg.Text or ''))
		if tx:find('chest', 1, true)
			or tx:find('summon', 1, true)
			or tx:find('platinum', 1, true)
			or tx:find('open all', 1, true)
			or tx:find('bless', 1, true)
		then
			return false
		end
		if tx:find('checkpoint', 1, true)
			or tx:find('regenerat', 1, true)
			or tx:find('extract', 1, true)
			or tx:find('continue', 1, true)
			or tx:find('replay', 1, true)
			or tx:find('milestone', 1, true)
			or tx:find('wave', 1, true)
			or tx:find('boss rush', 1, true)
			or tx:find('next floor', 1, true)
			or tx:find('next area', 1, true)
			or tx:find('depth', 1, true)
		then
			return true
		end
		-- Endless floor prompt often has no keyword — just green Confirm.
		if loopingEndless() or inEndlessFarm() then
			local confirm = w:FindFirstChild('Confirm')
			return confirm ~= nil and guiChainVisible(confirm)
		end
		return false
	end

	local function findContinueButton()
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		local main = pg and pg:FindFirstChild('Main')
		local hud = main and main:FindFirstChild('HUD')
		if not hud then
			return nil
		end
		local best
		local function consider(btn)
			if btn and btn:IsA('GuiButton') and guiChainVisible(btn) then
				best = best or btn
			end
		end
		local endless = hud:FindFirstChild('Endless_Container')
		local info = endless and endless:FindFirstChild('Completion_Info')
		if info then
			local frame = info:FindFirstChild('Continue_Frame')
			consider(frame and (frame:FindFirstChildWhichIsA('GuiButton', true)))
			consider(info:FindFirstChild('Continue', true))
			consider(info:FindFirstChild('ContinueButton', true))
		end
		consider(hud:FindFirstChild('Continue', true))
		consider(hud:FindFirstChild('ContinueButton', true))
		local w = hudWarning()
		if continueWarningShowing() then
			consider(w and w:FindFirstChild('Confirm'))
		end
		local function scan(root)
			if not root then
				return
			end
			for _, d in ipairs(root:GetDescendants()) do
				if d:IsA('GuiButton') and guiChainVisible(d) then
					local n = string.lower(tostring(d.Name or ''))
					local lab = d:FindFirstChildWhichIsA('TextLabel', true)
					local tx = string.lower(tostring((lab and lab.Text) or d.Text or ''))
					if n:find('continue', 1, true)
						or tx:find('continue', 1, true)
						or tx:find('next floor', 1, true)
					then
						if not n:find('chest', 1, true) and not tx:find('chest', 1, true) then
							consider(d)
						end
					end
				end
			end
		end
		scan(info)
		if continueWarningShowing() then
			scan(w)
		end
		return best
	end

	local function continueUiShowing()
		if continueWarningShowing() then
			return true
		end
		return findContinueButton() ~= nil
	end

	local function clickContinueWarning()
		local w = hudWarning()
		if clickBtn(w and w:FindFirstChild('Confirm')) then
			return true
		end
		if not w then
			return false
		end
		for _, d in ipairs(w:GetDescendants()) do
			if d:IsA('GuiButton') then
				local t = string.lower(tostring(d.Name or ''))
				local lab = d:FindFirstChildWhichIsA('TextLabel', true)
				local tx = string.lower(tostring(lab and lab.Text or ''))
				if t:find('confirm', 1, true)
					or t:find('continue', 1, true)
					or t:find('replay', 1, true)
					or tx:find('continue', 1, true)
					or tx:find('replay', 1, true)
					or tx == 'yes'
				then
					if clickBtn(d) then
						return true
					end
				end
			end
		end
		return false
	end

	local function inRushNow()
		if type(inBossRushFarm) == 'function' and inBossRushFarm() then
			return true
		end
		local d = string.lower(tostring(
			LocalPlayer:GetAttribute('CurrentDungeon') or rt.runDungeonId or ''
		))
		return d:find('bossrush', 1, true) ~= nil
			or d:find('boss_rush', 1, true) ~= nil
			or d:find('boss rush', 1, true) ~= nil
	end

	local function continueEndless()
		if clickBtn(findContinueButton()) then
			return true
		end
		if continueWarningShowing() and clickContinueWarning() then
			return true
		end
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		local main = pg and pg:FindFirstChild('Main')
		local hud = main and main:FindFirstChild('HUD')
		local info = hud and hud:FindFirstChild('Endless_Container')
		info = info and info:FindFirstChild('Completion_Info')
		if info then
			local status = info:FindFirstChild('Status', true)
			local tx = string.upper(tostring(status and status.Text or ''))
			if tx:find('FAIL', 1, true) or tx:find('DEFEAT', 1, true) then
				return false
			end
			local frame = info:FindFirstChild('Continue_Frame')
			local btn = frame and (frame:FindFirstChild('ImageButton', true) or frame:FindFirstChildWhichIsA('GuiButton', true))
			if clickBtn(btn) then
				return true
			end
		end
		if not continueUiShowing() then
			return false
		end
		local rf = RunLoops.knitRF('DungeonRunService', 'SubmitEndlessChoice')
		if not rf then
			return false
		end
		for _, arg in ipairs({ true, 'Continue', 'Stay' }) do
			local ok, res = pcall(function()
				return rf:InvokeServer(arg)
			end)
			if ok and res ~= false then
				return true
			end
		end
		local ok, res = pcall(function()
			return rf:InvokeServer()
		end)
		return ok and res ~= false
	end

	function api.request(silent)
		-- Endless floor-clear is Continue, not CHANGE DUNGEON / RequestReplay.
		if loopingEndless() and continueEndless() then
			return true
		end
		-- Prefer a better dungeon/diff when one is unlocked; otherwise same-run replay.
		local upgrade = rt.dungeonUpgradeOrReplay
		if type(upgrade) == 'function' then
			local okUpgrade, did = pcall(upgrade, silent)
			if okUpgrade and did then
				return true
			end
		end
		if loopingEndless() and continueEndless() then
			return true
		end
		if inRushNow() then
			if clickReplayButton() then
				return true
			end
			local rushRf = RunLoops.knitRF('BossRushService', 'RequestReplay')
			if rushRf then
				local okRush, resRush = pcall(function()
					return rushRf:InvokeServer()
				end)
				if okRush and resRush ~= false then
					return true
				end
			end
		end
		local rf = RunLoops.knitRF('DungeonRunService', 'RequestReplay')
		if not rf then
			if not silent then
				Library:Notify('Replay remote not found')
			end
			return false
		end
		local ok, res = pcall(function()
			return rf:InvokeServer()
		end)
		if not ok then
			if not silent then
				Library:Notify('Replay failed: ' .. tostring(res))
			end
			return false
		end
		if res == false then
			if clickReplayButton() then
				return true
			end
			return false
		end
		return true
	end

	function api.tick()
		local wantReplay = on('DLAutoReplay') or on('DLLoopSpecific')
		local rushContinue = on('DLAutoFarm') and inRushNow()
		if not wantReplay and not rushContinue then
			runCompleteAt = nil
			replayArmedAt = nil
			replayTries = 0
			return
		end
		-- Never replay while the reward pick is still open. A faded Chest_Selection
		-- must not block Endless Continue.
		if ChestPick.open() and not (loopingEndless() and continueUiShowing()) then
			replayArmedAt = nil
			return
		end
		-- Boss Rush: red REPLAY on Completion_Info (Mythic), not green Warning Confirm.
		if inRushNow() and rushReplayShowing() then
			local now = os.clock()
			if now - lastReplayAt < 1.2 then
				return
			end
			lastReplayAt = now
			task.spawn(function()
				local ok = clickReplayButton()
				if not ok then
					local rf = RunLoops.knitRF('BossRushService', 'RequestReplay')
					if rf then
						local okRf, resRf = pcall(function()
							return rf:InvokeServer()
						end)
						ok = okRf and resRf ~= false
					end
				end
				if ok then
					Library:Notify('Boss rush replay')
				end
			end)
			return
		end
		-- Endless floor checkpoint: Continue_Frame or HUD.Warning green Confirm.
		if loopingEndless() and continueUiShowing() then
			local now = os.clock()
			if now - lastReplayAt < 1.2 then
				return
			end
			lastReplayAt = now
			task.spawn(function()
				if continueEndless() then
					Library:Notify('Endless continue')
				end
			end)
			return
		end
		if not wantReplay then
			return
		end
		local showing = completionShowing()
		local ended = showing or (runCompleteAt ~= nil and os.clock() - runCompleteAt < 90)
		-- Do NOT require InDungeon == false: completion shows while InDungeon is still
		-- true, which is why Auto replay never fired and Replay now did.
		if not ended then
			if runCompleteAt then
				replayCount += 1
				runCompleteAt = nil
			end
			replayArmedAt = nil
			replayTries = 0
			return
		end
		local now = os.clock()
		if not replayArmedAt then
			replayArmedAt = now
			return
		end
		local delay = Options.DLReplayDelay and tonumber(Options.DLReplayDelay.Value) or 2.5
		if now - replayArmedAt < delay then
			return
		end
		if now - lastReplayAt < 2.5 then
			return
		end
		if replayTries >= MAX_TRIES then
			if now - lastReplayAt < 8 then
				return
			end
			replayTries = 0
		end
		lastReplayAt = now
		replayTries += 1
		local attempt = replayTries
		task.spawn(function()
			local ok = api.request(true)
			if not ok then
				ok = clickReplayButton()
			end
			if ok then
				Library:Notify(on('DLLoopSpecific') and 'Loop dungeon requested' or 'Auto replay requested')
			elseif attempt >= MAX_TRIES then
				Library:Notify('Auto replay still waiting — server refused')
			end
		end)
	end

	return api
end)()

-- Lobby auto-start: next unlocked dungeon up the DisplayOrder list (or furthest
-- in lobby), hardest Easy–Nightmare that fits, then RequestStartSoloRun.
-- Same remotes the Dungeon_Select UI uses (RequestSelectDungeon / Difficulty / StartSoloRun).
-- Auto pick never chooses Endless — that is only for Loop specific dungeon.
local DungeonStart = (function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local DIFF_RANK = { Easy = 1, Normal = 2, Hard = 3, Nightmare = 4, Endless = 5 }
	local DIFF_LIST = { 'Easy', 'Normal', 'Hard', 'Nightmare', 'Endless' }
	local api = {}
	local nextCheck, lastStart, busy, armedAt = 0, 0, false, 0
	local lastLabel = ''

	local function inLobby()
		return LocalPlayer:GetAttribute('InDungeon') ~= true
			and LocalPlayer:GetAttribute('DungeonRun') ~= true
	end

	local function playerLevel()
		return tonumber(LocalPlayer:GetAttribute('PlayerLevel')) or 0
	end

	local function invoke(name, ...)
		local rem = RunLoops.knitRF('DungeonQueueService', name)
		if not rem then
			return false, nil
		end
		local args = table.pack(...)
		local ok, res = pcall(function()
			return rem:InvokeServer(table.unpack(args, 1, args.n))
		end)
		return ok, res
	end

	local function clickGui(btn)
		if not btn then
			return false
		end
		if type(firesignal) == 'function' then
			local ok = pcall(firesignal, btn.MouseButton1Click)
			if ok then
				return true
			end
		end
		local ok, conns = pcall(getconnections, btn.MouseButton1Click)
		if not ok then
			return false
		end
		local fired = false
		for _, c in ipairs(conns) do
			if c.Function then
				task.spawn(c.Function)
				fired = true
			end
		end
		return fired
	end

	local function panel()
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		local main = pg and pg:FindFirstChild('Main')
		local frames = main and main:FindFirstChild('Frames')
		return frames and frames:FindFirstChild('Dungeon_Select') or nil
	end

	local function ensureOpen()
		local p = panel()
		if p and p.Visible then
			return p
		end
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		local main = pg and pg:FindFirstChild('Main')
		local frames = main and main:FindFirstChild('Frames')
		local menu = frames and frames:FindFirstChild('MenuButtons')
		local dungeonBtn = menu and menu:FindFirstChild('Dungeon', true)
		if dungeonBtn then
			clickGui(dungeonBtn)
		else
			local hud = main and main:FindFirstChild('HUD')
			local enter = hud and hud:FindFirstChild('EnterDungeon', true)
			if enter then
				clickGui(enter)
			end
		end
		task.wait(0.55)
		p = panel()
		return (p and p.Visible) and p or p
	end

	local function fits(br, lvl, loose)
		if type(br) ~= 'table' then
			return false
		end
		local minL = tonumber(br.Min) or 0
		local maxL = tonumber(br.Max) or 1e9
		if lvl < minL then
			return false
		end
		if loose then
			return true
		end
		return lvl <= maxL
	end

	local function orderOf(data, want)
		if type(data) ~= 'table' or type(data.DisplayOrder) ~= 'table' then
			return 0
		end
		for order, id in ipairs(data.DisplayOrder) do
			if id == want then
				return order
			end
		end
		return 0
	end

	local dungeonMeta, currentRun, requestDungeonChange

	function api.listDungeons()
		local names = {}
		local ok, data = pcall(require, ReplicatedStorage.GameInfo.DungeonData)
		if not ok or type(data) ~= 'table' or type(data.DisplayOrder) ~= 'table' then
			return names
		end
		for _, id in ipairs(data.DisplayOrder) do
			local d = dungeonMeta(data, id)
			if type(d) == 'table' and not d.HideFromSelect and not d.ChallengeMode and not d.Legacy then
				names[#names + 1] = tostring(d.DisplayName or id)
			end
		end
		return names
	end

	function api.listDifficulties()
		return DIFF_LIST
	end

	function api.target()
		local wantName = Options.DLLoopDungeon and tostring(Options.DLLoopDungeon.Value or '')
		local wantDiff = Options.DLLoopDifficulty and tostring(Options.DLLoopDifficulty.Value or '')
		if wantName == '' or wantName == 'nil' then
			return nil
		end
		if not DIFF_RANK[wantDiff] then
			wantDiff = 'Nightmare'
		end
		local ok, data = pcall(require, ReplicatedStorage.GameInfo.DungeonData)
		if not ok or type(data) ~= 'table' or type(data.DisplayOrder) ~= 'table' then
			return nil
		end
		local wantLow = string.lower(wantName)
		for _, id in ipairs(data.DisplayOrder) do
			local d = dungeonMeta(data, id)
			if type(d) == 'table' then
				local name = tostring(d.DisplayName or id)
				if string.lower(name) == wantLow or string.lower(tostring(id)) == wantLow then
					return id, wantDiff, name
				end
			end
		end
		return nil
	end

	-- Loop-this-map: CHANGE DUNGEON to the dropdown pair, or false so RequestReplay
	-- can rejoin the same run when we are already there.
	function api.loopNow(silent)
		local id, diff, name = api.target()
		if not id or not diff then
			if not silent then
				Library:Notify('Pick a dungeon / difficulty first')
			end
			return false
		end
		local curId, curDiff = currentRun()
		if tostring(id) == tostring(curId) and tostring(diff) == tostring(curDiff) then
			return false
		end
		if not requestDungeonChange(id, diff) then
			if not silent then
				Library:Notify(('Loop failed: %s · %s'):format(tostring(name or id), tostring(diff)))
			end
			return false
		end
		rt.runDungeonId, rt.runDifficulty = id, diff
		Library:Notify(('Loop → %s · %s'):format(tostring(name or id), tostring(diff)))
		return true
	end

	dungeonMeta = function(data, id)
		if type(data) ~= 'table' or not id then
			return nil
		end
		return (data.GetDungeon and data.GetDungeon(id)) or (data.Dungeons and data.Dungeons[id])
	end

	-- Progression pick: never hardcode a dungeon name.
	-- 1) If you already have a current dungeon, take the next DisplayOrder entry
	--    you can enter (one step up the list).
	-- 2) Otherwise (lobby / no current), take the furthest DisplayOrder you can enter.
	-- Difficulty: hardest unlocked Easy–Nightmare. Endless is loop-specific only.
	-- Bracket Min is only a preference — unlocks from the server win.
	local function scorePair(order, rank, fit)
		return (fit and 100000 or 0) + (tonumber(order) or 0) * 100 + (tonumber(rank) or 0)
	end

	local function bestDiffOn(unlocks, brackets, lvl)
		local bestRank, bestDiff, bestStrict = -1, nil, false
		if type(unlocks) ~= 'table' then
			return nil, -1
		end
		for diff, st in pairs(unlocks) do
			local rank = DIFF_RANK[diff]
			local unlocked = st == true or (type(st) == 'table' and st.Unlocked == true)
			-- Trust GetUnlockedDifficulties over the printed bracket. Underworld
			-- Easy is Min 60, but the game already unlocks it at 58.
			-- Endless is not an auto-upgrade target — only Loop specific picks it.
			if unlocked and rank and diff ~= 'Endless' then
				local strict = fits(brackets[diff], lvl, false)
				if rank > bestRank or (rank == bestRank and strict and not bestStrict) then
					bestRank, bestDiff, bestStrict = rank, diff, strict
				end
			end
		end
		return bestDiff, bestRank
	end

	currentRun = function()
		local id = tostring(LocalPlayer:GetAttribute('CurrentDungeon') or rt.runDungeonId or '')
		local diff = tostring(
			LocalPlayer:GetAttribute('CurrentDifficultyMode')
				or LocalPlayer:GetAttribute('CurrentDifficulty')
				or rt.runDifficulty
				or ''
		)
		if id == '' or diff == '' then
			local info = nil
			pcall(function()
				local rf = RunLoops.knitRF('DungeonRunService', 'GetSessionInfo')
				if rf then
					info = rf:InvokeServer()
				end
			end)
			if type(info) == 'table' then
				if id == '' then
					id = tostring(info.DungeonId or info.LocationId or info.Dungeon or '')
				end
				if diff == '' then
					diff = tostring(info.DifficultyMode or info.Difficulty or info.Mode or '')
				end
			end
		end
		if id ~= '' then
			rt.runDungeonId = id
		end
		if diff ~= '' then
			rt.runDifficulty = diff
		end
		return id, diff
	end

	function api.pick()
		local ok, data = pcall(require, ReplicatedStorage.GameInfo.DungeonData)
		if not ok or type(data) ~= 'table' or type(data.DisplayOrder) ~= 'table' then
			return nil
		end
		local lvl = playerLevel()
		local curId = select(1, currentRun())
		local curOrder = orderOf(data, curId)
		local options = {}
		for order, id in ipairs(data.DisplayOrder) do
			local d = dungeonMeta(data, id)
			if type(d) == 'table' and not d.HideFromSelect and not d.ChallengeMode and not d.Legacy then
				local okA, access = invoke('GetDungeonAccessState', id)
				if okA and type(access) == 'table' and access.Unlocked == true then
					local okU, unlocks = invoke('GetUnlockedDifficulties', id)
					local brackets = d.DifficultyLevelBrackets or {}
					local diff, rank = nil, -1
					if okU then
						diff, rank = bestDiffOn(unlocks, brackets, lvl)
					end
					if diff then
						options[#options + 1] = {
							order = order,
							id = id,
							diff = diff,
							rank = rank,
							name = d.DisplayName or id,
						}
					end
				end
			end
		end
		if #options == 0 then
			return nil
		end
		local chosen = nil
		if curOrder > 0 then
			-- Next dungeon up: earliest option past the current one.
			for _, opt in ipairs(options) do
				if opt.order > curOrder and (not chosen or opt.order < chosen.order) then
					chosen = opt
				end
			end
			-- Nothing higher unlocked yet — stay on current dungeon, best difficulty.
			if not chosen then
				for _, opt in ipairs(options) do
					if opt.id == curId then
						chosen = opt
						break
					end
				end
			end
		end
		-- Lobby / unknown current: furthest unlocked dungeon in the list.
		if not chosen then
			for _, opt in ipairs(options) do
				if not chosen or opt.order > chosen.order then
					chosen = opt
				end
			end
		end
		if not chosen then
			return nil
		end
		return chosen.id, chosen.diff, chosen.name, scorePair(chosen.order, chosen.rank, true)
	end

	local function scoreCurrent()
		local ok, data = pcall(require, ReplicatedStorage.GameInfo.DungeonData)
		local id, diff = currentRun()
		if id == '' or diff == '' then
			return -1, id, diff
		end
		-- Leaving Endless always counts as an upgrade target.
		if diff == 'Endless' then
			local order = orderOf(data, id)
			return scorePair(order, 0, true) - 1, id, diff
		end
		local lvl = playerLevel()
		local d = ok and dungeonMeta(data, id) or nil
		local brackets = type(d) == 'table' and d.DifficultyLevelBrackets or {}
		-- Match pick(): over-max on a lower tier still loses to a later dungeon.
		local fit = fits(brackets[diff], lvl, true)
		local rank = DIFF_RANK[diff] or 0
		local order = orderOf(data, id)
		return scorePair(order, rank, fit), id, diff
	end

	local function clickChangeDungeon()
		local frame = nil
		pcall(function()
			local pg = LocalPlayer:FindFirstChild('PlayerGui')
			local hud = pg and pg:FindFirstChild('Main') and pg.Main:FindFirstChild('HUD')
			if not hud then
				return
			end
			for _, name in ipairs({ 'Dungeon_Container', 'Endless_Container' }) do
				local cont = hud:FindFirstChild(name)
				local info = cont and cont:FindFirstChild('Completion_Info')
				if info then
					frame = info
					break
				end
			end
		end)
		local btn = frame and frame:FindFirstChild('DungeonButton', true)
		if not btn then
			return false
		end
		return clickGui(btn)
	end

	-- Client select controller: open CHANGE DUNGEON, RequestSelect*, then
	-- RequestDungeonChange(id, diff). Confirm is for party members; solo still
	-- benefits from a confirm attempt after a successful request.
	requestDungeonChange = function(id, diff)
		clickChangeDungeon()
		task.wait(0.35)
		invoke('RequestSelectMode', 'Dungeon')
		task.wait(0.15)
		invoke('RequestSelectDungeon', id)
		task.wait(0.2)
		invoke('RequestSelectDifficulty', diff)
		task.wait(0.25)
		local rf = RunLoops.knitRF('DungeonRunService', 'RequestDungeonChange')
		if not rf then
			return false
		end
		local ok, res = pcall(function()
			return rf:InvokeServer(id, diff)
		end)
		if not (ok and res ~= false) then
			return false
		end
		local conf = RunLoops.knitRF('DungeonRunService', 'ConfirmDungeonChange')
		if conf then
			pcall(function()
				return conf:InvokeServer()
			end)
		end
		return true
	end

	-- Auto replay: specific loop target wins; else next DisplayOrder; else RequestReplay.
	rt.dungeonUpgradeOrReplay = function(silent)
		if on('DLLoopSpecific') then
			return api.loopNow(silent)
		end
		local id, diff, name, score = api.pick()
		if not id or not diff then
			return false
		end
		local curScore, curId, curDiff = scoreCurrent()
		local same = tostring(id) == tostring(curId) and tostring(diff) == tostring(curDiff)
		local leaveEndless = tostring(curDiff) == 'Endless' and tostring(diff) ~= 'Endless'
		if same and not leaveEndless then
			return false
		end
		if not leaveEndless and (type(score) ~= 'number' or score <= curScore) then
			return false
		end
		if not requestDungeonChange(id, diff) then
			if not silent then
				Library:Notify(('Upgrade failed: %s · %s'):format(tostring(name or id), tostring(diff)))
			end
			return false
		end
		rt.runDungeonId, rt.runDifficulty = id, diff
		Library:Notify(('Auto upgrade → %s · %s'):format(tostring(name or id), tostring(diff)))
		return true
	end

	function api.run(silent)
		if busy then
			return false
		end
		if not inLobby() then
			if not silent then
				Library:Notify('Already in a dungeon')
			end
			return false
		end
		busy = true
		task.spawn(function()
			local id, diff, name
			if on('DLLoopSpecific') or on('DLHuntSpecial') then
				id, diff, name = api.target()
			end
			if not id or not diff then
				id, diff, name = api.pick()
			end
			if not id or not diff then
				busy = false
				if not silent then
					Library:Notify('No dungeon fits your level / unlocks')
				end
				return
			end
			local p = ensureOpen()
			if p then
				-- Friends Only ON blocks solo starts; turn it off when the title says ON.
				local friendsTitle = p:FindFirstChild('FriendsOnlyTitle', true)
				local friendsBtn = p:FindFirstChild('FriendsOnlyButton', true)
				if friendsTitle and friendsBtn and tostring(friendsTitle.Text):find('ON', 1, true) then
					clickGui(friendsBtn)
					task.wait(0.2)
				end
			end
			invoke('RequestSelectDungeon', id)
			task.wait(0.35)
			invoke('RequestSelectDifficulty', diff)
			task.wait(0.35)
			local ok, res = invoke('RequestStartSoloRun')
			if not ok or res == false then
				ok, res = invoke('RequestEnter')
			end
			if not ok or res == false then
				ok, res = invoke('RequestStartNow')
			end
			lastStart = os.clock()
			lastLabel = ('%s · %s'):format(tostring(name or id), tostring(diff))
			busy = false
			if not silent or res ~= false then
				Library:Notify(('Dungeon start: %s%s'):format(
					lastLabel, (res == false) and ' (server refused)' or ''))
			end
		end)
		return true
	end

	function api.onLobby()
		armedAt = os.clock()
	end

	function api.label()
		return lastLabel
	end

	function api.tick()
		if not on('DLAutoDungeon') and not on('DLLoopSpecific') and not on('DLHuntSpecial') then
			armedAt = 0
			return
		end
		if on('DLLoopSpecific') or on('DLHuntSpecial') then
			local id = select(1, api.target())
			if not id then
				return
			end
		end
		if not inLobby() then
			armedAt = 0
			return
		end
		if busy or os.clock() < nextCheck then
			return
		end
		local cool = (on('DLLoopSpecific') or on('DLHuntSpecial')) and 6 or 12
		if os.clock() - lastStart < cool then
			return
		end
		if armedAt == 0 then
			armedAt = os.clock()
			return
		end
		local delay = Options.DLDungeonDelay and tonumber(Options.DLDungeonDelay.Value) or 2
		if os.clock() - armedAt < delay then
			return
		end
		nextCheck = os.clock() + 4
		api.run(true)
	end

	return api
end)()

rt.requestHuntReturn = function()
	if rt.huntReturning then
		return
	end
	rt.huntReturning = true
	farmLabel = 'hunt · return lobby'
	Library:Notify(('Hunt kill · %s — lobby'):format(huntTargetNeedle()))
	task.spawn(function()
		local rf = RunLoops.knitRF('DungeonRunService', 'RequestReturn')
		if rf then
			pcall(function()
				rf:InvokeServer()
			end)
		end
		pcall(function()
			local pg = LocalPlayer:FindFirstChild('PlayerGui')
			local main = pg and pg:FindFirstChild('Main')
			if not main then
				return
			end
			for _, d in ipairs(main:GetDescendants()) do
				if d:IsA('TextButton') or d:IsA('ImageButton') then
					local t = string.lower(tostring(d.Text or d.Name or ''))
					if (t:find('return', 1, true) or t == 'lobby') and d.Visible ~= false then
						if type(firesignal) == 'function' then
							pcall(firesignal, d.MouseButton1Click)
						end
					end
				end
			end
		end)
		local deadline = os.clock() + 12
		while os.clock() < deadline and LocalPlayer:GetAttribute('InDungeon') == true do
			task.wait(0.4)
		end
		rt.huntReturning = false
		rt.huntKills = (rt.huntKills or 0) + 1
		DungeonStart.onLobby()
	end)
end

-- QuestService.ClaimQuest rejects every argument shape a quest id can take, so
-- claiming has to go through the Claim button's own handler. That handler also
-- closes over Knit, which is how we reach the replicated PlayerData holding the
-- authoritative Claimed flags — the green button itself is unreliable, because a
-- closed Quests panel keeps showing it long after the quest was claimed.
local QuestClaim = (function()
	local CATS = { 'Daily', 'Weekly', 'Limited' }
	local MAX_SLOTS = 12
	local api = {}

	function api.rows()
		local pg = LocalPlayer:FindFirstChildOfClass('PlayerGui')
		local main = pg and pg:FindFirstChild('Main')
		local frames = main and main:FindFirstChild('Frames')
		local quests = frames and frames:FindFirstChild('Quests')
		local content = quests and quests:FindFirstChild('Content')
		return content and content:FindFirstChild('ScrollingFrame')
	end

	local function claimConn(row)
		local comp = row and row:FindFirstChild('Complete')
		if not comp or type(getconnections) ~= 'function' then
			return nil
		end
		local ok, conns = pcall(getconnections, comp.MouseButton1Click)
		if not ok or type(conns) ~= 'table' then
			return nil
		end
		return conns[1]
	end
	api.conn = claimConn

	local cached
	local function playerData()
		if type(cached) == 'table' and type(cached.Quests) == 'table' then
			return cached
		end
		cached = nil
		local sf = api.rows()
		if not sf or type(debug) ~= 'table' or type(debug.getupvalues) ~= 'function' then
			return nil
		end
		for _, row in ipairs(sf:GetChildren()) do
			local conn = claimConn(row)
			if conn then
				local ok, ups = pcall(debug.getupvalues, conn.Function)
				if ok and type(ups) == 'table' then
					for _, up in pairs(ups) do
						if type(up) == 'table' and type(up.Registry) == 'table' then
							local entries = up.Registry._Entries
							local pd = entries and entries.PlayerData
							local data = pd and pd.Data
							if type(data) == 'table' and type(data.Quests) == 'table' then
								cached = data
								return data
							end
						end
					end
				end
			end
		end
		return nil
	end

	function api.state()
		local data = playerData()
		return data and data.Quests or nil
	end

	-- The store mutates slot entries in place, so re-index rather than caching one.
	local function entry(quests, cat, slot)
		local active = quests[cat] and quests[cat].Active
		return active and active[slot] or nil
	end

	function api.pending()
		local out = {}
		local quests = api.state()
		if not quests then
			return out, false
		end
		for _, cat in ipairs(CATS) do
			for slot = 1, MAX_SLOTS do
				local e = entry(quests, cat, slot)
				if type(e) == 'table' and e.Completed and not e.Claimed then
					out[#out + 1] = { cat = cat, slot = slot, id = e.QuestId }
				end
			end
		end
		return out, true
	end

	-- Returns claimed, stillPending, reachable.
	function api.claimAll()
		local sf = api.rows()
		local quests = api.state()
		if not sf or not quests then
			return 0, 0, false
		end
		local claimed, stuck = 0, 0
		for _, cat in ipairs(CATS) do
			for slot = 1, MAX_SLOTS do
				local e = entry(quests, cat, slot)
				if type(e) == 'table' and e.Completed and not e.Claimed then
					local conn = claimConn(sf:FindFirstChild(('Quest_%s_%d'):format(cat, slot)))
					if conn then
						-- The handler yields on its remote call, so it needs its own thread.
						task.spawn(function()
							pcall(conn.Function)
						end)
						local deadline = os.clock() + 3
						repeat
							task.wait(0.15)
							e = entry(quests, cat, slot)
						until (type(e) == 'table' and e.Claimed) or os.clock() > deadline
						if type(e) == 'table' and e.Claimed then
							claimed += 1
						else
							stuck += 1
						end
					end
				end
			end
		end
		return claimed, stuck, true
	end

	-- ClaimedFree / ClaimedPremium store the claimed tiers as a list of numbers.
	local function claimedTiers(list)
		local set = {}
		for k, v in pairs(list or {}) do
			if type(v) == 'number' then
				set[v] = true
			elseif v == true and type(k) == 'number' then
				set[k] = true
			end
		end
		return set
	end

	-- Battlepass is a separate service and, unlike the main quests, its remotes take
	-- plain arguments: ClaimQuest(index) and ClaimReward(tier, 'Free'|'Premium').
	-- Quests go first because each award raises the tier and unlocks more rewards.
	-- Returns questsClaimed, rewardsClaimed.
	function api.claimBattlepass()
		local data = playerData()
		local bp = data and data.Battlepass
		local claimQuest = RunLoops.knitRF('BattlepassService', 'ClaimQuest')
		local claimReward = RunLoops.knitRF('BattlepassService', 'ClaimReward')
		if type(bp) ~= 'table' or not claimQuest or not claimReward then
			return 0, 0
		end
		local quests, rewards = 0, 0
		for i, q in pairs(bp.Quests or {}) do
			if type(q) == 'table' and q.Completed and not q.Claimed then
				pcall(function()
					claimQuest:InvokeServer(i)
				end)
				task.wait(0.4)
				local now = bp.Quests[i]
				if type(now) == 'table' and now.Claimed then
					quests += 1
				end
			end
		end
		local tracks = { 'Free' }
		if bp.HasPremium then
			tracks[#tracks + 1] = 'Premium'
		end
		local tier = tonumber(bp.Tier) or 0
		for _, track in ipairs(tracks) do
			local function done()
				return claimedTiers(track == 'Free' and bp.ClaimedFree or bp.ClaimedPremium)
			end
			for t = 1, tier do
				if not done()[t] then
					pcall(function()
						claimReward:InvokeServer(t, track)
					end)
					task.wait(0.35)
					if done()[t] then
						rewards += 1
					end
				end
			end
		end
		return quests, rewards
	end

	function api.bpPending()
		local data = playerData()
		local bp = data and data.Battlepass
		if type(bp) ~= 'table' then
			return 0, 0
		end
		local quests = 0
		for _, q in pairs(bp.Quests or {}) do
			if type(q) == 'table' and q.Completed and not q.Claimed then
				quests += 1
			end
		end
		local free = claimedTiers(bp.ClaimedFree)
		local tiers = 0
		for t = 1, tonumber(bp.Tier) or 0 do
			if not free[t] then
				tiers += 1
			end
		end
		return quests, tiers
	end

	return api
end)()

local function listChallengeMilestones()
	local list = {}
	local gi = game:GetService('ReplicatedStorage'):FindFirstChild('GameInfo')
	local mod = gi and gi:FindFirstChild('ChallengeRewardData')
	if not mod or not mod:IsA('ModuleScript') then
		return list
	end
	local ok, data = pcall(require, mod)
	if not ok or type(data) ~= 'table' or type(data.MILESTONES) ~= 'table' then
		return list
	end
	for k, v in pairs(data.MILESTONES) do
		if type(k) == 'number' then
			list[#list + 1] = k
		elseif type(v) == 'table' and (v.Floor or v.Id) then
			list[#list + 1] = v.Floor or v.Id
		elseif type(k) == 'string' then
			list[#list + 1] = k
		end
	end
	table.sort(list, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return list
end

local function claimAllQuests(silent)
	if questBusy then
		if not silent then
			Library:Notify('Quest claim already running')
		end
		return
	end
	questBusy = true
	if not silent then
		Library:Notify('Claiming quests…')
	end
	task.spawn(function()
		local claimed, failed = 0, 0
		local achAll = RunLoops.knitRF('AchievementService', 'ClaimAll')
		if achAll then
			local ok, result = pcall(function()
				return achAll:InvokeServer()
			end)
			print('[DL] ClaimAll achievements', ok, tostring(result):sub(1, 80))
			if ok and result ~= false then
				claimed += 1
			end
		end
		local questsClaimed, questsStuck, reachable = QuestClaim.claimAll()
		claimed += questsClaimed
		failed += questsStuck
		if not reachable and not silent then
			Library:Notify('Quest state unreachable — open the Quests menu once', 6)
		end
		local bpQuests, bpRewards = QuestClaim.claimBattlepass()
		claimed += bpQuests + bpRewards
		local claimCh = RunLoops.knitRF('ChallengeRewardService', 'ClaimReward')
		if claimCh then
			for _, ms in ipairs(listChallengeMilestones()) do
				pcall(function()
					claimCh:InvokeServer(ms)
				end)
				task.wait(0.12)
			end
			pcall(function()
				claimCh:InvokeServer()
			end)
		end
		questBusy = false
		lastQuestAuto = os.clock()
		local msg = ('Quests  claimed %s  (bp %s quests / %s tiers)  other %s'):format(
			fmtNum(claimed),
			fmtNum(bpQuests),
			fmtNum(bpRewards),
			fmtNum(failed)
		)
		if not silent then
			Library:Notify(msg, 6)
		end
		print('[DL]', msg)
	end)
end

-- ── Settings autosave ──
-- Ataraxia profiles: shared list per game folder, autoload per Roblox account.
local Config = (function()
	local Cfg = Library.Config
	Library:SetFolder('dungeon-lootr')
	Cfg.IgnoreIndexes({ DLPlayerList = true, DLSpectate = true })

	local api = {}

	function api.saveNow()
		return Cfg.SaveCurrent()
	end

	function api.queue()
		Cfg.Queue()
	end

	function api.tick()
		Cfg.Tick()
	end

	function api.hook()
		Cfg.Hook()
	end

	function api.load()
		if Cfg.HasState() then
			return Cfg.LoadAutoload()
		end
		-- Old global settings.json → this account only (does not autoload on alts).
		if type(isfile) == 'function' and isfile('dungeon-lootr/settings.json') then
			Cfg.ImportFile('dungeon-lootr/settings.json')
			Cfg.SaveAccount()
			-- Consume the old global file so alts do not inherit this account's setup.
			pcall(function()
				if type(writefile) == 'function' and type(readfile) == 'function' then
					writefile('dungeon-lootr/settings.migrated.json', readfile('dungeon-lootr/settings.json'))
				end
				if type(delfile) == 'function' then
					delfile('dungeon-lootr/settings.json')
				end
			end)
			return 1
		end
		return Cfg.LoadAutoload()
	end

	function api.reset()
		Cfg.Reset()
	end

	function api.finish()
		Cfg.Finish()
	end

	return api
end)()

-- Level-up skill points. StatService is the same surface the game's own stat panel
-- uses: GetSkillPoints reports { Unspent = n, Allocated = { STR = n, ... } },
-- AllocatePoint(name) spends one and AllocatePoints(name, count) batches.
-- Respec is the Inventory → Stat Upgrades RESET button. SetStat / SetStatPoints
-- write values outright rather than spending earned points, so those stay unused.
local Stats = (function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local POLL = 5
	local AUTO_EVERY = 8
	local api = { NAMES = { 'STR', 'DEX', 'INT', 'LCK', 'VIT' } }
	local rf, cache, cacheAt, nextAuto, label, labelAt = nil, nil, 0, 0, nil, 0

	local function remotes()
		if rf and rf.Parent then
			return rf
		end
		local ok, folder = pcall(function()
			return ReplicatedStorage.Packages._Index['sleitnick_knit@1.7.0'].knit.Services.StatService.RF
		end)
		rf = (ok and folder) or nil
		return rf
	end

	function api.points(fresh)
		if not fresh and cache and os.clock() - cacheAt < POLL then
			return cache
		end
		local folder = remotes()
		local get = folder and folder:FindFirstChild('GetSkillPoints')
		if not get then
			return nil
		end
		local ok, res = pcall(function()
			return get:InvokeServer()
		end)
		if ok and type(res) == 'table' then
			cache, cacheAt = res, os.clock()
			return res
		end
		return nil
	end

	function api.unspent(fresh)
		local p = api.points(fresh)
		return p and tonumber(p.Unspent) or 0
	end

	-- Reports how many points actually landed, measured against the server rather
	-- than trusting the remote's own return value.
	function api.spend(name, count)
		local folder = remotes()
		if not folder or count <= 0 then
			return 0
		end
		local before = api.unspent(true)
		if before <= 0 then
			return 0
		end
		count = math.min(count, before)
		local batch = (count > 1) and folder:FindFirstChild('AllocatePoints') or nil
		if batch then
			pcall(function()
				batch:InvokeServer(name, count)
			end)
		else
			local one = folder:FindFirstChild('AllocatePoint')
			if not one then
				return 0
			end
			for _ = 1, count do
				local ok, res = pcall(function()
					return one:InvokeServer(name)
				end)
				if not ok or res == false then
					break
				end
			end
		end
		return math.max(0, before - api.unspent(true))
	end

	function api.picked()
		local v = Options.DLStatPick and Options.DLStatPick.Value
		local set = {}
		if type(v) == 'table' then
			for k, val in pairs(v) do
				if type(k) == 'string' and val == true then
					set[k] = true
				elseif type(val) == 'string' then
					set[val] = true
				end
			end
		elseif type(v) == 'string' and v ~= '' then
			set[v] = true
		end
		-- Canonical order, so an even split is deterministic run to run.
		local list = {}
		for _, name in ipairs(api.NAMES) do
			if set[name] then
				list[#list + 1] = name
			end
		end
		return list
	end

	-- Split everything unspent across the picked stats; remainder to the first ones.
	function api.spendAll(silent)
		local picks = api.picked()
		if #picks == 0 then
			if not silent then
				Library:Notify('Pick at least one stat first')
			end
			return 0
		end
		local pool = api.unspent(true)
		if pool <= 0 then
			if not silent then
				Library:Notify('No unspent skill points')
			end
			return 0
		end
		local per = math.floor(pool / #picks)
		local extra = pool - per * #picks
		local spent = 0
		for i, name in ipairs(picks) do
			local want = per + ((i <= extra) and 1 or 0)
			if want > 0 then
				spent += api.spend(name, want)
			end
		end
		if spent > 0 and not silent then
			Library:Notify(('Spent %d point%s · %s'):format(spent, spent == 1 and '' or 's', table.concat(picks, '/')))
		end
		labelAt = 0
		return spent
	end

	function api.allocated(fresh)
		local p = api.points(fresh)
		if not p or type(p.Allocated) ~= 'table' then
			return 0
		end
		local n = 0
		for _, name in ipairs(api.NAMES) do
			n += tonumber(p.Allocated[name]) or 0
		end
		return n
	end

	-- Inventory → Stat Upgrades → RESET. Refunds allocated points to Unspent.
	function api.respec(silent)
		local folder = remotes()
		local rem = folder and folder:FindFirstChild('Respec')
		if not rem then
			if not silent then
				Library:Notify('StatService.Respec missing')
			end
			return false, 'missing'
		end
		local used = api.allocated(true)
		if used <= 0 then
			if not silent then
				Library:Notify('No allocated points to reset')
			end
			return false, 'none'
		end
		local ok, res = pcall(function()
			return rem:InvokeServer()
		end)
		if not ok then
			if not silent then
				Library:Notify('Reset failed: ' .. tostring(res))
			end
			return false, tostring(res)
		end
		if res == false or (type(res) == 'table' and res.Success == false) then
			local why = 'server refused'
			if type(res) == 'table' then
				why = tostring(res.Error or res.Reason or res.Message or why)
			end
			if not silent then
				Library:Notify('Reset refused: ' .. why)
			end
			return false, why
		end
		cache, cacheAt, labelAt = nil, 0, 0
		local after = api.unspent(true)
		if not silent then
			Library:Notify(('Reset stats · %d unspent'):format(after))
		end
		if on('DLAutoStat') then
			task.spawn(api.spendAll, true)
		end
		return true, after
	end

	function api.setLabel(obj)
		label = obj
	end

	function api.tick()
		if label and label.SetText and os.clock() - labelAt > 1 then
			labelAt = os.clock()
			local lvl = LocalPlayer:GetAttribute('PlayerLevel')
			local p = api.points()
			if p then
				local parts = {}
				for _, name in ipairs(api.NAMES) do
					local n = (p.Allocated and tonumber(p.Allocated[name])) or 0
					parts[#parts + 1] = ('%s %d'):format(name, n)
				end
				label:SetText(('Level %s · %d unspent · %s'):format(
					tostring(lvl or '?'), tonumber(p.Unspent) or 0, table.concat(parts, '  ')))
			else
				label:SetText(('Level %s · points unavailable'):format(tostring(lvl or '?')))
			end
		end
		if not on('DLAutoStat') or os.clock() < nextAuto then
			return
		end
		nextAuto = os.clock() + AUTO_EVERY
		if api.unspent() > 0 then
			api.spendAll(true)
		end
	end

	return api
end)()

-- Auto-equip. Every fact needed to rank an item is already in PlayerData — GUID,
-- Slot, Rarity, LevelReq, EnchantLevel, BaseDamage — so ranking happens locally and
-- only the winning swap costs a remote call. Rarity leads the ordering because it
-- scales every roll on an item, and the ordering itself comes from the game's own
-- RarityData.RarityIndex rather than a guessed list. Where the server publishes
-- Stat_GearScore, each swap is checked against it and rolled back if the number
-- drops, so a wrong guess never leaves gear worse than it found it.
local Gear = (function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local KNIT = 'sleitnick_knit@1.7.0'
	local AUTO_EVERY = 4
	-- Only used if RarityData cannot be read; kept in the game's own order.
	local FALLBACK_RANK = {
		Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5,
		Mythic = 6, Celestial = 7, Impossible = 8, Exotic = 9, Admin = 11, Owner = 12,
	}
	local api = {}
	local rankMap, templates, nextAuto, label, labelAt = nil, nil, 0, nil, 0
	local hasLifesteal, isLifestealKey, lifestealAmount
	-- Candidates the gear score rejected. Without this the ranking would re-propose
	-- the same losing swap every cycle and equip/revert forever. Keyed by enchant
	-- level too, so upgrading an item puts it back in the running.
	local rejected = {}

	local function rejectKey(slot, item)
		return ('%s|%s|%s'):format(tostring(slot), tostring(item.GUID), tostring(item.EnchantLevel or 0))
	end

	-- Resolved on every call, never cached: the replicated Services folder briefly
	-- disappears while joining or teleporting, and a cached reference goes stale.
	local function knitRoot()
		local ok, mod = pcall(function()
			return ReplicatedStorage.Packages._Index[KNIT].knit
		end)
		return (ok and mod) or nil
	end

	-- PlayerData comes off the Knit registry rather than being scraped out of a UI
	-- panel: panels are destroyed when closed, the registry survives.
	function api.data()
		local mod = knitRoot()
		if not mod then
			return nil
		end
		local ok, K = pcall(require, mod)
		if not ok or type(K) ~= 'table' then
			return nil
		end
		local reg = rawget(K, 'Registry')
		local entries = (type(reg) == 'table') and reg._Entries or nil
		local pd = entries and entries.PlayerData
		local d = pd and pd.Data
		return (type(d) == 'table') and d or nil
	end

	local function equipmentRF(name)
		local mod = knitRoot()
		local svcs = mod and mod:FindFirstChild('Services')
		local es = svcs and svcs:FindFirstChild('EquipmentService')
		local rf = es and es:FindFirstChild('RF')
		return (rf and rf:FindFirstChild(name)) or nil
	end

	local function equipRemote()
		return equipmentRF('Equip')
	end

	local function collectPending()
		local rem = equipmentRF('CollectAll')
		if not rem then
			return
		end
		pcall(function()
			return rem:InvokeServer()
		end)
	end

	local function sellRemote()
		local mod = knitRoot()
		local svcs = mod and mod:FindFirstChild('Services')
		local shop = svcs and svcs:FindFirstChild('ShopService')
		local rf = shop and shop:FindFirstChild('RF')
		return (rf and rf:FindFirstChild('SellEquipment')) or nil
	end

	local function deleteRemote()
		local mod = knitRoot()
		local svcs = mod and mod:FindFirstChild('Services')
		local es = svcs and svcs:FindFirstChild('EquipmentService')
		local rf = es and es:FindFirstChild('RF')
		return (rf and rf:FindFirstChild('DeleteItem')) or nil
	end

	local function rank(rarity)
		if not rankMap then
			local ok, rd = pcall(require, ReplicatedStorage.GameInfo.RarityData)
			rankMap = (ok and type(rd) == 'table' and type(rd.RarityIndex) == 'table')
				and rd.RarityIndex or FALLBACK_RANK
		end
		return tonumber(rankMap[rarity or '']) or 0
	end

	-- EquipTier separates same-rarity items: it is the item's own power band.
	local function tier(itemId)
		if templates == nil then
			local ok, t = pcall(require, ReplicatedStorage.GameInfo.EquipmentTemplates)
			templates = (ok and type(t) == 'table' and type(t.GetTemplate) == 'function') and t or false
		end
		if not templates or not itemId then
			return 0
		end
		local ok, tpl = pcall(function()
			if templates.GetTemplate then
				return templates:GetTemplate(itemId)
			end
			return nil
		end)
		return (ok and type(tpl) == 'table' and tonumber(tpl.EquipTier)) or 0
	end

	-- Rings: lifesteal amount is the whole ranking (best LS wins, even a Common
	-- 2% over a Mythic 1%). Other slots: any LS still beats non-LS, then rarity.
	function api.score(item)
		if type(item) ~= 'table' then
			return -1
		end
		local s = rank(item.Rarity) * 10000
		s += tier(item.ItemId) * 500
		s += (tonumber(item.LevelReq) or 0) * 20
		s += (tonumber(item.EnchantLevel) or 0) * 10
		s += tonumber(item.BaseDamage) or 0
		local g = item.GuaranteedStat
		if type(g) == 'table' then
			s += (tonumber(g.Value) or 0) * 0.1
		end
		local ls = 0
		if type(lifestealAmount) == 'function' then
			ls = lifestealAmount(item)
		end
		if tostring(item.Slot) == 'Ring' then
			s += ls * 100000
		elseif ls > 0 then
			s += 1000000 + ls * 100
		end
		return s
	end

	-- The attribute is absent while joining, so the saved value leads.
	local function level(d)
		return tonumber(d.PlayerLevel) or tonumber(LocalPlayer:GetAttribute('PlayerLevel')) or 0
	end

	-- Locked is deliberately ignored: it protects an item from being sold, not worn.
	local function usable(item, lvl)
		return type(item) == 'table'
			and type(item.GUID) == 'string'
			and type(item.Slot) == 'string'
			and item.Identified ~= false
			and (tonumber(item.LevelReq) or 0) <= lvl
	end

	-- Slots are discovered from the data instead of a hardcoded Head/Body/Ring list,
	-- so slots unlocked later are picked up without editing this.
	function api.plan()
		local d = api.data()
		if not d or type(d.EquipmentInventory) ~= 'table' then
			return {}, nil
		end
		local lvl = level(d)
		local worn = (type(d.Equipment) == 'table') and d.Equipment or {}
		local best = {}
		for _, item in pairs(d.EquipmentInventory) do
			if usable(item, lvl) and not rejected[rejectKey(item.Slot, item)] then
				local cur = best[item.Slot]
				local take = not cur
				if cur and tostring(item.Slot) == 'Ring' then
					local la = lifestealAmount(item)
					local lb = lifestealAmount(cur)
					take = la > lb
				elseif cur then
					take = api.score(item) > api.score(cur)
				end
				if take then
					best[item.Slot] = item
				end
			end
		end
		local ups = {}
		for slot, item in pairs(best) do
			local wornItem = worn[slot]
			local take = false
			if tostring(slot) == 'Ring' then
				local la = lifestealAmount(item)
				local lb = lifestealAmount(wornItem)
				-- Rings only move for strictly more lifesteal — never rarity/damage.
				take = la > lb
			else
				take = api.score(item) > api.score(wornItem)
			end
			if take then
				ups[#ups + 1] = { slot = slot, item = item, worn = wornItem }
			end
		end
		table.sort(ups, function(a, b)
			return a.slot < b.slot
		end)
		return ups, d
	end

	local function invokeEquip(remote, guid, slot)
		local ok, res = pcall(function()
			return remote:InvokeServer(guid)
		end)
		if ok and res ~= false then
			return true
		end
		ok, res = pcall(function()
			return remote:InvokeServer(guid, slot)
		end)
		if ok and res ~= false then
			return true
		end
		ok, res = pcall(function()
			return remote:InvokeServer({ GUID = guid, Slot = slot })
		end)
		return ok and res ~= false
	end

	function api.apply(silent)
		collectPending()
		local ups = api.plan()
		if #ups == 0 then
			if not silent then
				Library:Notify('Already wearing the best you own')
			end
			return 0
		end
		local remote = equipRemote()
		if not remote then
			if not silent then
				Library:Notify('EquipmentService not ready yet')
			end
			return 0
		end
		local swapped, reverted = 0, 0
		for _, up in ipairs(ups) do
			local before = tonumber(LocalPlayer:GetAttribute('Stat_GearScore'))
			if invokeEquip(remote, up.item.GUID, up.slot) then
				task.wait(0.22)
				local after = tonumber(LocalPlayer:GetAttribute('Stat_GearScore'))
				-- Judged only when the server actually publishes a score, and only a
				-- genuine drop counts as a mistake worth undoing.
				local keepLs = lifestealAmount(up.item) > lifestealAmount(up.worn)
				if before and after and after < before and up.worn and type(up.worn.GUID) == 'string' and not keepLs then
					invokeEquip(remote, up.worn.GUID, up.slot)
					rejected[rejectKey(up.slot, up.item)] = true
					reverted += 1
					task.wait(0.2)
				else
					swapped += 1
				end
			end
		end
		labelAt = 0
		if swapped > 0 or reverted > 0 or not silent then
			Library:Notify(('Equipped %d · reverted %d'):format(swapped, reverted))
		end
		return swapped
	end

	-- Junk = the equipped piece in that slot would show this item's main stat as
	-- red (▼). Rings use BaseDamage; Head/Body use GuaranteedStat. LevelReq is
	-- ignored — a 72 ring with worse damage than the 70 you wear is still junk.
	-- Locked, Judgement-named, Lifesteal, and weapons stay.
	local SELL_SLOTS = { Head = true, Body = true, Ring = true }
	local KEEP_NAME = {
		'judgement', 'judgment',
	}

	local function itemLabel(item)
		return (
			tostring(item.DisplayName or '')
			.. ' '
			.. tostring(item.Name or '')
			.. ' '
			.. tostring(item.ItemId or '')
		):lower()
	end

	-- EquipmentData.StatDisplayNames.LifeSteal = "Lifesteal". Rolled lines live
	-- on item.Stats; guaranteed lines use GuaranteedStat.StatKey.
	isLifestealKey = function(s)
		s = string.lower((tostring(s or ''):gsub('[^%a]', '')))
		return s:find('lifesteal', 1, true) ~= nil
	end

	lifestealAmount = function(item)
		if type(item) ~= 'table' then
			return 0
		end
		local best = 0
		local function take(v)
			if type(v) == 'table' then
				v = v.Value or v.Amount or v.Magnitude or v.Percent
			end
			v = tonumber(v)
			if v and v > best then
				best = v
			end
		end
		local function consider(node, depth)
			if depth > 5 or type(node) ~= 'table' then
				return
			end
			if isLifestealKey(node.StatKey)
				or isLifestealKey(node.Key)
				or isLifestealKey(node.Name)
				or isLifestealKey(node.DisplayName)
				or isLifestealKey(node.Computed)
			then
				take(node)
			end
			for k, v in pairs(node) do
				if isLifestealKey(k) then
					take(v)
				end
				if type(v) == 'table' then
					consider(v, depth + 1)
				end
			end
		end
		consider(item.GuaranteedStat, 0)
		consider(item.Stats, 0)
		take(item.LifeSteal)
		return best
	end

	hasLifesteal = function(item)
		return lifestealAmount(item) > 0
	end

	local function mustKeep(item)
		if type(item) ~= 'table' then
			return true
		end
		if item.Locked == true then
			return true
		end
		if not SELL_SLOTS[tostring(item.Slot or '')] then
			return true
		end
		if hasLifesteal(item) then
			return true
		end
		local label = itemLabel(item)
		for _, needle in ipairs(KEEP_NAME) do
			if label:find(needle, 1, true) then
				return true
			end
		end
		return false
	end

	-- Same number the inventory paints green ▲ / red ▼ against the worn piece.
	local function primaryPower(item)
		if type(item) ~= 'table' then
			return nil, 0
		end
		local bd = tonumber(item.BaseDamage)
		if bd then
			return 'BaseDamage', bd
		end
		local g = item.GuaranteedStat
		if type(g) == 'table' then
			return tostring(g.StatKey or g.Key or 'G'), tonumber(g.Value) or 0
		end
		return nil, 0
	end

	local function isDowngrade(item, eq)
		if type(eq) ~= 'table' then
			return false
		end
		local ik, iv = primaryPower(item)
		local ek, ev = primaryPower(eq)
		if ik and ek and ik == ek then
			return iv < ev
		end
		if ik == 'BaseDamage' and ev then
			return iv < ev
		end
		if iv and (not ev or ev == 0) then
			return false
		end
		return api.score(item) < api.score(eq)
	end

	function api.junkList()
		local d = api.data()
		if not d or type(d.EquipmentInventory) ~= 'table' then
			return {}
		end
		local worn = (type(d.Equipment) == 'table') and d.Equipment or {}
		local wornGuid = {}
		for _, w in pairs(worn) do
			if type(w) == 'table' and type(w.GUID) == 'string' then
				wornGuid[w.GUID] = true
			end
		end
		local list = {}
		for _, item in pairs(d.EquipmentInventory) do
			if type(item) == 'table'
				and type(item.GUID) == 'string'
				and type(item.Slot) == 'string'
				and item.Identified ~= false
				and not wornGuid[item.GUID]
				and not mustKeep(item)
			then
				local eq = worn[item.Slot]
				if type(eq) == 'table' and isDowngrade(item, eq) then
					list[#list + 1] = item
				end
			end
		end
		table.sort(list, function(a, b)
			return api.score(a) < api.score(b)
		end)
		return list
	end

	function api.sellJunk(silent)
		collectPending()
		local list = api.junkList()
		if #list == 0 then
			if not silent then
				Library:Notify('No junk to clear')
			end
			return 0
		end
		local mode = Options.DLJunkMode and tostring(Options.DLJunkMode.Value) or 'Sell'
		local guids = {}
		for _, item in ipairs(list) do
			guids[#guids + 1] = item.GUID
		end
		local cleared = 0
		if mode == 'Delete' then
			local rem = deleteRemote()
			if not rem then
				if not silent then
					Library:Notify('DeleteItem remote missing')
				end
				return 0
			end
			for _, guid in ipairs(guids) do
				local ok, res = pcall(function()
					return rem:InvokeServer(guid)
				end)
				if not ok or res == false then
					ok, res = pcall(function()
						return rem:InvokeServer({ guid })
					end)
				end
				if ok and res ~= false then
					cleared += 1
				end
				task.wait(0.12)
			end
		else
			local rem = sellRemote()
			if not rem then
				if not silent then
					Library:Notify('SellEquipment remote missing')
				end
				return 0
			end
			-- ShopService.SellEquipment iterates a GUID list (a bare string errors).
			local ok, res = pcall(function()
				return rem:InvokeServer(guids)
			end)
			if ok and res ~= false then
				cleared = #guids
			elseif not silent then
				Library:Notify('Sell refused')
				return 0
			end
		end
		labelAt = 0
		if not silent or cleared > 0 then
			Library:Notify(('%s %d junk item%s'):format(
				mode == 'Delete' and 'Deleted' or 'Sold',
				cleared,
				cleared == 1 and '' or 's'))
		end
		return cleared
	end

	function api.setLabel(obj)
		label = obj
	end

	local viewLabel

	function api.setView(obj)
		viewLabel = obj
	end

	local function itemLine(item, slotHint)
		if type(item) ~= 'table' then
			return ('%s  —'):format(slotHint or '?')
		end
		local slot = tostring(item.Slot or slotHint or '?')
		local rare = tostring(item.Rarity or '?')
		local name = tostring(item.DisplayName or item.Name or item.ItemId or '?')
		local bits = { rare, slot, name }
		if hasLifesteal(item) then
			bits[#bits + 1] = 'LS'
		end
		local enc = tonumber(item.EnchantLevel)
		if enc and enc > 0 then
			bits[#bits + 1] = ('+%d'):format(enc)
		end
		if item.Locked == true then
			bits[#bits + 1] = 'lock'
		end
		return table.concat(bits, '  ')
	end

	local STACK_NAME = {
		SmallHealPercent = 'Rejuvenation Tonic',
		ClassXPEssence = 'Class XP Essence',
		AspectGem = 'Aspect Gem',
		ProtectionScroll = 'Protection Scroll',
		LuckPotionT1 = 'Luck Potion T1',
		LuckPotionT2 = 'Luck Potion T2',
		LuckPotionT3 = 'Luck Potion T3',
	}

	local function stackLabel(id, count)
		return ('%s  x%s'):format(STACK_NAME[id] or tostring(id), tostring(count))
	end

	local function addStackMap(values, title, map)
		if type(map) ~= 'table' then
			return 0
		end
		local rows = {}
		for k, v in pairs(map) do
			local n = tonumber(v)
			if n and n > 0 then
				rows[#rows + 1] = { tostring(k), n }
			end
		end
		table.sort(rows, function(a, b)
			if a[2] == b[2] then
				return a[1] < b[1]
			end
			return a[2] > b[2]
		end)
		if #rows == 0 then
			return 0
		end
		values[#values + 1] = ('— %s —'):format(title)
		for _, row in ipairs(rows) do
			values[#values + 1] = stackLabel(row[1], row[2])
		end
		return #rows
	end

	function api.invLines()
		local d = api.data()
		if not d then
			return { 'Inventory unavailable' }, 'Inventory unavailable'
		end
		local values = { '— Worn —' }
		for _, slot in ipairs({ 'Head', 'Body', 'Ring', 'Weapon' }) do
			values[#values + 1] = itemLine(d.Equipment and d.Equipment[slot], slot)
		end
		local bag = {}
		for _, item in pairs(d.EquipmentInventory or {}) do
			if type(item) == 'table' then
				bag[#bag + 1] = item
			end
		end
		table.sort(bag, function(a, b)
			return api.score(a) > api.score(b)
		end)
		values[#values + 1] = ('— Extra gear  %d —'):format(#bag)
		if #bag == 0 then
			values[#values + 1] = '(none)'
		else
			for i, item in ipairs(bag) do
				if i <= 30 then
					values[#values + 1] = itemLine(item)
				end
			end
			if #bag > 30 then
				values[#values + 1] = ('… +%d more'):format(#bag - 30)
			end
		end
		local stacks = 0
		stacks += addStackMap(values, 'Potions', d.Potions)
		stacks += addStackMap(values, 'Consumables', d.Consumables)
		stacks += addStackMap(values, 'Buffs', d.BuffPotions)
		stacks += addStackMap(values, 'Materials', d.CraftingMaterials)
		local keys = {}
		if type(d.Keys) == 'table' then
			for k, v in pairs(d.Keys) do
				keys['Key ' .. tostring(k)] = v
			end
		end
		stacks += addStackMap(values, 'Keys', keys)
		local extra = {}
		if tonumber(d.ProtectionScrolls) and d.ProtectionScrolls > 0 then
			extra['Protection Scroll'] = d.ProtectionScrolls
		end
		if tonumber(d.NormalSpins) and d.NormalSpins > 0 then
			extra['Normal Spin'] = d.NormalSpins
		end
		if tonumber(d.LuckySpins) and d.LuckySpins > 0 then
			extra['Lucky Spin'] = d.LuckySpins
		end
		stacks += addStackMap(values, 'Other', extra)
		local head = ('Your inventory  %d extra gear  ·  %d stacks  (not loot bag)'):format(#bag, stacks)
		return values, head
	end

	function api.summary()
		local _, head = api.invLines()
		return head
	end

	function api.setDrop(obj)
		rt.invDrop = obj
	end

	function api.refreshDrop()
		local drop = rt.invDrop
		if not drop or not drop.SetValues then
			return
		end
		local values = api.invLines()
		drop:SetValues(values)
	end

	local function gameInvFrame()
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		local main = pg and pg:FindFirstChild('Main')
		local frames = main and main:FindFirstChild('Frames')
		return frames and frames:FindFirstChild('Inventory'), main
	end

	local function hudInvButton(main)
		local hud = main and main:FindFirstChild('HUD')
		local actions = hud and hud:FindFirstChild('Actions')
		local left = actions and actions:FindFirstChild('Left')
		local buttons = left and left:FindFirstChild('Buttons')
		return buttons and buttons:FindFirstChild('Inventory')
	end

	local function gameInvObj()
		local ps = LocalPlayer:FindFirstChild('PlayerScripts')
		local client = ps and ps:FindFirstChild('Client')
		local ctrls = client and client:FindFirstChild('Controllers')
		local mod = ctrls and ctrls:FindFirstChild('UIController')
		if not mod then
			return nil
		end
		local ok, UI = pcall(require, mod)
		if not ok or type(UI) ~= 'table' then
			return nil
		end
		return UI.names and UI.names.Inventory
	end

	local function hideDungeonLootOverlay(main)
		local hud = main and main:FindFirstChild('HUD')
		local overlay = hud and hud:FindFirstChild('Dungeon_Loot')
		if overlay then
			overlay.Visible = false
		end
	end

	local function showItemGrid(inv)
		local contents = inv and inv:FindFirstChild('Contents')
		if not contents then
			return
		end
		local section = contents:FindFirstChild('InventorySection')
		if section then
			section.Visible = true
		end
		for _, name in ipairs({ 'StatUpgrade', 'Loadouts', 'StatInfo' }) do
			local other = contents:FindFirstChild(name)
			if other then
				other.Visible = false
			end
		end
	end

	function api.pinGameInv()
		local obj = gameInvObj()
		if obj and obj.isOpen ~= true and type(obj.open) == 'function' then
			pcall(function()
				obj:open()
			end)
		end
		local inv, main = gameInvFrame()
		if not inv then
			return false
		end
		inv.Visible = true
		inv.Active = true
		showItemGrid(inv)
		hideDungeonLootOverlay(main)
		local btn = hudInvButton(main)
		if btn then
			btn.Visible = true
			btn.Active = true
			if not rt.invBtnHooked then
				rt.invBtnHooked = true
				btn.MouseButton1Click:Connect(function()
					api.toggleGameInv()
				end)
			end
		end
		return true
	end

	local function gameForgeFrame()
		local pg = LocalPlayer:FindFirstChild('PlayerGui')
		local main = pg and pg:FindFirstChild('Main')
		local frames = main and main:FindFirstChild('Frames')
		return frames and frames:FindFirstChild('Forge'), main
	end

	local function hudCraftButton(main)
		local hud = main and main:FindFirstChild('HUD')
		local function findBtn(root)
			if not root then
				return nil
			end
			local craft = root:FindFirstChild('Craft')
			if not craft then
				local buttons = root:FindFirstChild('Buttons')
				craft = buttons and buttons:FindFirstChild('Craft')
			end
			if not craft then
				return nil
			end
			if craft:IsA('GuiButton') then
				return craft
			end
			return craft:FindFirstChildWhichIsA('GuiButton', true)
		end
		local btn = findBtn(hud and hud:FindFirstChild('Left'))
		if btn then
			return btn
		end
		local actions = hud and hud:FindFirstChild('Actions')
		return findBtn(actions and actions:FindFirstChild('Left'))
	end

	function api.pinGameForge()
		local forge, main = gameForgeFrame()
		if not forge then
			return false
		end
		local btn = hudCraftButton(main)
		if btn then
			btn.Visible = true
			btn.Active = true
			local holder = btn.Parent
			if holder and holder:IsA('GuiObject') then
				holder.Visible = true
			end
			if forge.Visible ~= true and os.clock() - (rt.forgeClickAt or 0) > 0.8 then
				rt.forgeClickAt = os.clock()
				pcall(clickGuiButton, btn)
			end
		end
		-- Forge is not in UIController.names, so :open() cannot be used.
		forge.Visible = true
		forge.Active = true
		local contents = forge:FindFirstChild('Contents')
		if contents then
			contents.Visible = true
		end
		hideDungeonLootOverlay(main)
		return true
	end

	function api.toggleGameForge(force)
		local forge = gameForgeFrame()
		if not forge then
			Library:Notify('Forge frame missing')
			return false
		end
		local want = force
		if want == nil then
			want = forge.Visible ~= true
		end
		rt.forgeOpen = want == true
		if rt.forgeOpen then
			if rt.invOpen then
				api.toggleGameInv(false)
			end
			api.pinGameForge()
			Library:Notify('Forge open')
		else
			local exit = forge:FindFirstChild('Exit')
			if exit then
				pcall(clickGuiButton, exit)
			end
			forge.Visible = false
			Library:Notify('Forge closed')
		end
		return rt.forgeOpen
	end

	function api.toggleGameInv(force)
		local obj = gameInvObj()
		local inv, main = gameInvFrame()
		if not inv and not obj then
			Library:Notify('Inventory frame missing')
			return false
		end
		local want = force
		if want == nil then
			if obj ~= nil then
				want = obj.isOpen ~= true
			else
				want = not (rt.invOpen == true)
			end
		end
		rt.invOpen = want == true
		if rt.invOpen then
			if obj and type(obj.open) == 'function' then
				pcall(function()
					obj:open()
				end)
			end
			api.pinGameInv()
			pcall(api.refreshDrop)
			Library:Notify('Inventory open')
		else
			if obj and type(obj.close) == 'function' then
				pcall(function()
					obj:close()
				end)
			elseif inv then
				inv.Visible = false
			end
			Library:Notify('Inventory closed')
		end
		return rt.invOpen
	end

	function api.tick()
		if label and label.SetText and os.clock() - labelAt > 2 then
			labelAt = os.clock()
			local d = api.data()
			if d then
				local ups = api.plan()
				local junk = api.junkList()
				local gs = tonumber(LocalPlayer:GetAttribute('Stat_GearScore'))
				label:SetText(('Gear score %s · %d up · %d junk'):format(
					gs and tostring(gs) or (tostring(d.PeakGearScore or '?') .. ' peak'),
					#ups,
					#junk))
			else
				label:SetText('Inventory unavailable')
			end
		end
		if os.clock() - (rt.invViewAt or 0) > 2 then
			rt.invViewAt = os.clock()
			if viewLabel and viewLabel.SetText then
				pcall(function()
					viewLabel:SetText(api.summary())
				end)
			end
			pcall(api.refreshDrop)
		end
		if rt.invOpen or on('DLInvPin') then
			pcall(api.pinGameInv)
		end
		if rt.forgeOpen then
			pcall(api.pinGameForge)
		end
		if on('DLAutoGear') and os.clock() >= nextAuto then
			nextAuto = os.clock() + AUTO_EVERY
			api.apply(true)
		end
		if on('DLAutoJunk') and os.clock() >= (rt.junkAt or 0) then
			rt.junkAt = os.clock() + 8
			-- Equip first so the old piece becomes junk instead of staying worn.
			if on('DLAutoGear') then
				api.apply(true)
			end
			api.sellJunk(true)
		end
	end

	return api
end)()

-- "Gameplay Paused" is Roblox's own overlay, not this game's: CoreGui holds an empty
-- RobloxNetworkPauseNotification ScreenGui and fills it in the moment replication
-- stalls, which the teleport-heavy farm and chest routes provoke easily. What is
-- suppressed here is only that notification. The engine-side pause is not
-- switchable from Lua, so this stops the overlay covering the screen and nothing
-- more — the stall itself still resolves on its own.
-- Stored on rt (not a new local) — main chunk is at Luau's 200-register limit.
rt.Pause = (function()
	local CoreGui = game:GetService('CoreGui')
	local NAME = 'RobloxNetworkPauseNotification'
	local api = {}
	local conns, warned = {}, false

	local function overlay()
		local ok, sg = pcall(function()
			return CoreGui:FindFirstChild(NAME)
		end)
		return (ok and sg) or nil
	end

	local function drop()
		for _, c in ipairs(conns) do
			pcall(function()
				c:Disconnect()
			end)
		end
		conns = {}
	end

	-- The CoreScript re-enables the ScreenGui and rebuilds its children on every
	-- pause, so a single Enabled = false does not hold; both are re-asserted.
	local function silence(sg)
		local ok = pcall(function()
			sg.Enabled = false
			for _, d in ipairs(sg:GetDescendants()) do
				if d:IsA('GuiObject') then
					d.Visible = false
				end
			end
		end)
		if not ok and not warned then
			warned = true
			Library:Notify('Cannot write to the pause overlay')
		end
		return ok
	end

	function api.start()
		if Library and type(Library.SetHideGameplayPaused) == 'function' then
			Library:SetHideGameplayPaused(true)
			return true
		end
		-- Overlay is often created later, on the first stall. Watch CoreGui
		-- instead of failing (that used to flip the toggle back off).
		drop()
		local sg = overlay()
		if sg and not silence(sg) then
			return false
		end
		if sg then
			conns[#conns + 1] = sg:GetPropertyChangedSignal('Enabled'):Connect(function()
				if sg.Enabled and on('DLNoPause') then
					silence(sg)
				end
			end)
			conns[#conns + 1] = sg.DescendantAdded:Connect(function(d)
				if on('DLNoPause') and d:IsA('GuiObject') then
					pcall(function()
						d.Visible = false
					end)
				end
			end)
		end
		conns[#conns + 1] = CoreGui.ChildAdded:Connect(function(ch)
			if on('DLNoPause') and ch.Name == NAME then
				silence(ch)
			end
		end)
		pcall(function()
			game:GetService('GuiService'):SetGameplayPausedNotificationEnabled(false)
		end)
		return true
	end

	-- Handing the overlay back matters: left disabled, a genuine disconnect would
	-- give no warning at all.
	function api.stop()
		if Library and type(Library.SetHideGameplayPaused) == 'function' then
			Library:SetHideGameplayPaused(false)
			return
		end
		drop()
		local sg = overlay()
		if sg then
			pcall(function()
				sg.Enabled = true
			end)
		end
		pcall(function()
			game:GetService('GuiService'):SetGameplayPausedNotificationEnabled(true)
		end)
	end

	return api
end)()

-- ── Tabs ──
-- Menu construction gets its own function: Luau caps a function at 200 active
-- locals, and the main chunk had grown right up to that limit. A function body has
-- its own register budget, and nothing in here is referenced afterwards.
local function buildMenu()

local RunTab = Window:AddTab('Run', 'swords')
local WorldTab = Window:AddTab('World', 'sun')
local MoveTab = Window:AddTab('Move', 'person-standing')
local PlayersTab = Window:AddTab('Players', 'users')
local DataTab = Window:AddTab('Data', 'scroll')
local MenuTab = Window:AddTab('Menu', 'settings')

local RunBox = RunTab:AddLeftGroupbox('ESP')
local HudBox = RunTab:AddRightGroupbox('HUD')
RunBox:AddToggle('DLEspChests', { Text = 'Chests', Default = true })
RunBox:AddToggle('DLEspPotions', { Text = 'Potion stations', Default = true })
RunBox:AddToggle('DLEspKeys', { Text = 'Locked rooms / keys', Default = true })
RunBox:AddToggle('DLEspLoot', { Text = 'Ground loot', Default = true })
RunBox:AddToggle('DLEspExtract', { Text = 'Extract / portals', Default = true })
RunBox:AddToggle('DLEspEnemies', {
	Text = 'Enemy tracers',
	Default = false,
	Tooltip = 'Infinite Yield–style screen tracers to enemies. Gold = miniboss, pink = boss, orange = elite.',
}):OnChanged(function(v)
	if not v then
		pcall(clearEnemyTracers)
	end
	Library:Notify(v and 'Enemy tracers on' or 'Enemy tracers off')
end)

local ChestBox = RunTab:AddLeftGroupbox('Chests')
ChestBox:AddToggle('DLChestAnywhere', {
	Text = 'Auto collect chests',
	Default = false,
	Tooltip = 'Farm: Nightmare waits until the floor boss is next, then sweeps. Endless loots each room as soon as that pack is dead. Manual Collect still works anytime. Locked-room chests are skipped unless Open locked gates is on.',
}):OnChanged(function(v)
	Library:Notify(v and 'Auto chest route on' or 'Auto chest route off')
end)
ChestBox:AddToggle('DLOpenGates', {
	Text = 'Open locked gates',
	Default = true,
	Tooltip = 'Farm fires Use Key on Gold/Silver gates after a room clears. Off: do not unlock, and auto collect skips those locked-room chests.',
}):OnChanged(function(v)
	Library:Notify(v and 'Open locked gates on' or 'Open locked gates off')
end)
ChestBox:AddButton('Collect all chests', function()
	collectChestRoute(false)
end)
ChestBox:AddSlider('DLChestEvery', {
	Text = 'Route every (s)',
	Default = 45,
	Min = 5,
	Max = 120,
	Rounding = 0,
	Suffix = 's',
	Tooltip = 'Only used when auto farm is off. Farm waits until the last mob is the boss, then sweeps chests in one pass.',
})
ChestBox:AddLabel('Open gates is Use Key. Off leaves locked rooms alone.')
HudBox:AddToggle('DLShowHud', {
	Text = 'Overlay HUD',
	Default = true,
	Tooltip = 'Saved with the rest of the profile. Off stays off across reloads.',
}):OnChanged(function()
	pcall(refreshHud)
end)
HudBox:AddToggle('DLDpsMeter', {
	Text = 'DPS meter',
	Default = true,
	Tooltip = 'Rolling 5s outgoing DPS plus fight average from Damage_Dealt. Average ignores idle gaps between packs.',
}):OnChanged(function()
	pcall(refreshHud)
end)
HudBox:AddLabel('Home = menu   ·   HUD stays up while the window is hidden')

local CombatBox = RunTab:AddRightGroupbox('Combat')
CombatBox:AddToggle('DLAutoParry', {
	Text = 'Auto parry',
	Default = false,
	Tooltip = 'Times F on real wind-ups (Telegraph_Root rising edge, CanAttack, attack anims). Ignores floor AOE discs that used to false-parry. Successful parries feed ultimate charge.',
}):OnChanged(function(v)
	if v then
		Library:Notify('Auto parry on')
	else
		if not on('DLAutoDodge') then
			clearEnemyWatches()
			rt.parryArmed = 0
			rt.parryDelay = 0
		end
		Library:Notify('Auto parry off')
	end
end)
CombatBox:AddToggle('DLAutoDodge', {
	Text = 'Auto dodge (Q)',
	Default = true,
	Tooltip = 'Q-dash on swing telegraphs when parry is down. Dark Professor floor circles are not dashed — the character is moved into a gap between the red discs.',
}):OnChanged(function(v)
	if v then
		Library:Notify('Auto dodge on')
	else
		if not on('DLAutoParry') then
			clearEnemyWatches()
			rt.parryArmed = 0
			rt.parryDelay = 0
		end
		Library:Notify('Auto dodge off')
	end
end)
CombatBox:AddSlider('DLParryBossDelay', {
	Text = 'Boss parry lead',
	Default = 0.85,
	Min = 0,
	Max = 2,
	Rounding = 2,
	Suffix = 's',
	Tooltip = 'Fallback wait after a boss telegraph if the attack clip has no length. Raise it if you parry too early, lower it if you get hit. Anim-timed bosses ignore this and fire just before impact.',
})
CombatBox:AddSlider('DLParryRange', {
	Text = 'Combat range',
	Min = 10,
	Max = 80,
	Default = 40,
	Rounding = 0,
})
CombatBox:AddToggle('DLAutoSkill', {
	Text = 'Auto skill',
	Default = false,
	Tooltip = 'Fires skills 1–4 on a live target. Ultimate (G) pops as soon as it is charged — does not wait for a mob or boss. Dark Professor still holds G until the 4 crystals spawn, then dumps from the pack center.',
}):OnChanged(function(v)
	Library:Notify(v and 'Auto skill on' or 'Auto skill off')
end)
CombatBox:AddToggle('DLSkill1', { Text = 'Skill 1', Default = true })
CombatBox:AddToggle('DLSkill2', { Text = 'Skill 2', Default = true })
CombatBox:AddToggle('DLSkill3', { Text = 'Skill 3', Default = true })
CombatBox:AddToggle('DLSkill4', { Text = 'Skill 4', Default = true })
CombatBox:AddToggle('DLAutoPotion', {
	Text = 'Auto potion',
	Default = false,
	Tooltip = 'Drinks your equipped potion once HP (humanoid or HUD bar) drops under the threshold, including mid-fight, respecting the real cooldown.',
}):OnChanged(function(v)
	rt.potionNextTry = 0
	Library:Notify(v and 'Auto potion on' or 'Auto potion off')
end)
CombatBox:AddToggle('DLAutoPotionRefill', {
	Text = 'Auto refill at 0',
	Default = true,
	Tooltip = 'When the equipped heal potion hits x0, warp to an unused dungeon cauldron and refill. Each pot is limited — spent ones are skipped. If none are left, farm continues instead of looping the same empty station.',
}):OnChanged(function(v)
	Library:Notify(v and 'Auto potion refill on' or 'Auto potion refill off')
	if v and rt.PotionRefill and rt.PotionRefill.count() == 0 then
		task.spawn(rt.PotionRefill.run, true)
	end
end)
CombatBox:AddButton('Refill potions now', function()
	task.spawn(function()
		if rt.PotionRefill then
			rt.PotionRefill.run(false)
		end
	end)
end)
CombatBox:AddSlider('DLPotionHp', {
	Text = 'Drink / flee under',
	Default = 40,
	Min = 5,
	Max = 90,
	Rounding = 0,
	Suffix = '%',
	Tooltip = 'Starts a heal: drink potions and flee. Farm does not resume at this number.',
})
CombatBox:AddSlider('DLHealResume', {
	Text = 'Resume farm over',
	Default = 70,
	Min = 20,
	Max = 95,
	Rounding = 0,
	Suffix = '%',
	Tooltip = 'After a low-HP latch, farm stays out until HP is over this. Default 70%. Never lower than the drink/flee slider.',
})
CombatBox:AddToggle('DLAutoFlee', {
	Text = 'Flee when low HP',
	Default = false,
	Tooltip = 'Warps off the pack when HP drops under Drink / flee, then waits there until Resume farm over (default 70%).',
}):OnChanged(function(v)
	Library:Notify(v and 'Auto flee on' or 'Auto flee off')
end)
CombatBox:AddLabel('Parry = F   ·   Dodge = Q   ·   Skills = 1–4   ·   Ult G = bosses   ·   Potion = 5')

local RollBox = RunTab:AddLeftGroupbox('Roll')
local classDrop = RollBox:AddDropdown('DLRollClasses', {
	Text = 'Stop on classes',
	Values = RunLoops.listClassNames(),
	Multi = true,
	AllowNull = true,
})
RollBox:AddDropdown('DLSpinMode', {
	Text = 'Spin type',
	Values = { 'Lucky first', 'Normal only', 'Lucky only' },
	Default = 1,
	Tooltip = 'Lucky first burns lucky spins then normal. Matches SummoningService.Spin("Lucky"|"Normal").',
})
RollBox:AddButton('Refresh classes', function()
	local names = RunLoops.listClassNames()
	if classDrop and classDrop.SetValues then
		classDrop:SetValues(names)
	end
	Library:Notify((#names) .. ' classes')
end)
RollBox:AddToggle('DLStopExotic', {
	Text = 'Stop on Exotic',
	Default = true,
	Tooltip = 'Always stop auto-roll when Class_Data rarity is Exotic (Dragoon, Embertide, etc.), even if that class is not in the dropdown.',
})
RollBox:AddToggle('DLAutoRoll', {
	Text = 'Auto roll',
	Default = false,
	Tooltip = 'Lobby: SummoningService.Spin as fast as possible, skips the summon animation. Stops on picked classes and Exotic if that toggle is on.',
}):OnChanged(function(v)
	if not v then
		rollBusy = false
		return
	end
	if LocalPlayer:GetAttribute('InDungeon') == true then
		Library:Notify('Roll from lobby')
		Toggles.DLAutoRoll:SetValue(false)
		return
	end
	if not next(RunLoops.wantedRollClasses()) and not on('DLStopExotic') then
		Library:Notify('Pick stop-on classes first, or enable Stop on Exotic')
		Toggles.DLAutoRoll:SetValue(false)
		return
	end
	local curClass = RunLoops.currentClassName()
	if RunLoops.classIsWanted(curClass) then
		Library:Notify('Already on ' .. tostring(curClass))
		Toggles.DLAutoRoll:SetValue(false)
		return
	end
	local rem = RunLoops.findRollRemote()
	if not rem then
		Library:Notify('SummoningService.Spin not found')
		Toggles.DLAutoRoll:SetValue(false)
		return
	end
	Library:Notify('Auto roll on · ' .. tostring(rollRFLabel or rem.Name) .. ' (skip anim)')
end)
RollBox:AddLabel('Lobby · Normal + Lucky · stops on Exotic by default')

local FarmBox = RunTab:AddLeftGroupbox('Auto farm')
FarmBox:AddToggle('DLAutoFarm', {
	Text = 'Auto farm enemies',
	Default = false,
	Tooltip = 'Walks the nearest enemy down with Inputs.Attack, then moves to the next. Turn on Auto parry / Auto dodge / Auto skill alongside it.',
}):OnChanged(function(v)
	if v then
		Library:Notify('Auto farm on')
		-- Start immediately — do not wait on the Heartbeat watchdog (throttle /
		-- stacked connections used to leave the toggle on with no farm thread).
		pcall(RunLoops.startFarm)
	else
		rt.farmStarted = false
		Library:Notify(('Auto farm off — %d kills'):format(farmKills))
	end
end)
FarmBox:AddToggle('DLSweepMarks', {
	Text = 'Room sweep markers',
	Default = true,
	Tooltip = 'Highlights each combat/loot/boss room with its number. Marker vanishes after that room is clear, and after chests/gates if those toggles are on. Farm will not go back to an unmarked room.',
}):OnChanged(function(v)
	if not v then
		pcall(clearAllSweepMarks)
	end
	Library:Notify(v and 'Room sweep markers on' or 'Room sweep markers off')
end)
FarmBox:AddToggle('DLFarmBoss', {
	Text = 'Prefer bosses',
	Default = false,
	Tooltip = 'Target elites before fodder. Minibosses / bosses still win. Specials are skipped while anything else is alive.',
})
FarmBox:AddToggle('DLFarmRanged', {
	Text = 'Prefer ranged',
	Default = true,
	Tooltip = 'Kill archers / mages / other ranged mobs before melee. Minibosses / bosses still win. Specials are not preferred.',
})
FarmBox:AddToggle('DLAutoSpecial', {
	Text = 'Auto summon special',
	Default = false,
	Tooltip = 'Warps to Skull_Totem, holds the summon prompt, then clicks the green Summon confirm (HUD.Warning) so the 7 Platinum keys actually spend. Skips if you are short on keys or the totem is already used.',
}):OnChanged(function(v)
	rt.specialNext = 0
	Library:Notify(v and 'Auto special summon on' or 'Auto special summon off')
	if v then
		task.spawn(function()
			pcall(RunLoops.trySummonSpecial)
		end)
	end
end)
FarmBox:AddToggle('DLFarmReturn', {
	Text = 'Return on stop',
	Default = true,
	Tooltip = 'Puts you back where you switched the farm on.',
})
FarmBox:AddSlider('DLFarmStand', {
	Text = 'Standoff',
	Default = 5,
	Min = 0,
	Max = 15,
	Rounding = 0,
	Tooltip = 'Horizontal gap from the enemy. 0 stands on top of them.',
})
FarmBox:AddSlider('DLFarmSpecialOff', {
	Text = 'Special boss height',
	Default = -11.5,
	Min = -25,
	Max = 5,
	Rounding = 1,
	Suffix = ' vs root',
	Tooltip = 'Used only when Auto max low and Auto max height are both off. Ice-dodge bury vs the special\'s HumanoidRootPart (Awakened Devil was -11.5). With auto height on, specials stand in the weapon hitbox like other bosses.',
})
FarmBox:AddToggle('DLFarmAutoLow', {
	Text = 'Auto max low height',
	Default = false,
	Tooltip = 'Floor bosses / tall packs / specials: sit 7 under the hurtbox. Normal mobs: stand on the floor. Overrides Special boss height.',
})
FarmBox:AddToggle('DLFarmAutoHigh', {
	Text = 'Auto max height',
	Default = true,
	Tooltip = 'Stand as high as your weapon HitboxSize still connects — the top of the M1 volume. Hover is a fine-tune on top. Uses the same HitboxSize as Show Hitbox in the game.',
})
FarmBox:AddSlider('DLFarmHover', {
	Text = 'Hover',
	Default = 0,
	Min = -20,
	Max = 20,
	Rounding = 0,
	Tooltip = 'Added on top of auto height. With both autos off: height vs the floor next to the pack. Negative drops you into a pit / under an ice slab.',
})
FarmBox:AddSlider('DLFarmDelay', {
	Text = 'Swing delay',
	Default = 0,
	Min = 0,
	Max = 1,
	Rounding = 2,
	Suffix = 's',
	Tooltip = '0 = follow your real Stat_AttackSpeed.',
})
FarmBox:AddLabel('Fires Inputs.Attack — same remote as your mouse.')

local PickBox = RunTab:AddRightGroupbox('Chest pick')
PickBox:AddToggle('DLAutoChestPick', {
	Text = 'Auto select reward chests',
	Default = false,
	Tooltip = 'When "SELECT n CHESTS" appears, clicks the real chest buttons and Finish. Reads n from the header, so the gamepass third pick is used when you have it.',
}):OnChanged(function(v)
	Library:Notify(v and 'Auto chest pick on' or 'Auto chest pick off')
	if v then
		task.spawn(ChestPick.run, true)
	end
end)
PickBox:AddButton('Pick chests now', function()
	task.spawn(ChestPick.run, false)
end)
PickBox:AddLabel('Takes them left to right; rarity is hidden until opened.')

local BlessBox = RunTab:AddRightGroupbox('Blessings')
BlessBox:AddToggle('DLAutoBless', {
	Text = 'Auto pick best damage blessing',
	Default = false,
	Tooltip = 'Teleports to Blessing_Altar prompts in the dungeon (not just nearby), opens the panel, and picks the highest damage buff. Uses farm target range (0 = whole dungeon).',
}):OnChanged(function(v)
	Library:Notify(v and 'Auto blessing on' or 'Auto blessing off')
	if v then
		task.spawn(BlessPick.run, true)
	end
end)
BlessBox:AddButton('Pick blessing now', function()
	task.spawn(BlessPick.run, false)
end)
BlessBox:AddLabel('Uses BuffData ranks: DamagePct first, then skill/crit.')

local ReplayBox = RunTab:AddRightGroupbox('Replay')
ReplayBox:AddToggle('DLAutoReplay', {
	Text = 'Auto replay dungeon',
	Default = false,
	Tooltip = 'On completion: CHANGE DUNGEON to the next DisplayOrder dungeon up (Nightmare max) when unlocked; otherwise RequestReplay. Loop specific dungeon overrides this and may pick Endless.',
}):OnChanged(function(v)
	runCompleteAt = nil
	replayArmedAt = nil
	replayTries = 0
	Library:Notify(v and 'Auto replay on' or 'Auto replay off')
end)
ReplayBox:AddToggle('DLLoopSpecific', {
	Text = 'Loop specific dungeon',
	Default = false,
	Tooltip = 'Always replay and lobby-join the dungeon/difficulty picked below. Does not need Auto replay or Auto start — fail, death, and win all restart that map.',
}):OnChanged(function(v)
	Library:Notify(v and 'Loop specific dungeon on' or 'Loop specific dungeon off')
	if v then
		DungeonStart.onLobby()
	end
end)
local loopDungeonDrop = ReplayBox:AddDropdown('DLLoopDungeon', {
	Text = 'Dungeon',
	Values = DungeonStart.listDungeons(),
	AllowNull = true,
})
ReplayBox:AddDropdown('DLLoopDifficulty', {
	Text = 'Difficulty',
	Values = DungeonStart.listDifficulties(),
	Default = 4,
	Tooltip = 'Easy / Normal / Hard / Nightmare / Endless. Auto start still caps at Nightmare.',
})
ReplayBox:AddButton('Refresh dungeon list', function()
	local names = DungeonStart.listDungeons()
	if loopDungeonDrop and loopDungeonDrop.SetValues then
		loopDungeonDrop:SetValues(names)
	end
	Library:Notify((#names) .. ' dungeons')
end)
ReplayBox:AddButton('Go to this dungeon now', function()
	task.spawn(function()
		if LocalPlayer:GetAttribute('InDungeon') == true then
			if DungeonStart.loopNow(false) then
				return
			end
			Replay.request(false)
			return
		end
		DungeonStart.run(false)
	end)
end)
ReplayBox:AddSlider('DLReplayDelay', {
	Text = 'Replay after',
	Default = 2.5,
	Min = 0,
	Max = 15,
	Rounding = 1,
	Suffix = 's',
	Tooltip = 'Grace period once the run ends, so reward and chest popups can resolve first.',
})
ReplayBox:AddButton('Replay now', function()
	if Replay.request(false) then
		Library:Notify('Replay requested')
	end
end)
ReplayBox:AddLabel('Loop specific restarts that map on win, fail, or lobby. Auto replay is only for upgrading to the next dungeon.')

ReplayBox:AddToggle('DLHuntSpecial', {
	Text = 'Hunt special loop',
	Default = false,
	Tooltip = 'Underworld Gate Nightmare (or your Loop dungeon/diff): summon + kill the named special (Scarlet Knight), RequestReturn to lobby, start again. Needs platinum keys for the totem.',
}):OnChanged(function(v)
	if not v then
		Library:Notify('Hunt special off')
		return
	end
	pcall(function()
		if Options.DLLoopDungeon and Options.DLLoopDungeon.SetValue then
			Options.DLLoopDungeon:SetValue('Underworld Gate')
		end
		if Options.DLLoopDifficulty and Options.DLLoopDifficulty.SetValue then
			Options.DLLoopDifficulty:SetValue('Nightmare')
		end
		if Options.DLHuntTarget and Options.DLHuntTarget.SetValue then
			local cur = tostring(Options.DLHuntTarget.Value or '')
			if cur == '' or cur == 'nil' then
				Options.DLHuntTarget:SetValue('Scarlet Knight')
			end
		end
		if Toggles.DLLoopSpecific then
			Toggles.DLLoopSpecific:SetValue(true)
		end
		if Toggles.DLAutoFarm then
			Toggles.DLAutoFarm:SetValue(true)
		end
		if Toggles.DLAutoSpecial then
			Toggles.DLAutoSpecial:SetValue(true)
		end
	end)
	DungeonStart.onLobby()
	Library:Notify('Hunt · Underworld Gate Nightmare · Scarlet Knight')
end)
ReplayBox:AddInput('DLHuntTarget', {
	Text = 'Hunt target name',
	Default = 'Scarlet Knight',
	Numeric = false,
	Finished = true,
	Tooltip = 'Matches enemy Name / ItemId (substring). Scarlet Knight is the Underworld Gate special.',
})
ReplayBox:AddLabel('Hunt sets Loop dungeon to Underworld Gate + Nightmare, farms/summons the special, then returns to lobby on kill.')

local LobbyBox = RunTab:AddLeftGroupbox('Lobby')
LobbyBox:AddToggle('DLAutoDungeon', {
	Text = 'Auto start best dungeon',
	Default = false,
	Tooltip = 'In the lobby, picks the best unlocked dungeon/difficulty for your level (difficulty rank first), then RequestStartSoloRun.',
}):OnChanged(function(v)
	if v then
		DungeonStart.onLobby()
	end
	Library:Notify(v and 'Auto dungeon start on' or 'Auto dungeon start off')
end)
LobbyBox:AddSlider('DLDungeonDelay', {
	Text = 'Start after',
	Default = 2,
	Min = 0,
	Max = 15,
	Rounding = 1,
	Suffix = 's',
	Tooltip = 'Wait after landing in the lobby before opening the dungeon menu.',
})
LobbyBox:AddButton('Start best dungeon now', function()
	task.spawn(DungeonStart.run, false)
end)
LobbyBox:AddLabel('Loop specific dungeon overrides this pick and can use Endless. Auto start stays Nightmare max.')

local WorldBox = WorldTab:AddLeftGroupbox('Look')
WorldBox:AddToggle('DLFullbright', { Text = 'Fullbright' }):OnChanged(function(v)
	pcall(applyFullbright, v == true)
end)
WorldBox:AddToggle('DLInvisicam', {
	Text = 'Invisicam (see through walls)',
	Default = true,
	Tooltip = 'Library Invisicam: DevCameraOcclusionMode so walls fade instead of the camera zooming into your back. Built into Ataraxia for every game.',
}):OnChanged(function(v)
	pcall(rt.applyOcclusion, v == true)
	Library:Notify(v and 'Invisicam on' or 'Invisicam off')
end)
WorldBox:AddToggle('DLMuteVfx', { Text = 'Mute dungeon VFX' })
WorldBox:AddLabel('Mutes Particles / telegraphs / projectiles. Does not fire remotes.')

local SessionBox = WorldTab:AddRightGroupbox('Session')
SessionBox:AddToggle('DLNoPause', {
	Text = 'Hide "Gameplay Paused"',
	Default = true,
	Tooltip = 'Ataraxia hides RobloxNetworkPauseNotification. The network stall still resolves on its own — this only stops the banner.',
}):OnChanged(function(v)
	if v then
		rt.Pause.start()
		Library:Notify('Pause overlay hidden')
	else
		rt.Pause.stop()
		Library:Notify('Pause overlay restored')
	end
end)
SessionBox:AddLabel('Roblox overlay, not the game\'s. The 17-minute AFK warp is in the game\'s own Settings.')

local MoveBox = MoveTab:AddLeftGroupbox('Walkspeed')
MoveBox:AddToggle('DLWalkOn', { Text = 'Override walkspeed', Default = true }):OnChanged(function(v)
	if v then
		pcall(applyWalk)
		Library:Notify('Walkspeed override on')
	else
		Library:Notify('Walkspeed override off')
	end
end)
MoveBox:AddSlider('DLWalkSpeed', {
	Text = 'Walkspeed',
	Min = 8,
	Max = 120,
	Default = defaultWalk,
	Rounding = 0,
}):OnChanged(function()
	if Toggles.DLWalkOn and Toggles.DLWalkOn.Value ~= true then
		Toggles.DLWalkOn:SetValue(true)
	end
	pcall(applyWalk)
end)
MoveBox:AddButton('Default walkspeed', function()
	if Options.DLWalkSpeed then
		Options.DLWalkSpeed:SetValue(defaultWalk)
	end
	pcall(applyWalk)
	Library:Notify('Walkspeed ' .. tostring(defaultWalk))
end)
MoveBox:AddLabel('Game resets speed every frame — override pins it.')

local ClipBox = MoveTab:AddRightGroupbox('Noclip')
ClipBox:AddToggle('DLAutoNoclip', {
	Text = 'Auto noclip at key doors',
	Default = false,
	Tooltip = 'When you get near a Locked_ key door, collision drops so you can walk through. Turns off when you leave range.',
}):OnChanged(function(v)
	if not v then
		noclipOn = false
		pcall(setCharNoclip, false)
		Library:Notify('Key-door noclip off')
		return
	end
	Library:Notify('Key-door noclip on')
end)
ClipBox:AddSlider('DLNoclipRange', {
	Text = 'Door range',
	Min = 8,
	Max = 50,
	Default = 22,
	Rounding = 0,
})
ClipBox:AddButton('Fix movement', function()
	if fixMovement() then
		Library:Notify('Movement reset — collision and velocity cleared')
	else
		Library:Notify('No character to fix')
	end
end)
ClipBox:AddLabel('Walk through Locked_ doors. Stay near the door.')

local PlrBox = PlayersTab:AddLeftGroupbox('Players')
local playerDrop = PlrBox:AddDropdown('DLPlayerList', {
	Text = 'Players',
	Values = {},
	AllowNull = true,
})
local function refreshPlayers()
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		list[#list + 1] = plr.Name
	end
	table.sort(list)
	if playerDrop and playerDrop.SetValues then
		playerDrop:SetValues(list)
	end
end
refreshPlayers()
PlrBox:AddButton('Refresh players', refreshPlayers)
PlrBox:AddToggle('DLSpectate', { Text = 'Spectate' }):OnChanged(function(v)
	if not v then
		stopSpectate()
		return
	end
	spectateName = Options.DLPlayerList and Options.DLPlayerList.Value
	if type(spectateName) ~= 'string' or spectateName == '' then
		Library:Notify('Pick a player first')
		if Toggles.DLSpectate then
			Toggles.DLSpectate:SetValue(false)
		end
		return
	end
	Library:Notify('Spectating ' .. spectateName)
end)
PlrBox:AddButton('Fix camera', function()
	if Toggles.DLSpectate then
		Toggles.DLSpectate:SetValue(false)
	end
	stopSpectate()
	Library:Notify('Camera reset')
end)

local DataBox = DataTab:AddLeftGroupbox('Copy')
DataBox:AddButton('Copy current stats', function()
	local text = select(1, statsText())
	text = text .. ('\nChests %s/%s\nGround %s\nMobs %s'):format(
		fmtNum(lastLootable),
		fmtNum(lastTotal),
		fmtNum(lastGround),
		fmtNum(lastEnemies)
	)
	if copyText(text) then
		Library:Notify('Copied stats')
	else
		Library:Notify('Clipboard unavailable')
	end
end)
DataBox:AddButton('Copy class list', function()
	local folder = game:GetService('ReplicatedStorage'):FindFirstChild('Classes')
	if not folder then
		Library:Notify('Classes folder missing')
		return
	end
	local names = {}
	for _, c in ipairs(folder:GetChildren()) do
		if c:IsA('Folder') then
			names[#names + 1] = c.Name
		end
	end
	table.sort(names)
	if copyText(table.concat(names, '\n')) then
		Library:Notify(('Copied %s classes'):format(#names))
	else
		Library:Notify('Clipboard unavailable')
	end
end)
DataBox:AddButton('Copy dungeon names', function()
	local ss = game:GetService('ReplicatedStorage'):FindFirstChild('ServerState')
	local sess = ss and ss:FindFirstChild('DungeonSessions')
	if not sess then
		Library:Notify('No dungeon sessions')
		return
	end
	local names = {}
	for _, c in ipairs(sess:GetChildren()) do
		if c:IsA('StringValue') then
			names[#names + 1] = c.Name
		end
	end
	table.sort(names)
	if copyText(table.concat(names, '\n')) then
		Library:Notify(('Copied %s dungeons'):format(#names))
	else
		Library:Notify('Clipboard unavailable')
	end
end)
DataBox:AddLabel('Class / dungeon dumps only.')

local CodesBox = DataTab:AddRightGroupbox('Codes')
CodesBox:AddLabel('Live CodesData + Sept 2026 guide extras. Skip creator-only.')
CodesBox:AddButton('Use all codes', function()
	RunLoops.redeemAllCodes()
end)
CodesBox:AddButton('Copy active codes', function()
	local names = RunLoops.listRedeemCodes()
	if #names == 0 then
		Library:Notify('No codes found')
		return
	end
	if copyText(table.concat(names, '\n')) then
		Library:Notify(('Copied %s codes'):format(#names))
	else
		Library:Notify('Clipboard unavailable')
	end
end)
CodesBox:AddLabel('Need ClickBytes group (same as in-game Codes).')

local QuestBox = DataTab:AddRightGroupbox('Quests')
QuestBox:AddButton('Claim all quests', function()
	claimAllQuests(false)
end)
QuestBox:AddToggle('DLAutoQuest', {
	Text = 'Auto claim quests',
	Default = false,
	Tooltip = 'Every 45s: each completed quest\'s own Claim button, battlepass quests/tiers, achievement ClaimAll.',
}):OnChanged(function(v)
	if v then
		claimAllQuests(true)
		Library:Notify('Auto claim quests on')
	else
		Library:Notify('Auto claim quests off')
	end
end)
QuestBox:AddLabel('Daily / weekly / limited / NPC / achievements.')

local GearBox = DataTab:AddRightGroupbox('Gear')
Gear.setLabel(GearBox:AddLabel('Reading inventory…'))
Gear.setView(GearBox:AddLabel('Your inventory (not the dungeon loot bag).'))
Gear.setDrop(GearBox:AddDropdown('DLInvBag', {
	Text = 'Current inventory',
	Values = { 'Reading…' },
	Tooltip = 'Worn gear, extra gear, potions, materials, keys. This is PlayerData inventory, not the extract loot bag.',
}))
GearBox:AddButton('Open / close inventory', function()
	Gear.toggleGameInv()
end)
GearBox:AddButton('Open / close forge', function()
	Gear.toggleGameForge()
end)
GearBox:AddToggle('DLInvPin', {
	Text = 'Keep inventory open in dungeon',
	Default = false,
	Tooltip = 'Re-opens the real Inventory window (item grid) and hides the dungeon loot overlay so you can see what you own mid-run.',
}):OnChanged(function(v)
	rt.invOpen = v
	if v then
		task.spawn(function()
			Gear.toggleGameInv(true)
		end)
	else
		local inv = LocalPlayer.PlayerGui:FindFirstChild('Main')
		inv = inv and inv:FindFirstChild('Frames')
		inv = inv and inv:FindFirstChild('Inventory')
		if inv then
			inv.Visible = false
		end
		Library:Notify('Inventory pin off')
	end
end)
GearBox:AddButton('Equip best gear now', function()
	task.spawn(Gear.apply, false)
end)
GearBox:AddToggle('DLAutoGear', {
	Text = 'Auto equip best gear',
	Default = false,
	Tooltip = 'Head/Body/Weapon: rarity then tier. Rings: highest Lifesteal only — never swaps a ring for damage or rarity if LS is not strictly better.',
}):OnChanged(function(v)
	Library:Notify(v and 'Auto equip on' or 'Auto equip off')
	if v then
		task.spawn(Gear.apply, true)
	end
end)
GearBox:AddDropdown('DLJunkMode', {
	Text = 'Junk action',
	Values = { 'Sell', 'Delete' },
	Default = 1,
	Tooltip = 'Sell uses ShopService.SellEquipment (cash). Delete uses EquipmentService.DeleteItem.',
})
GearBox:AddToggle('DLAutoJunk', {
	Text = 'Auto clear junk gear',
	Default = false,
	Tooltip = 'Sells/deletes Head, Body, or Ring pieces whose main stat is red vs what you wear (worse Base Damage / guaranteed). Sells over-level junk too. Never weapons. Keeps Locked, Judgement, and Lifesteal.',
}):OnChanged(function(v)
	Library:Notify(v and 'Auto junk clear on' or 'Auto junk clear off')
	if v then
		rt.junkAt = 0
		task.spawn(Gear.sellJunk, true)
	end
end)
GearBox:AddButton('Clear junk now', function()
	task.spawn(Gear.sellJunk, false)
end)
GearBox:AddLabel('Junk sell: Head / Body / Ring only. Red main-stat (▼) vs equipped = sell. Keeps weapons, Locked, Judgement, Lifesteal.')

local StatBox = DataTab:AddLeftGroupbox('Skill points')
Stats.setLabel(StatBox:AddLabel('Level ? · reading…'))
StatBox:AddDropdown('DLStatPick', {
	Text = 'Put points into',
	Values = Stats.NAMES,
	Multi = true,
	AllowNull = true,
	Tooltip = 'Unspent points are split evenly across every stat picked here.',
})
StatBox:AddButton('Spend all points now', function()
	-- Spawned: allocating yields on the remote, which would stall the button.
	task.spawn(Stats.spendAll, false)
end)
StatBox:AddButton('Reset stat points', function()
	task.spawn(Stats.respec, false)
end)
StatBox:AddToggle('DLAutoStat', {
	Text = 'Auto spend skill points',
	Default = false,
	Tooltip = 'Every 8s, splits unspent level-up points across the picked stats using StatService.AllocatePoints — the same call the in-game stat panel makes.',
}):OnChanged(function(v)
	if not v then
		Library:Notify('Auto skill points off')
		return
	end
	if #Stats.picked() == 0 then
		Library:Notify('Pick at least one stat first')
		Toggles.DLAutoStat:SetValue(false)
		return
	end
	Library:Notify('Auto skill points on')
	task.spawn(Stats.spendAll, true)
end)
StatBox:AddLabel('Reset is Inventory → Stat Upgrades → RESET. Auto spend will reallocate after a reset.')

local MenuBox = MenuTab:AddLeftGroupbox('Script')
MenuBox:AddLabel('Home hides/shows this window (same as PlayerTools).')
if type(Library.AddNotifyToggle) == 'function' then
	Library:AddNotifyToggle(MenuBox)
end
MenuBox:AddButton('Hide menu', function()
	Library:Toggle(false)
end)
MenuBox:AddButton('Unload', function()
	if type(getgenv().DLUnload) == 'function' then
		getgenv().DLUnload()
	end
end)
MenuBox:AddButton('Save current profile now', function()
	Library:Notify(Config.saveNow() and 'Profile saved' or 'Profile save failed')
end)
MenuBox:AddButton('Reset settings to defaults', function()
	Config.reset()
	Library:Notify('Settings reset to defaults')
end)

local ProfileBox = MenuTab:AddRightGroupbox('Profiles')
Library.Config.Build(ProfileBox)

end
buildMenu()
-- hook before load so the snapshot of defaults is taken untouched
Config.hook()
Config.load()
pcall(refreshHud)
pcall(function()
	local resume = getgenv().DLResumeFarm == true or on('DLAutoFarm')
	if resume then
		if Toggles.DLAutoFarm and Toggles.DLAutoFarm.Value ~= true then
			Toggles.DLAutoFarm:SetValue(true)
		end
		noclipOn = true
		pcall(setCharNoclip, true)
		pcall(RunLoops.startFarm)
	end
	task.defer(function()
		getgenv().DLResumeFarm = nil
	end)
end)
pcall(rt.applyOcclusion, on('DLInvisicam'))
-- Library hide stays on even if an old profile saved DLNoPause=false.
pcall(function()
	if Library and type(Library.SetHideGameplayPaused) == 'function' then
		Library:SetHideGameplayPaused(true)
		if Toggles.DLNoPause and Toggles.DLNoPause.Value ~= true then
			Toggles.DLNoPause:SetValue(true)
		end
		if Toggles.DLSweepMarks and Toggles.DLSweepMarks.Value ~= true then
			Toggles.DLSweepMarks:SetValue(true)
		end
	elseif on('DLNoPause') then
		rt.Pause.start()
	end
end)
task.defer(function()
	pcall(tickRoomSweepMarks)
end)

local hbCombatConn
hbCombatConn = track(RunService.Heartbeat:Connect(function(dt)
	-- A superseded copy must stop touching the character, not just stop deciding:
	-- stacked copies each kept firing parry, which held the 1.8s cooldown down so
	-- the live copy never had it when a real swing came.
	if not currentInstance() then
		if hbCombatConn then
			pcall(function()
				hbCombatConn:Disconnect()
			end)
		end
		return
	end
	-- Walk speed is already pinned on RenderStepped; duplicating it here cost a
	-- full character lookup every frame for no gain.
	-- Potion / flee must run every frame-ish: the combat throttle used to skip
	-- them while a pack was chewing HP.
	pcall(function()
		if rt.PotionRefill then
			rt.PotionRefill.tick()
		end
	end)
	pcall(RunLoops.autoPotionTick)
	pcall(Flee.tick)
	pcall(maintainNoclip)
	-- Parry must run every frame. The farm throttle used to skip the tick and
	-- miss telegraph rising-edges / the armed fire window.
	pcall(autoParryTick)
	-- Skills / farm watchdog must not sit behind the combat throttle.
	pcall(autoSkillTick)
	pcall(RunLoops.autoFarmTick)
	if (farmBusy or LocalPlayer:GetAttribute('InDungeon') == true)
		and os.clock() - (rt.sweepMarkAt or 0) > 0.45
	then
		rt.sweepMarkAt = os.clock()
		pcall(tickRoomSweepMarks)
	end
	local now = os.clock()
	local hot = now < (rt.parryArmed or 0) or now < (rt.parryDelay or 0)
	if not hot then
		rt.hbCombat += dt
		local gap = farmBusy and 0.14 or 0.08
		if rt.hbCombat < gap then
			return
		end
		rt.hbCombat = 0
	else
		rt.hbCombat = 0
	end
	if not farmBusy and not routeBusy then
		pcall(applyKeyNoclip)
	end
	pcall(RunLoops.autoRollTick)
end))
-- Noclip maintain used to sit on Stepped (physics rate). Heartbeat above is enough.
track(LocalPlayer.CharacterAdded:Connect(function(char)
	-- Saved CanCollide values belong to the old rig; keeping them would restore
	-- collision onto parts of a character that never lost it.
	noclipSaved = {}
	noclipOn = false
	routeBusy = false
	routeLabel = nil
	-- Keep farmBusy/farmLabel: wiping them mid-run made the HUD look like farm
	-- disengaged on every life, and Return-on-stop used to yank you home on death.
	farmFinished = {}
	collisionBaseline = nil
	task.delay(1.5, captureCollisionBaseline)
	pcall(rt.bindCharHp, char)
	if on('DLInvisicam') then
		pcall(rt.applyOcclusion, true)
	end
	if farmBusy then
		task.defer(function()
			noclipOn = true
			pcall(setCharNoclip, true)
		end)
	end
end))
pcall(function()
	RunService:UnbindFromRenderStep(WALK_BIND)
end)
pcall(function()
	RunService:BindToRenderStep(WALK_BIND, Enum.RenderPriority.Camera.Value + 1, function()
		pcall(applyWalk)
	end)
end)
pcall(function()
	RunService:UnbindFromRenderStep('DLEnemyTracers')
end)
pcall(function()
	RunService:BindToRenderStep('DLEnemyTracers', Enum.RenderPriority.Camera.Value + 2, function()
		pcall(updateEnemyTracers)
	end)
end)

rt.hbAcc = 0
local hbEspConn
hbEspConn = track(RunService.Heartbeat:Connect(function(dt)
	if not currentInstance() then
		if hbEspConn then
			pcall(function()
				hbEspConn:Disconnect()
			end)
		end
		return
	end
	rt.hbAcc += dt
	-- ESP / HUD: farm already knows its targets; avoid mark churn mid-run.
	local every = 0.55
	if LocalPlayer:GetAttribute('InDungeon') == true then
		every = farmBusy and 2.25 or 1.0
	end
	if rt.hbAcc < every then
		return
	end
	rt.hbAcc = 0
	-- Skip ESP mark rebuild while farming unless an ESP toggle is on.
	local anyEsp = on('DLEspChests')
		or on('DLEspPotions')
		or on('DLEspKeys')
		or on('DLEspLoot')
		or on('DLEspEnemies')
		or on('DLEspExtract')
	if anyEsp and (not farmBusy or on('DLEspEnemies') or on('DLEspChests')) then
		pcall(scanEspThrottled, every)
	elseif not farmBusy then
		-- Still refresh chest/door lists for routes without rebuilding marks.
		pcall(scanEspThrottled, 1.25)
	end
	pcall(refreshHud)
	pcall(muteVfx)
	pcall(applySpectate)
	if on('DLAutoQuest') and not questBusy and os.clock() - lastQuestAuto > 45 then
		pcall(claimAllQuests, true)
	end
	-- Picked before the replay check runs, so the chests are banked first.
	pcall(ChestPick.tick)
	pcall(BlessPick.tick)
	pcall(BlessPick.shrineTick)
	pcall(tickRoomSweepMarks)
	pcall(RunLoops.trySummonSpecial)
	pcall(RunLoops.confirmSpecialSummon)
	pcall(Replay.tick)
	pcall(DungeonStart.tick)
	-- Gear/stat polls are not frame-critical — half rate while farming.
	pcall(Stats.tick)
	pcall(Gear.tick)
	rt.slowUi = (rt.slowUi or 0) + 1
	pcall(Config.tick)
	-- While the farm is running, chests are swept the moment a room is cleared, so the
	-- timer would only add redundant round trips — which is most of what made the farm
	-- look like it was teleporting constantly. The timer stays for manual play.
	if on('DLChestAnywhere') and not routeBusy and not farmBusy then
		local everyChest = Options.DLChestEvery and tonumber(Options.DLChestEvery.Value) or 20
		if os.clock() - routeDoneAt > everyChest and #lootChests > 0 then
			pcall(collectChestRoute, true)
		end
	end
end))

getgenv().DLUnload = function()
	local resumeFarm = on('DLAutoFarm') == true
	getgenv().DLResumeFarm = resumeFarm or getgenv().DLResumeFarm == true
	pcall(Config.finish)
	pcall(applyFullbright, false)
	pcall(rt.applyOcclusion, false)
	stopSpectate()
	clearEnemyWatches()
	rt.parryArmed = 0
	rt.parryDelay = 0
	-- Steal the epoch before touching the farm toggle. Turning the toggle off
	-- used to run farmLoop cleanup (noclip off + Return-on-stop) and then save
	-- farm as off, so a reload dumped you on the floor with auto farm dead.
	if currentInstance() then
		getgenv().DLEpoch = nil
	end
	pcall(function()
		if not resumeFarm and Toggles.DLAutoFarm then
			Toggles.DLAutoFarm:SetValue(false)
		end
	end)
	if not resumeFarm then
		pcall(Pin.stop)
	end
	-- Leave Ataraxia's pause hide armed (same as Anti-AFK). Stopping it here
	-- is why the banner came back on every helper reload.
	routeBusy = false
	routeLabel = nil
	if not resumeFarm then
		farmBusy = false
		farmLabel = nil
		farmThread = nil
		rt.potionBusy = false
		noclipOn = false
		pcall(setCharNoclip, false)
	end
	pcall(function()
		RunService:UnbindFromRenderStep(WALK_BIND)
	end)
	pcall(function()
		RunService:UnbindFromRenderStep('DLEnemyTracers')
	end)
	pcall(clearEnemyTracers)
	if walkConn then
		pcall(function()
			walkConn:Disconnect()
		end)
		walkConn = nil
		walkHum = nil
	end
	for inst in pairs(marks) do
		clearMark(inst)
	end
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	conns = {}
	pcall(function()
		hudGui:Destroy()
	end)
	pcall(function()
		Library:Unload()
	end)
	getgenv().DLUnload = nil
	getgenv().DLLootHudUnload = nil
	getgenv().DLCollectChests = nil
	getgenv().DLFixMovement = nil
	getgenv().DLSetFarm = nil
	getgenv().DLFarmStatus = nil
	-- Release the claim so anything of ours still on a signal evicts itself on its
	-- next tick, and drop the handles we just disconnected.
	if currentInstance() then
		getgenv().DLEpoch = nil
	end
	getgenv().DLConns = {}
end
getgenv().DLLootHudUnload = getgenv().DLUnload
getgenv().DLCollectChests = function()
	collectChestRoute(false)
end
getgenv().DLFixMovement = fixMovement
getgenv().DLSetFarm = function(v)
	if Toggles.DLAutoFarm then
		Toggles.DLAutoFarm:SetValue(v == true)
	end
end
getgenv().DLFarmStatus = function()
	return farmLabel, farmKills, farmBusy
end
getgenv().DLQuestPending = function()
	local list, reachable = QuestClaim.pending()
	local bpQuests, bpTiers = QuestClaim.bpPending()
	return list, reachable, bpQuests, bpTiers
end

pcall(function()
	-- The completion panel can appear a beat after the server says the run is over,
	-- so take DungeonComplete as the authoritative end-of-run signal too.
	-- Fail / wipe uses the same panel (Title FAILED) and LivesUpdate hitting 0.
	local function markEnded()
		runCompleteAt = os.clock()
		replayTries = 0
	end
	for _, pair in ipairs({
		{ 'DungeonRunService', 'DungeonComplete' },
		{ 'DungeonService', 'DungeonComplete' },
		{ 'BossRushService', 'DungeonComplete' },
	}) do
		local ev = knitRE(pair[1], pair[2])
		if ev then
			track(ev.OnClientEvent:Connect(markEnded))
		end
	end
	for _, pair in ipairs({
		{ 'DungeonRunService', 'ReplayStarting' },
		{ 'BossRushService', 'ReplayStarting' },
	}) do
		local rs = knitRE(pair[1], pair[2])
		if rs then
			track(rs.OnClientEvent:Connect(function()
				replayArmedAt = nil
				replayTries = 0
			end))
		end
	end
	for _, svc in ipairs({ 'DungeonRunService', 'BossRushService' }) do
		local lives = knitRE(svc, 'LivesUpdate')
		if lives then
			track(lives.OnClientEvent:Connect(function(a)
				local n = tonumber(a)
				if type(a) == 'table' then
					n = tonumber(a.Lives or a.Remaining or a.lives or a.Count)
				end
				if n == 0 then
					markEnded()
				end
			end))
		end
	end
	local st = knitRE('DungeonRunService', 'StateUpdate')
	if st then
		track(st.OnClientEvent:Connect(function(a, b)
			local s = a
			if type(a) == 'table' then
				s = a.State or a.Phase or a.Status or a.Name
			end
			s = string.lower(tostring(s or b or ''))
			if s:find('fail', 1, true) or s:find('defeat', 1, true) or s:find('wipe', 1, true) then
				markEnded()
			end
		end))
	end
end)
track(LocalPlayer:GetAttributeChangedSignal('InDungeon'):Connect(function()
	if LocalPlayer:GetAttribute('InDungeon') == true then
		rt.farmChestSwept = false
		local id = tostring(LocalPlayer:GetAttribute('CurrentDungeon') or '')
		local diff = tostring(LocalPlayer:GetAttribute('CurrentDifficultyMode') or '')
		if id ~= '' then
			rt.runDungeonId = id
		end
		if diff ~= '' then
			rt.runDifficulty = diff
		end
	else
		pcall(DungeonStart.onLobby)
	end
end))
for _, attr in ipairs({ 'CurrentDungeon', 'CurrentDifficultyMode' }) do
	track(LocalPlayer:GetAttributeChangedSignal(attr):Connect(function()
		local id = tostring(LocalPlayer:GetAttribute('CurrentDungeon') or '')
		local diff = tostring(LocalPlayer:GetAttribute('CurrentDifficultyMode') or '')
		if id ~= '' then
			rt.runDungeonId = id
		end
		if diff ~= '' then
			rt.runDifficulty = diff
		end
	end))
end
do
	local id = tostring(LocalPlayer:GetAttribute('CurrentDungeon') or '')
	local diff = tostring(LocalPlayer:GetAttribute('CurrentDifficultyMode') or '')
	if id ~= '' then
		rt.runDungeonId = id
	end
	if diff ~= '' then
		rt.runDifficulty = diff
	end
end
if LocalPlayer:GetAttribute('InDungeon') ~= true then
	pcall(DungeonStart.onLobby)
end
pcall(rt.bindCharHp, character())

pcall(scanEsp)
pcall(refreshHud)
pcall(captureCollisionBaseline)
Library:Notify('Dungeon Lootr ' .. DL_BUILD .. ' — Home toggles menu')
print('[DL] helper loaded —', DL_BUILD)
