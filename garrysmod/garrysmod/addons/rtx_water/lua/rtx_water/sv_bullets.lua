-- RTX Water, server side: where bullets go into the water.
--
-- A client only sees the shots it predicts itself, its own in multiplayer: never other
-- players' or NPCs', and in single player not even its own. So the server reports every
-- shot that reaches water to the players who can see or hear it there, and cl_ripples.lua
-- turns them into waves and splashes. This is all of RTX Water that runs on the server.
--
-- PostEntityFireBullets hands over each pellet's own trace, which passes through water as if
-- it were not there; the first water along it is where the bullet went in.

util.AddNetworkString("rtx_water_shots")

local LIQUID = bit.bor(CONTENTS_WATER, CONTENTS_SLIME)
local MAX_SHOTS = 31  -- entry points one message carries (a tick's pellets)

local queue = {}

local function send()
	local n = math.min(#queue, MAX_SHOTS)
	if n == 0 then return end
	local rf = RecipientFilter()
	net.Start("rtx_water_shots", true)
	net.WriteUInt(n, 5)
	for i = 1, n do
		local q = queue[i]
		net.WriteVector(q.pos)
		net.WriteNormal(q.dir)
		net.WriteUInt(q.power, 8)
		rf:AddPAS(q.pos)
	end
	-- (one player, who may be looking through a camera somewhere else)
	if game.SinglePlayer() then net.Broadcast() else net.Send(rf) end
	queue = {}
end

-- How hard a bullet hits, 1 for a pistol round: the square root of its damage over 10.
-- Engine weapons leave the damage to their ammo type.
local function power(data)
	local dmg = tonumber(data.Damage) or 0
	if dmg <= 0 and isstring(data.AmmoType) then
		local id = game.GetAmmoID(data.AmmoType)
		if id and id >= 0 then
			local att = data.Attacker
			dmg = (IsValid(att) and att:IsPlayer()) and game.GetAmmoPlayerDamage(id) or game.GetAmmoNPCDamage(id)
		end
	end
	if not dmg or dmg <= 0 then dmg = 10 end
	return math.Clamp(math.sqrt(dmg / 10), 0.5, 3)
end

hook.Add("PostEntityFireBullets", "RTXWater_Shots", function(ent, data)
	local tr = data.Trace
	if not tr or not tr.StartPos or not tr.HitPos then return end
	local from = tr.StartPos
	-- fired under water: there is no surface for it to break
	if bit.band(util.PointContents(from), LIQUID) ~= 0 then return end
	local w = util.TraceLine({ start = from, endpos = tr.HitPos, mask = LIQUID })
	if not w.Hit or w.StartSolid or #queue >= MAX_SHOTS then return end
	if #queue == 0 then timer.Simple(0, send) end
	queue[#queue + 1] = { pos = w.HitPos, dir = tr.Normal, power = math.Clamp(math.Round(power(data) * 32), 1, 255) }
end)
