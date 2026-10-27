-- Bodies: what each entity near the water is shaped like. The native core's wave
-- simulation gets every body's shape and pose every frame; splashes get the outline of the
-- part of a body that is going into (or coming out of) the water.
--
-- Props, vehicles and other physics objects use their collision hull (GetMeshConvexes of a
-- client-side copy of the model, made once per model). Players, NPCs and ragdolls use their
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

B.data = B.data or {}       -- "hull:model" / "hitbox:model" -> { parts, bones, corners } or false
B.keys = B.keys or {}       -- the same names -> the core's shape key, once sent to it
B.pending = B.pending or {} -- entity -> shape name, to be made outside the frame
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

local function shapeName(ent)
	local model = ent:GetModel()
	if not model or model == "" then return nil end
	return (animated(ent) and "hitbox:" or "hull:") .. model
end

-- Each part's corners once (its triangle soup repeats them), for footprints.
local function corners(parts)
	local out = {}
	for i, v in ipairs(parts) do
		local seen, c = {}, {}
		for k = 1, #v - 2, 3 do
			local key = string.format("%.1f %.1f %.1f", v[k], v[k + 1], v[k + 2])
			if not seen[key] then
				seen[key] = true
				c[#c + 1] = v[k]
				c[#c + 1] = v[k + 1]
				c[#c + 1] = v[k + 2]
			end
		end
		out[i] = c
	end
	return out
end

-- The shape of an entity, made the first time its model is seen. A hull comes from a
-- client-side prop, which must not be spawned or removed while a frame is drawn, and B.Send
-- and the splashes run in the draw hook: so they only look shapes up, and the scan (a
-- timer) makes the missing ones with B.Prepare.
local function makeShape(ent, name)
	local parts, bones
	if animated(ent) then
		parts, bones = hitboxes(ent)
	else
		parts = hull(ent:GetModel())
	end
	if not parts then
		local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
		if (maxs - mins):LengthSqr() < 1 then
			B.data[name] = false
			return
		end
		parts, bones = { boxTris(mins, maxs) }, nil
	end
	B.data[name] = { parts = parts, bones = bones, corners = corners(parts) }
end

-- The shape of an entity and its key in the core, which gets it the first time it is used.
local function shapeOf(ent)
	local name = shapeName(ent)
	if not name then return nil end
	local d = B.data[name]
	if d == nil then B.pending[ent] = name end
	if not d then return nil end
	local key = B.keys[name]
	if not key then
		B.nextKey = B.nextKey + 1
		key = B.nextKey
		RTXWaterNative.SetShape(key, d.parts)
		B.keys[name] = key
	end
	return d, key
end

-- Asks for an entity's shape to be made (by the next B.Prepare).
function B.Want(ent)
	local name = shapeName(ent)
	if name and B.data[name] == nil then B.pending[ent] = name end
end

function B.Prepare()
	for ent, name in pairs(B.pending) do
		B.pending[ent] = nil
		if IsValid(ent) and B.data[name] == nil then makeShape(ent, name) end
	end
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

-- Where the parts of a body are now: one matrix for all of them, or one per hitbox.
local function placement(ent, d, lp)
	if not d.bones then return { ent:GetWorldTransformMatrix() } end
	local bones = d.bones
	if ent == lp and not lp:ShouldDrawLocalPlayer() then return firstPersonPose(lp, bones) end
	local ms = {}
	for i = 1, #bones do
		local m = ent:GetBoneMatrix(bones[i])
		if not m then
			ent:SetupBones()
			m = ent:GetBoneMatrix(bones[i])
			if not m then return nil end
		end
		ms[i] = m
	end
	return ms
end

-- { id, shape, matrices... } for SetBodies.
local function entry(ent, d, key, lp)
	local ms = placement(ent, d, lp)
	if not ms then return nil end
	local e = { bodyId(ent), key }
	for i = 1, #ms do e[i + 2] = ms[i] end
	return e
end

---------------------------------------------------------------- footprints

-- Convex hull of points {x1, y1, x2, y2, ...}, counter-clockwise (monotone chain), or nil.
local function hull2d(p)
	local n = #p / 2
	if n < 3 then return nil end
	local idx = {}
	for i = 1, n do idx[i] = i end
	table.sort(idx, function(a, b)
		local ax, bx = p[2 * a - 1], p[2 * b - 1]
		if ax ~= bx then return ax < bx end
		return p[2 * a] < p[2 * b]
	end)
	local function turn(o, a, b)
		local ox, oy = p[2 * o - 1], p[2 * o]
		return (p[2 * a - 1] - ox) * (p[2 * b] - oy) - (p[2 * a] - oy) * (p[2 * b - 1] - ox)
	end
	local lower, upper = {}, {}
	for k = 1, n do
		local i = idx[k]
		while #lower >= 2 and turn(lower[#lower - 1], lower[#lower], i) <= 1e-6 do lower[#lower] = nil end
		lower[#lower + 1] = i
	end
	for k = n, 1, -1 do
		local i = idx[k]
		while #upper >= 2 and turn(upper[#upper - 1], upper[#upper], i) <= 1e-6 do upper[#upper] = nil end
		upper[#upper + 1] = i
	end
	local out = {}
	for k = 1, #lower - 1 do out[#out + 1], out[#out + 2] = p[2 * lower[k] - 1], p[2 * lower[k]] end
	for k = 1, #upper - 1 do out[#out + 1], out[#out + 2] = p[2 * upper[k] - 1], p[2 * upper[k]] end
	if #out < 6 then return nil end
	return out
end

-- An outline: its polygon, area, perimeter, centre and the radius round that centre.
local function outline(poly)
	local a = S.area(poly)
	if a < 0.5 then return nil end
	local n, cx, cy, per, r = #poly, 0, 0, 0, 0
	for k = 1, n, 2 do cx, cy = cx + poly[k], cy + poly[k + 1] end
	cx, cy = cx * 2 / n, cy * 2 / n
	local px, py = poly[n - 1], poly[n]
	for k = 1, n, 2 do
		local x, y = poly[k], poly[k + 1]
		per = per + math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
		r = math.max(r, math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2))
		px, py = x, y
	end
	return { poly = poly, area = a, perimeter = per, x = cx, y = cy, r = r }
end

local function boxCorners(mins, maxs)
	local c = {}
	for k = 0, 7 do
		c[#c + 1] = (k % 2 == 0) and mins.x or maxs.x
		c[#c + 1] = (math.floor(k / 2) % 2 == 0) and mins.y or maxs.y
		c[#c + 1] = (k < 4) and mins.z or maxs.z
	end
	return c
end

-- The plan of a body's lowest `depth` units above height z0, as seen from above: for each
-- convex part, the hull of its corners in that slice and of where the lines between them
-- cross the slice's top. Parts whose plans overlap are merged, so two legs going in make two
-- outlines and a crate one. Returns a list of outlines (see outline()), largest first.
function B.Footprint(ent, z0, depth)
	local name = shapeName(ent)
	local d = name and B.data[name]
	local parts, mats
	if d then
		parts, mats = d.corners, placement(ent, d, LocalPlayer())
	end
	if not mats then
		-- not made yet: its bounding box
		parts, mats = { boxCorners(ent:OBBMins(), ent:OBBMaxs()) }, { ent:GetWorldTransformMatrix() }
	end
	local zc = z0 + depth
	local plans = {}
	for i, c in ipairs(parts) do
		local m = mats[#mats == 1 and 1 or i]
		if m then
			local e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12 = m:Unpack()
			local wv, below = {}, false
			for k = 1, #c - 2, 3 do
				local x, y, z = c[k], c[k + 1], c[k + 2]
				local wz = e9 * x + e10 * y + e11 * z + e12
				wv[k], wv[k + 1], wv[k + 2] = e1 * x + e2 * y + e3 * z + e4, e5 * x + e6 * y + e7 * z + e8, wz
				below = below or wz <= zc
			end
			if below then
				local pts = {}
				for k = 1, #wv - 2, 3 do
					local x, y, z = wv[k], wv[k + 1], wv[k + 2]
					if z <= zc then
						pts[#pts + 1], pts[#pts + 2] = x, y
						for j = 3, #wv, 3 do
							local zj = wv[j]
							if zj > zc then
								local t = (zc - z) / (zj - z)
								pts[#pts + 1], pts[#pts + 2] = x + (wv[j - 2] - x) * t, y + (wv[j - 1] - y) * t
							end
						end
					end
				end
				local o = outline(hull2d(pts) or {})
				if o then plans[#plans + 1] = { o = o, pts = pts } end
			end
		end
	end
	-- merge plans that overlap
	local merged = true
	while merged do
		merged = false
		for i = 1, #plans do
			for j = i + 1, #plans do
				local a, b = plans[i].o, plans[j].o
				if (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 < (a.r + b.r) ^ 2 * 0.8 then
					local pts = plans[i].pts
					for _, v in ipairs(plans[j].pts) do pts[#pts + 1] = v end
					local o = outline(hull2d(pts) or {})
					if o then plans[i].o = o end
					table.remove(plans, j)
					merged = true
					break
				end
			end
			if merged then break end
		end
	end
	local out = {}
	for _, p in ipairs(plans) do out[#out + 1] = p.o end
	table.sort(out, function(a, b) return a.area > b.area end)
	return out
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
			local d, key = shapeOf(ent)
			local e = d and entry(ent, d, key, lp)
			if e then list[#list + 1] = e end
		end
	end
	if #list == 0 and not B.sentAny then return end
	B.sentAny = #list > 0
	RTXWaterNative.SetBodies(now, list)
end

-- (the shapes themselves stay: they do not change, and the core gets them again by key)
function B.Reset()
	B.keys, B.pending, B.nextKey, B.sentAny, B.last, B.pose = {}, {}, 0, false, nil, nil
end
