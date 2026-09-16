--[[
	Loads the Dungeon Lootr Ataraxia helper (same chrome as PlayerTools).
]]

local p = 'dungeon-lootr/DungeonLootr.lua'
if type(isfile) == 'function' and not isfile(p) then
	error('[DL] missing ' .. p)
end
assert(loadstring(readfile(p), p))()
