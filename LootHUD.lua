--[[
	Back-compat: HUD path now launches the full Dungeon Lootr menu.
]]

local p = 'dungeon-lootr/DungeonLootr.lua'
if type(isfile) == 'function' and not isfile(p) then
	error('[DL] missing ' .. p)
end
assert(loadstring(readfile(p), p))()
