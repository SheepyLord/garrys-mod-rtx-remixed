-- Bodies for the native core's wave simulation: what each entity near the water is shaped
-- like, and where it is, every frame.
--
-- Props, vehicles and other physics objects use their collision hull (GetMeshConvexes of a
-- client-side copy of the model, sent once per model). Players, NPCs and ragdolls use their
-- hitboxes, boxes that follow the animated bones, so wading legs and swimming arms push the
-- water where they actually are. Anything else falls back to its bounding box. The
-- simulation rasterises these shapes into the water every step (see source/rtx_water/wavesim.cpp).

local W = RTXWater
local R = W.Ripples
local S = W.Surface
local B = W.Bodies or {}
W.Bodies = B

local SEND_RATE = 60   -- body samples a second at most
local ABOVE = 64       -- units above the water a body is still sent (fast ones arrive between scans)
local BELOW = 64       -- and below it
local POSE_RATE = 15   -- poses a second of the local player in first person (setting its bones up costs ~50 us)

B.shapes = B.shapes or {}  -- "hull:model" / "hitbox:model" -> { key, bones } or false
B.nextKey = B.nextKey or 0

-- A box as a triangle soup.
local function boxTris(mins, maxs)
	local x0, y0, z0, x1, y1, z1 = mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z
	local c = { { x0, y0, z0 }, { x1, y0, z0 }, { x1, y1, z0 }, { x0, y1, z0 },
		{ x0, y0, z1 }, { x1, y0, z1 }, { x1, y1, z1 }, { x0, y1, z1 } }
	local faces = { 1, 3, 2, 1, 4, 3, 5, 6, 7, 5, 7, 8, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 4, 8, 3, 8, 7, 4, 1, 5, 4, 5, 8 }
	local v = {}
	for _, i in ipairs(faces) do
		v[#v + 1] = c[i][1]
		v[#v + 1] = c[i][2]
		v[#v + 1] = c[i][3]
	end
	return v
end

-- The collision hull of a model, in entity space.
local function hull(model)
	local p = ents.CreateClientProp(model)
	if not IsValid(p) then return nil end
	p:Spawn()
	local po = p:GetPhysicsObject()
	local parts
	if IsValid(po) then
		for _, convex in ipairs(po:GetMeshConvexes() or {}) do
			local v = {}
			for _, vert in ipairs(convex) do
				local pos = vert.pos
				v[#v + 1] = pos.x
				v[#v + 1] = pos.y
				v[#v + 1] = pos.z
			end
			if #v >= 9 then
				parts = parts or {}
				parts[#parts + 1] = v
			end
		end
	end
	p:Remove()
	return parts
end

-- Hitbox boxes, each in its bone's space.
local function hitboxes(ent)
	local set = ent:GetHitboxSet() or 0
	local parts, bones = {}, {}
	for i = 0, (ent:GetHitBoxCount(set) or 0) - 1 do
		local bone = ent:GetHitBoxBone(i, set)
		local mins, maxs = ent:GetHitBoxBounds(i, set)
		if bone and mins and maxs then
			parts[#parts + 1] = boxTris(mins, maxs)
			bones[#bones + 1] = bone
		end
	end
	if #parts == 0 then return nil end
	return parts, bones
end

local function animated(ent)
	return ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:GetClass() == "prop_ragdoll"
end

-- The shape of an entity, sent to the core the first time its model is seen.
local function shapeOf(ent)
	local model = ent:GetModel()
	if not model or model == "" then return nil end
	local bony = animated(ent)
	local name = (bony and "hitbox:" or "hull:") .. model
	local sh = B.shapes[name]
	if sh ~= nil then return sh or nil end
	local parts, bones
	if bony then
		parts, bones = hitboxes(ent)
	else
		parts = hull(model)
	end
	if not parts then
		local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
		if (maxs - mins):LengthSqr() < 1 then
			B.shapes[name] = false
			return nil
		end
		parts, bones = { boxTris(mins, maxs) }, nil
	end
	B.nextKey = B.nextKey + 1
	sh = { key = B.nextKey, bones = bones }
	RTXWaterNative.SetShape(sh.key, parts)
	B.shapes[name] = sh
	return sh
end

local function bodyId(ent)
	local id = ent:EntIndex()
	if id >= 0 then return id end
	if not ent.RTXWaterBodyId then
		B.nextId = (B.nextId or 1000000) + 1
		ent.RTXWaterBodyId = B.nextId
	end
	return ent.RTXWaterBodyId
end

-- The local player's hitbox matrices in first person. Its model is not drawn then, so
-- nothing sets its bones up: that is done POSE_RATE times a second, and in between the
-- last pose moves with the player.
local function firstPersonPose(lp, bones)
	local now, pos = CurTime(), lp:GetPos()
	local pose = B.pose
	local valid = pose and pose.bones == bones and now >= pose.t
	-- standing still, the last pose still stands
	if valid and pos:DistToSqr(pose.origin) < 0.01 and lp:GetVelocity():LengthSqr() < 1 then return pose.m end
	if not valid or now - pose.t >= 1 / POSE_RATE then
		lp:SetupBones()
		pose = { t = now, origin = pos, bones = bones, m = {} }
		for i = 1, #bones do
			local m = lp:GetBoneMatrix(bones[i])
			if not m then return nil end
			pose.m[i] = m
		end
		B.pose = pose
		return pose.m
	end
	local d, out = pos - pose.origin, {}
	for i, m in ipairs(pose.m) do
		local c = Matrix(m)
		c:SetTranslation(m:GetTranslation() + d)
		out[i] = c
	end
	return out
end

-- { id, shape, matrices... } for SetBodies.
local function entry(ent, sh, lp)
	if not sh.bones then return { bodyId(ent), sh.key, ent:GetWorldTransformMatrix() } end
	local e = { bodyId(ent), sh.key }
	local bones = sh.bones
	if ent == lp and not lp:ShouldDrawLocalPlayer() then
		local ms = firstPersonPose(lp, bones)
		if not ms then return nil end
		for i = 1, #ms do e[i + 2] = ms[i] end
		return e
	end
	for i = 1, #bones do
		local m = ent:GetBoneMatrix(bones[i])
		if not m then
			ent:SetupBones()
			m = ent:GetBoneMatrix(bones[i])
			if not m then return nil end
		end
		e[i + 2] = m
	end
	return e
end

local function inReach(ent)
	local mins, maxs = ent:WorldSpaceAABB()
	for _, plane in ipairs(S.planes) do
		local b = plane.bounds
		if mins.z < plane.z + ABOVE and maxs.z > plane.z - BELOW and maxs.x > b[1] and mins.x < b[3]
			and maxs.y > b[2] and mins.y < b[4] then
			return true
		end
	end
	return false
end

-- Each frame, up to SEND_RATE a second: every body within reach of the water. The core
-- interpolates between these samples, so its steps see smooth motion.
function B.Send()
	local now = CurTime()
	if now - (B.last or 0) < 1 / SEND_RATE then return end
	B.last = now
	local list, lp = {}, LocalPlayer()
	for ent in pairs(R.tracked) do
		if IsValid(ent) and R.Active(ent) and inReach(ent) then
			local sh = shapeOf(ent)
			local e = sh and entry(ent, sh, lp)
			if e then list[#list + 1] = e end
		end
	end
	if #list == 0 and not B.sentAny then return end
	B.sentAny = #list > 0
	RTXWaterNative.SetBodies(now, list)
end

function B.Reset()
	B.shapes, B.nextKey, B.sentAny, B.last, B.pose = {}, 0, false, nil, nil
end
