--[[
	bootstrap.lua — one-line install / update for Dungeon Lootr

	Friend load (cache-bust so GitHub raw cannot serve yesterday's bootstrap):

	  loadstring(game:HttpGet("https://raw.githubusercontent.com/NickB926/dungeon-lootr/main/bootstrap.lua?"..tostring(tick())))()

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

local info = Updater.check and Updater.check() or { ok = false }

local function luaBuild()
	if type(isfile) ~= 'function' or type(readfile) ~= 'function' then
		return nil
	end
	if not isfile('dungeon-lootr/DungeonLootr.lua') then
		return nil
	end
	local ok, body = pcall(readfile, 'dungeon-lootr/DungeonLootr.lua')
	if not ok or type(body) ~= 'string' then
		return nil
	end
	return body:match("local DL_BUILD = '([%d%.]+)'")
end

-- Always re-download. Matching version.json with a stale DungeonLootr.lua
-- (GitHub raw cache) is why friends stayed on the old farm.
local ok, detail = Updater.apply({
	force = true,
	notify = say,
	quietWarn = true,
})
if not ok then
	say('Update finished with issues: ' .. tostring(detail))
end

if not luaBuild() then
	say('GitHub copy looked stale — retrying jsDelivr')
	getgenv().DLUpdateBase = 'https://cdn.jsdelivr.net/gh/NickB926/dungeon-lootr@main'
	local ok2, detail2 = Updater.apply({
		force = true,
		notify = say,
		quietWarn = true,
	})
	if not ok2 then
		say('jsDelivr retry had issues: ' .. tostring(detail2))
	end
	getgenv().DLUpdateBase = BASE
end

local got = luaBuild()
if got then
	say('Helper build ' .. tostring(got))
elseif info and info.remoteVersion then
	say('Warning: helper download did not include a build stamp — re-run bootstrap')
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
