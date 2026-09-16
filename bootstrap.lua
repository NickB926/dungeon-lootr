--[[
	bootstrap.lua — one-line install / update for Dungeon Lootr

	Friend load:

	  loadstring(game:HttpGet("https://raw.githubusercontent.com/NickB926/dungeon-lootr/main/bootstrap.lua"))()

	Optional feed override:
	  getgenv().DLUpdateBase = "https://raw.githubusercontent.com/NickB926/dungeon-lootr/main"
]]

if getgenv().DLBootstrapBusy == true then
	warn('[Dungeon Lootr bootstrap] already running — skip duplicate')
	return
end
getgenv().DLBootstrapBusy = true

local BASE = (type(getgenv().DLUpdateBase) == 'string' and getgenv().DLUpdateBase ~= ''
	and getgenv().DLUpdateBase:gsub('/+$', ''))
	or 'https://raw.githubusercontent.com/NickB926/dungeon-lootr/main'

local function httpGet(url)
	local req = (syn and syn.request) or http_request or (http and http.request) or request
	if type(req) == 'function' then
		local ok, res = pcall(req, { Url = url, Method = 'GET' })
		if ok and type(res) == 'table' then
			local body = res.Body or res.body
			local code = tonumber(res.StatusCode or res.Status or res.statusCode) or 0
			if code >= 200 and code < 300 and type(body) == 'string' then
				return body
			end
		end
	end
	local ok, body = pcall(function()
		return game:HttpGet(url)
	end)
	if ok and type(body) == 'string' and body ~= '' then
		return body
	end
	return nil
end

local function say(msg)
	warn('[Dungeon Lootr bootstrap] ' .. tostring(msg))
end

local function finish(err)
	getgenv().DLBootstrapBusy = nil
	if err then
		error(err)
	end
end

if type(makefolder) == 'function' then
	pcall(makefolder, 'dungeon-lootr')
end
if type(writefile) ~= 'function' then
	finish('[Dungeon Lootr bootstrap] writefile required')
end

local updaterSrc = httpGet(BASE .. '/dungeon-lootr/Updater.lua')
if not updaterSrc then
	finish('[Dungeon Lootr bootstrap] could not download Updater.lua from ' .. BASE)
end
pcall(writefile, 'dungeon-lootr/Updater.lua', updaterSrc)
pcall(writefile, 'dungeon-lootr/update_url.txt', BASE)

local fn, err = (loadstring or load)(updaterSrc, 'dungeon-lootr/Updater.lua')
if not fn then
	finish('[Dungeon Lootr bootstrap] Updater compile failed: ' .. tostring(err))
end
local Updater = fn()
getgenv().DLUpdateBase = BASE

local hasLaunch = type(isfile) == 'function' and isfile('dungeon-lootr/launch.lua')
local hasMain = type(isfile) == 'function' and isfile('dungeon-lootr/DungeonLootr.lua')
local hasAta = type(isfile) == 'function' and isfile('dungeon-lootr/AtaraxiaLibrary.lua')
local info = Updater.check and Updater.check() or { ok = false }

if info.ok and not info.needsUpdate and hasLaunch and hasMain and hasAta then
	say(('Already on %s — skip download'):format(tostring(info.remoteVersion)))
else
	local ok, detail = Updater.apply({
		force = not (hasLaunch and hasMain and hasAta),
		notify = say,
		quietWarn = true,
	})
	if not ok then
		say('Update finished with issues: ' .. tostring(detail))
	else
		say('Files ready.')
	end
end

-- Always refresh Ataraxia if somehow missing after a partial apply.
if type(isfile) == 'function' and not isfile('dungeon-lootr/AtaraxiaLibrary.lua') then
	local ata = httpGet(BASE .. '/dungeon-lootr/AtaraxiaLibrary.lua')
	if type(ata) == 'string' and ata ~= '' then
		pcall(writefile, 'dungeon-lootr/AtaraxiaLibrary.lua', ata)
	end
end

local launchPath = 'dungeon-lootr/launch.lua'
if type(isfile) ~= 'function' or not isfile(launchPath) then
	finish('[Dungeon Lootr bootstrap] launch.lua missing after update')
end
local launchSrc = readfile(launchPath)
local launchFn, launchErr = (loadstring or load)(launchSrc, launchPath)
if not launchFn then
	finish('[Dungeon Lootr bootstrap] launch compile failed: ' .. tostring(launchErr))
end
say('Starting Dungeon Lootr…')
getgenv().DLBootstrapBusy = nil
launchFn()
