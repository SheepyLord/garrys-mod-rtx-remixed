-- RTX Water splashes: the water thrown up when something falls in, is pulled out or is hit
-- by a bullet. The wave simulation is a height field, which cannot leave the surface, so the
-- spray is drawn on its own, as real geometry in the water's own material: Remix refracts
-- and reflects through it as through the surface.
-- * Drops: small spheres stretched along their flight, falling under the game's gravity
--   with air drag. Those that come down on the water make rings of their own (R.Drop).
-- * The crown: the sheet a body throws up around itself as it goes in. It rises and flares
--   with the speed the body hit the water at, its rim breaking into drops, and falls back.
-- * The jet: the column that shoots up where a compact, fast body or a bullet went in,
--   once the cavity behind it closes. Its tip pinches off into drops.
-- A splash leans with the way the water was hit. Hit at a slant, the water ahead of the
-- body or bullet is thrown forward: the crown is drawn out along its path and leans ahead,
-- and so does most of the spray. The cavity runs down along the path, so the jet that comes
-- out of it leans back towards where the hit came from, and a bullet throws some spray back
-- up its path.
-- A body pulled out lifts a sheet of water that falls off its underside, and drips for a
-- while after. Every piece is one of three static meshes drawn under its own transform, so
-- a splash costs no vertex work in Lua, and Remix sees the same three meshes every frame.

local W = RTXWater
local S = W.Surface
local P = W.Splash or {}
W.Splash = P

local sqrt, min, max, floor, abs = math.sqrt, math.min, math.max, math.floor, math.abs
local cos, sin, random = math.cos, math.sin, math.random
local TAU = 2 * math.pi

local FAR = 3000          -- units from the camera beyond which pieces are not drawn
local DRAG = 0.0015       -- quadratic air drag of a drop, over its radius: fast spray slows down
local CROWN_WALL = 0.035  -- thickness of the crown's sheet, of its radius
local CROWN_FLARE = 0.25  -- how far the crown's top flares out, of its radius
local CROWN_BREAK = 1.6   -- the crown breaks up into drops this many rise times after the hit
local MAX_CROWNS = 24
local MAX_JETS = 32
local JET_ROOT = 3        -- units of a jet below the surface, where the crater it rises from is
local DRIP_TIME = 3       -- s a body pulled out of the water drips for
local DRIP_HEIGHT = 300   -- units above the water past which a body no longer drips onto it
-- At a grazing hit (and less the steeper it is), per unit of height or upward speed:
local SPRAY_LEAN = 1.2    -- spray thrown ahead
local CROWN_LEAN = 0.7    -- the crown's top ahead of its foot (and the crown 1.5 times as long)
local JET_LEAN = 0.7      -- the jet's tip back up the path
local BACK_SPRAY = 0.2    -- share of a bullet's spray thrown back up its path

-- (pieces from before a reload of this file may lack fields: start afresh)
P.drops, P.crowns, P.jets, P.wet = {}, {}, {}, {}
P.maxDrops = P.maxDrops or 200
P.strength = P.strength or 1
local drops, crowns, jets = P.drops, P.crowns, P.jets

local gravity = GetConVar("sv_gravity")

local function rand(a, b) return a + (b - a) * random() end

---------------------------------------------------------------- the three meshes

-- Clockwise seen from where the vertex normals point, which is the front for Source and
-- Remix: rays enter the water through the outside of every piece.
local function tri(out, a, b, c)
	local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
	local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
	local fx, fy, fz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
	if fx * fx + fy * fy + fz * fz < 1e-12 then return end
	if fx * (a[4] + b[4] + c[4]) + fy * (a[5] + b[5] + c[5]) + fz * (a[6] + b[6] + c[6]) > 0 then b, c = c, b end
	out[#out + 1] = a
	out[#out + 1] = b
	out[#out + 1] = c
end

-- A closed surface of revolution about z, as triangles. profile = {rho, z, ...} runs
-- counter-clockwise in the (rho, z) half plane: from the axis round to the axis, or round a
-- loop (closed). lift(theta, z) moves its points up or down (the crown's points).
local function lathe(profile, seg, closed, lift)
	local np = #profile / 2
	local nr, nz = {}, {}
	for k = 1, np do
		local a, b = k - 1, k + 1
		if closed then
			a, b = a < 1 and np or a, b > np and 1 or b
		else
			a, b = max(a, 1), min(b, np)
		end
		local dr, dz = profile[2 * b - 1] - profile[2 * a - 1], profile[2 * b] - profile[2 * a]
		local l = sqrt(dr * dr + dz * dz)
		nr[k], nz[k] = dz / l, -dr / l
	end
	local rows = {}
	for i = 0, seg do
		local th = TAU * i / seg
		local c, s = cos(th), sin(th)
		local row = {}
		for k = 1, np do
			local r, z = profile[2 * k - 1], profile[2 * k]
			if lift then z = lift(th, z) end
			row[k] = { r * c, r * s, z, nr[k] * c, nr[k] * s, nz[k], i / seg, z }
		end
		rows[i] = row
	end
	local out = {}
	for i = 0, seg - 1 do
		local A, B = rows[i], rows[i + 1]
		for k = 1, closed and np or np - 1 do
			local k2 = k % np + 1
			tri(out, A[k], B[k], B[k2])
			tri(out, A[k], B[k2], A[k2])
		end
	end
	return out
end

-- Unit sphere, from the bottom pole round to the top one.
local function sphere(rings)
	local p = {}
	for k = 0, rings do
		local a = math.pi * k / rings
		p[#p + 1] = sin(a)
		p[#p + 1] = -cos(a)
	end
	return p
end

-- The crown's sheet: radius 1 at its foot (z = 0), flaring to 1 + CROWN_FLARE at its rounded
-- lip (z = 1), CROWN_WALL thick; a loop up the outside, over the lip and down the inside.
local function crownProfile()
	local p, w, top = {}, CROWN_WALL, 0.97
	local function rim(t) return 1 + CROWN_FLARE * t * t end
	for k = 0, 5 do
		local t = top * k / 5
		p[#p + 1] = rim(t)
		p[#p + 1] = t
	end
	local cr = rim(top) - w * 0.5
	for k = 1, 4 do
		local a = math.pi * k / 5
		p[#p + 1] = cr + w * 0.5 * cos(a)
		p[#p + 1] = top + (1 - top) * sin(a)
	end
	for k = 5, 0, -1 do
		local t = top * k / 5
		p[#p + 1] = rim(t) - w
		p[#p + 1] = t
	end
	return p
end

-- The jet: a column from its root (z = 0, below the surface) up to a rounded tip (z = 1),
-- wide where it leaves the water and narrowing, with a bulb at the top that pinches off.
local JET = {
	0, 0, 1.7, 0, 1.6, 0.07, 1.1, 0.12, 0.85, 0.3, 0.7, 0.55, 0.6, 0.76,
	0.7, 0.86, 0.62, 0.95, 0.36, 0.995, 0, 1,
}

local V, NV = Vector(), Vector()

local function build(tris)
	local m = Mesh(P.mat)
	mesh.Begin(m, MATERIAL_TRIANGLES, #tris / 3)
	for _, v in ipairs(tris) do
		V:SetUnpacked(v[1], v[2], v[3])
		mesh.Position(V)
		NV:SetUnpacked(v[4], v[5], v[6])
		mesh.Normal(NV)
		mesh.TexCoord(0, v[7], v[8])
		mesh.AdvanceVertex()
	end
	mesh.End()
	return m
end

local function buildMeshes()
	P.dropMesh = build(lathe(sphere(7), 12, false))
	P.jetMesh = build(lathe(JET, 14, false))
	-- seven points round the crown's lip
	P.crownMesh = build(lathe(crownProfile(), 32, true, function(th, z) return z * (1 + 0.12 * cos(7 * th) * z * z) end))
end

---------------------------------------------------------------- settings

function P.Configure(s)
	P.enabled = s.splashes
	P.strength = s.splashStrength
	P.maxDrops = s.splashDrops
	local tag = RTXWater_Data.types[s.type].tags.calm.texture
	if not P.mat then
		-- the calm material of the water's type: drops have no use for the waves' normal map
		P.mat = CreateMaterial("RTXWater_Splash", "UnlitGeneric", { ["$basetexture"] = tag, ["$nocull"] = 1 })
	end
	local t = P.mat:GetTexture("$basetexture")
	if not t or t:GetName() ~= tag then P.mat:SetTexture("$basetexture", tag) end
	if not P.enabled then P.Clear() end
end

function P.Clear()
	for i = #drops, 1, -1 do drops[i] = nil end
	for i = #crowns, 1, -1 do crowns[i] = nil end
	for i = #jets, 1, -1 do jets[i] = nil end
	P.wet = {}
end

function P.Count() return #drops end

---------------------------------------------------------------- pieces

-- A drop of radius r at (x, y, z), coming down on `plane`'s height.
local function addDrop(plane, x, y, z, vx, vy, vz, r)
	if #drops >= P.maxDrops then return end
	drops[#drops + 1] = { x = x, y = y, z = max(z, plane.z + 0.1), vx = vx, vy = vy, vz = vz, r = r, plane = plane }
end

-- The way a hit along (dx, dy, dz) went across the water, (fx, fy), and how oblique it
-- was, h: 0 straight down, 1 grazing. A straight drop gets a random way (the crown's points).
local function heading(dx, dy, dz)
	local hz = sqrt(dx * dx + dy * dy)
	local l = sqrt(hz * hz + dz * dz)
	if hz < 1e-3 or l < 1e-3 then
		local a = rand(0, TAU)
		return cos(a), sin(a), 0
	end
	return dx / hz, dy / hz, hz / l
end

-- The crown rises for rise = vh / g seconds, widening by vr at first and less as it slows.
local function addCrown(plane, x, y, fx, fy, h, fields)
	if #crowns >= MAX_CROWNS then return end
	fields.plane, fields.x, fields.y, fields.z, fields.t0 = plane, x, y, plane.z, CurTime()
	fields.fx, fields.fy, fields.sx, fields.shear = fx, fy, 1 + 0.5 * h, CROWN_LEAN * h
	fields.rise = fields.vh / (gravity and gravity:GetFloat() or 600)
	fields.acc = 0
	crowns[#crowns + 1] = fields
end

-- A jet that rises from (x, y) after `delay`, leaning back up the path of the hit.
local function addJet(plane, x, y, fx, fy, h, delay, r, vj, tip)
	if #jets >= MAX_JETS then return end
	jets[#jets + 1] = {
		plane = plane, x = x, y = y, z = plane.z, t0 = CurTime() + delay, r = r, vj = vj, tip = tip,
		lx = -fx * JET_LEAN * h, ly = -fy * JET_LEAN * h,
	}
end

local LP = Vector()

-- A point low on a body: the lowest of three on the faces of its bounding box.
local function lowPoint(ent)
	local a, b = ent:OBBMins(), ent:OBBMaxs()
	local best
	for _ = 1, 3 do
		local x, y, z = rand(a.x, b.x), rand(a.y, b.y), rand(a.z, b.z)
		local side = random(1, 6)
		if side == 1 then x = a.x elseif side == 2 then x = b.x elseif side == 3 then y = a.y
		elseif side == 4 then y = b.y elseif side == 5 then z = a.z else z = b.z end
		LP:SetUnpacked(x, y, z)
		local w = ent:LocalToWorld(LP)
		if not best or w.z < best.z then best = w end
	end
	return best
end

-- A body of equivalent radius re hit the water at (x, y), going down at `speed` (units/s) and
-- across it at (vx, vy). The faster and the larger, the higher the crown and the more spray;
-- a compact body going in fast leaves a cavity that closes into a jet.
function P.Entry(plane, x, y, speed, re, vx, vy)
	if not P.enabled or P.strength <= 0 or speed < 60 then return end
	local s = P.strength
	local fx, fy, h = heading(vx or 0, vy or 0, -speed)
	local k = min(speed / 300, 3)
	local size = math.Clamp(re / 12, 0.25, 4)
	local vh = math.Clamp(0.45 * speed, 40, 520) * sqrt(s)
	if re >= 2.5 then
		local n = floor(math.Clamp((8 + 26 * k) * sqrt(size), 4, 64) * s)
		addCrown(plane, x, y, fx, fy, h, {
			r0 = re * 1.05 + 1, vr = 0.15 * vh, vh = vh, budget = n, rate = n * 600 / vh,
			dropR = math.Clamp(0.35 * sqrt(size), 0.25, 1.2),
		})
	end
	-- spray thrown up and out from round the body as it goes in, ahead of it at a slant
	local lean = SPRAY_LEAN * h
	local n = floor(math.Clamp((6 + 18 * k) * sqrt(size), 4, 48) * s)
	for _ = 1, n do
		local a, rr = rand(0, TAU), re * rand(0.8, 1.15)
		local out, up = vh * rand(0.1, 0.5), vh * rand(0.5, 1.25)
		addDrop(plane, x + cos(a) * rr, y + sin(a) * rr, plane.z + 0.5, cos(a) * out + fx * lean * up,
			sin(a) * out + fy * lean * up, up, rand(0.3, 0.9) * math.Clamp(sqrt(size), 0.7, 1.6))
	end
	if re < 10 and speed > 220 then
		addJet(plane, x, y, fx, fy, h, 0.12 + re / 120, math.Clamp(re * 0.5, 1, 4), math.Clamp(0.35 * speed, 80, 260) * sqrt(s), 4)
	end
end

-- A body left the water at `speed` (units/s, upwards): the water it lifts falls off its
-- underside, and it drips for a while.
function P.Exit(plane, ent, speed, re)
	if not P.enabled or P.strength <= 0 then return end
	local k = min(speed / 300, 2.5) * P.strength
	local vel = ent:GetVelocity()
	local n = floor(math.Clamp((4 + 14 * k) * sqrt(math.Clamp(re / 12, 0.25, 4)), 3, 40))
	for _ = 1, n do
		local p = lowPoint(ent)
		addDrop(plane, p.x, p.y, p.z, vel.x * 0.5 + rand(-20, 20), vel.y * 0.5 + rand(-20, 20), speed * rand(0.1, 0.6),
			rand(0.35, 0.9))
	end
	P.wet[ent] = { t0 = CurTime(), plane = plane, rate = math.Clamp(re * 0.8, 3, 24) * P.strength, acc = 0 }
end

-- A bullet went in at (x, y) along dir; power 1 for a pistol round. A plume of fine spray,
-- the short, thick jet of its closing cavity and a small crown.
function P.Shot(plane, x, y, dir, power)
	if not P.enabled or P.strength <= 0 then return end
	local s = P.strength
	local p = sqrt(power)
	local fx, fy, h = heading(dir.x, dir.y, dir.z)
	for _ = 1, floor((10 + 8 * power) * s) do
		local up, lat, a = rand(150, 320) * p, rand(5, 45) * p, rand(0, TAU)
		local lean = random() < BACK_SPRAY and -0.5 * h or SPRAY_LEAN * h
		addDrop(plane, x, y, plane.z + 0.3, cos(a) * lat + fx * lean * up, sin(a) * lat + fy * lean * up, up, rand(0.18, 0.4))
	end
	addJet(plane, x, y, fx, fy, h, 0.08, 1.0 * p, 90 * p * sqrt(s), 2)
	addCrown(plane, x, y, fx, fy, h, { r0 = 1.2 * p, vr = 15 * p, vh = 55 * p * sqrt(s), budget = 0, rate = 0, dropR = 0.25 })
end

---------------------------------------------------------------- per frame

-- Moves everything on by the time since the last frame. Drops that come down on the water
-- make rings there.
function P.Think()
	local now = CurTime()
	local dt = now - (P.last or now)
	P.last = now
	if dt <= 0 then return end
	if dt > 0.1 then dt = 0.1 end
	local g = gravity and gravity:GetFloat() or 600
	local R = W.Ripples

	local i, n = 1, #drops
	while i <= n do
		local d = drops[i]
		local sp = sqrt(d.vx * d.vx + d.vy * d.vy + d.vz * d.vz)
		local k = 1 / (1 + DRAG / d.r * sp * dt)
		d.vx, d.vy, d.vz = d.vx * k, d.vy * k, (d.vz - g * dt) * k
		d.x, d.y, d.z = d.x + d.vx * dt, d.y + d.vy * dt, d.z + d.vz * dt
		local z = d.plane.z
		if d.z <= z and d.vz < 0 then
			if S.PlaneAt(d.x, d.y, z - 0.5, z + 0.5) == d.plane then R.Drop(d.plane, d.x, d.y, d.r, -d.vz) end
			drops[i] = drops[n]
			drops[n] = nil
			n = n - 1
		else
			i = i + 1
		end
	end

	for c = #crowns, 1, -1 do
		local cr = crowns[c]
		local age = now - cr.t0
		local top = cr.vh * age - 0.5 * g * age * age
		local u = min(age / cr.rise, 1)
		cr.H = max(top, 0.5)
		cr.R = cr.r0 + 0.5 * cr.vr * cr.rise * (2 * u - u * u)
		local vtop = cr.vh - g * age
		local fx, fy, sx, lean = cr.fx, cr.fy, cr.sx, cr.shear
		-- a drop from its rim at angle a, thrown out along its lean
		local function rimDrop(a, out, up, r)
			local ca, sa = cos(a), sin(a)
			local s, w = ca * sx * (1 + CROWN_FLARE) * cr.R, sa * (1 + CROWN_FLARE) * cr.R
			local ox, oy = fx * ca - fy * sa, fy * ca + fx * sa
			addDrop(cr.plane, cr.x + fx * (s + lean * cr.H) - fy * w, cr.y + fy * (s + lean * cr.H) + fx * w, cr.z + cr.H,
				ox * out + fx * lean * up, oy * out + fy * lean * up, up, r)
		end
		if (top <= 0 and age > 0.02) or age >= CROWN_BREAK * cr.rise then
			-- falling back, the sheet breaks up into a ring of drops
			if top > 1 then
				local n = floor(math.Clamp(cr.R / 2, 4, 24))
				local a0 = rand(0, TAU)
				for k = 1, n do rimDrop(a0 + TAU * k / n, cr.vr * rand(0.1, 0.4), vtop * rand(0.7, 1.0), cr.dropR * rand(0.8, 1.4)) end
			end
			table.remove(crowns, c)
		elseif vtop > 0 and cr.budget > 0 then
			-- while the sheet rises, its rim breaks up into drops
			cr.acc = cr.acc + cr.rate * dt
			while cr.acc >= 1 and cr.budget > 0 do
				cr.acc, cr.budget = cr.acc - 1, cr.budget - 1
				rimDrop(rand(0, TAU), cr.vr + rand(0, 0.35) * cr.vh, vtop * rand(0.8, 1.25), cr.dropR * rand(0.6, 1.3))
			end
		end
	end

	for j = #jets, 1, -1 do
		local jt = jets[j]
		local age = now - jt.t0
		if age >= 0 then
			local top = jt.vj * age - 0.5 * g * age * age
			if top <= 0 and age > 0.02 then
				table.remove(jets, j)
			else
				jt.H = max(top, 0.5)
				-- at the top of its rise the tip pinches off and flies on, along the jet
				if not jt.pinched and jt.vj - g * age <= 0 then
					jt.pinched = true
					for _ = 1, jt.tip do
						local up = rand(0.05, 0.3) * jt.vj
						addDrop(jt.plane, jt.x + jt.lx * jt.H + rand(-0.5, 0.5) * jt.r, jt.y + jt.ly * jt.H + rand(-0.5, 0.5) * jt.r,
							jt.z + jt.H, jt.lx * up + rand(-12, 12), jt.ly * up + rand(-12, 12), up, jt.r * rand(0.6, 1.0))
					end
				end
			end
		end
	end

	for ent, w in pairs(P.wet) do
		local age = now - w.t0
		if not IsValid(ent) or age > DRIP_TIME then
			P.wet[ent] = nil
		else
			local mins = ent:WorldSpaceAABB()
			local z = w.plane.z
			if mins.z <= z then
				P.wet[ent] = nil -- back in the water
			elseif mins.z < z + DRIP_HEIGHT then
				local f = 1 - age / DRIP_TIME
				w.acc = w.acc + w.rate * f * f * dt
				while w.acc >= 1 do
					w.acc = w.acc - 1
					local p = lowPoint(ent)
					if S.PlaneAt(p.x, p.y, z - 0.5, z + 0.5) then
						addDrop(w.plane, p.x, p.y, p.z, rand(-4, 4), rand(-4, 4), 0, rand(0.3, 0.6))
					end
				end
			end
		end
	end
end

---------------------------------------------------------------- drawing

local M = Matrix()

-- Columns a, b, c (where the mesh's x, y and z axes go) and the origin.
local function place(ax, ay, az, bx, by, bz, cx, cy, cz, x, y, z)
	M:SetUnpacked(ax, bx, cx, x, ay, by, cy, y, az, bz, cz, z, 0, 0, 0, 1)
	cam.PushModelMatrix(M)
end

function P.Draw()
	if #drops == 0 and #crowns == 0 and #jets == 0 then return end
	if not P.mat then return end
	if not P.dropMesh then buildMeshes() end
	local eye = EyePos()
	local ex, ey, ez = eye.x, eye.y, eye.z
	local far2 = FAR * FAR
	render.SetMaterial(P.mat)

	local m = P.dropMesh
	for _, d in ipairs(drops) do
		local dx, dy, dz = d.x - ex, d.y - ey, d.z - ez
		if dx * dx + dy * dy + dz * dz < far2 then
			-- stretched along its flight, keeping its volume
			local vx, vy, vz = d.vx, d.vy, d.vz
			local sp = sqrt(vx * vx + vy * vy + vz * vz)
			local ux, uy, uz = 0, 0, 1
			if sp > 1 then ux, uy, uz = vx / sp, vy / sp, vz / sp end
			local ax, ay, az
			if abs(uz) < 0.9 then
				local l = sqrt(ux * ux + uy * uy)
				ax, ay, az = uy / l, -ux / l, 0
			else
				local l = sqrt(uy * uy + uz * uz)
				ax, ay, az = 0, uz / l, -uy / l
			end
			local bx, by, bz = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
			local st = 1 + min(sp / 500, 1.2)
			local r, rs = d.r / sqrt(st), d.r * st
			place(ax * r, ay * r, az * r, bx * r, by * r, bz * r, ux * rs, uy * rs, uz * rs, d.x, d.y, d.z)
			m:Draw()
			cam.PopModelMatrix()
		end
	end

	m = P.crownMesh
	for _, c in ipairs(crowns) do
		if c.H then
			local dx, dy, dz = c.x - ex, c.y - ey, c.z - ez
			if dx * dx + dy * dy + dz * dz < far2 then
				-- drawn out along the hit and leaning ahead, its foot a unit under the surface
				local fx, fy, h = c.fx, c.fy, c.H + 1
				local a, b, l = c.R * c.sx, c.R, c.shear * h
				place(fx * a, fy * a, 0, -fy * b, fx * b, 0, fx * l, fy * l, h, c.x, c.y, c.z - 1)
				m:Draw()
				cam.PopModelMatrix()
			end
		end
	end

	m = P.jetMesh
	for _, j in ipairs(jets) do
		if j.H then
			local dx, dy, dz = j.x - ex, j.y - ey, j.z - ez
			if dx * dx + dy * dy + dz * dz < far2 then
				-- leaning back up the path; its root under the surface, on the same slant
				local h = j.H + JET_ROOT
				place(j.r, 0, 0, 0, j.r, 0, j.lx * h, j.ly * h, h, j.x - j.lx * JET_ROOT, j.y - j.ly * JET_ROOT, j.z - JET_ROOT)
				m:Draw()
				cam.PopModelMatrix()
			end
		end
	end
end
