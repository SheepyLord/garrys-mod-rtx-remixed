-- RTX Water splashes: the water thrown up when something falls in, is pulled out or is hit
-- by a bullet. The wave simulation is a height field, which cannot leave the surface, so the
-- spray is drawn on its own, as real geometry in the water's own material: Remix refracts
-- and reflects through it as through the surface.
--
-- What real water does (Truscott, Epps & Belden, "Water entry of projectiles", Annual Review
-- of Fluid Mechanics 2014; Duez et al., "Making a splash with water repellency", Nature
-- Physics 2007; "Splash wave and crown breakup after disc impact on a liquid surface",
-- arXiv:1211.6641; Aristoff & Bush, "Water entry of small hydrophobic spheres", JFM 2009),
-- and how it is drawn here:
-- * A body going in throws a sheet up from its waterline, all along its outline: a crate's
--   sheet is square, a plank's runs along its sides, two legs throw two. The sheet is drawn
--   along the outline that W.Bodies.Footprint gives for the body, its corners rounded.
-- * A flat underside slams: the sheet leaves its edge fast (at first about 1.6 times the
--   impact speed) and low, a wide skirt of spray. A round or pointed one parts the water:
--   a slower, steeper crown. How flat the underside is: how much of its outline is in the
--   water within the first 3 units.
-- * The sheet's rim breaks into fingers and drops as it rises, and the rest of it breaks up
--   as it falls back. Rims break up from very low speeds on (a Weber number of about 140,
--   under half a metre a second for anything this size), and wood, plastic or skin splash
--   at any speed, so a splash fades in with speed instead of starting at a threshold: the
--   sheet's speed goes with the impact speed, its height with its square, and the amount
--   of water that flies with q^2 / (1 + q), q the impact speed over 300 units/s.
-- * A compact body going in fast (a high Froude number v^2 / g D) opens an air cavity that
--   closes, about 2 sqrt(D / g) later, into a jet (Worthington's); faster still, the crown
--   leans in and closes over the cavity (surface seal). Long or wide bodies make neither.
-- * Hit at a slant, the water ahead is thrown forward: on that side the sheet stands taller
--   and leans further out, and the spray goes ahead; a body's cavity runs down along its
--   path, so its jet leans back towards where it came from. A bullet's plume (and the
--   column of water at its root) is thrown ahead along the shot: straight up only from a
--   shot straight down, and the flatter the shot came in, the lower and further ahead.
-- Drops fall under the game's gravity with air drag; those that come down on the water make
-- rings of their own (R.Drop). A body pulled out lifts water that drains off its underside,
-- and drips. rtx_water_splash_randomness sets how much splashes vary (0: the same every
-- time). Drops and jets are static meshes drawn under their own transforms, so they cost no
-- vertex work in Lua; a sheet bends, rises and leans in ways no transform follows, so it is
-- built each frame while it stands (a few hundred vertices, SHEET_QUADS a frame at most).

local W = RTXWater
local S = W.Surface
local P = W.Splash or {}
W.Splash = P

local sqrt, min, max, floor, ceil, abs = math.sqrt, math.min, math.max, math.floor, math.ceil, math.abs
local cos, sin, atan2, random = math.cos, math.sin, math.atan2, math.random
local pi, TAU = math.pi, 2 * math.pi

local FAR = 3000          -- units from the camera beyond which pieces are not drawn
local DRAG = 0.0015       -- quadratic air drag of a drop, over its radius: fast spray slows down
local SHEET_MAX = 0.6     -- a sheet stays whole up to this many outline widths; above, it is spray
local SHEET_LEAN = 0.6    -- a sheet leans out at most this much per unit of height
local SHEET_STEP = 6      -- units between the points of a sheet along its outline
local SHEET_BREAK = 1.25  -- the sheet breaks up into drops this many rise times after the hit
local SHEET_QUADS = 2500  -- sheet quads drawn a frame at most (the nearest sheets first)
local FINGER = 10         -- units between the fingers of a sheet's rim
local MAX_CROWNS = 32
local MAX_JETS = 32
local MAX_SPRAY = 64      -- drops thrown at once by one outline
local JET_ROOT = 3        -- units of a jet below the surface, where the crater it rises from is
local DRIP_TIME = 3       -- s a body pulled out of the water drips for
local DRIP_HEIGHT = 300   -- units above the water past which a body no longer drips onto it
local SPRAY_LEAN = 1.2    -- at a grazing hit: spray thrown ahead, per unit of upward speed
local SLANT_SHEET = 0.5   -- ...the sheet that much taller on the side ahead (shorter behind)
local JET_LEAN = 0.7      -- ...a body's jet leaning back up its path, per unit of height
local BACK_SPRAY = 0.2    -- share of a bullet's spray thrown back up its path
local PLUME_RISE = 0.3    -- a bullet's plume rises this share of the way from its angle to vertical

-- (pieces from before a reload of this file may lack fields: start afresh)
P.drops, P.crowns, P.jets, P.wet = {}, {}, {}, {}
P.maxDrops = P.maxDrops or 200
P.strength = P.strength or 1
P.random = P.random or 0.5
local drops, crowns, jets = P.drops, P.crowns, P.jets

local gravity = GetConVar("sv_gravity")
local function grav() return gravity and gravity:GetFloat() or 600 end

local function rand(a, b) return a + (b - a) * random() end

-- Between a and b, as random as rtx_water_splash_randomness says: their middle at 0,
-- anywhere between them at 1.
local function vary(a, b) return (a + b) * 0.5 + (b - a) * 0.5 * P.random * (2 * random() - 1) end

-- A factor of 1 give or take spread (the same way).
local function jit(spread) return vary(1 - spread, 1 + spread) end
P.Jit = jit

-- n things on average: at no randomness, n rounded; otherwise rounded up or down at random,
-- so that small splashes fade in smoothly instead of all starting with one drop.
local function count(n)
	if P.random <= 0 then return floor(n + 0.5) end
	return floor(n * jit(0.3) + random())
end

local function smooth(x, a, b)
	local t = math.Clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

-- How much water a hit at `speed` throws: q^2 / (1 + q), q = speed / 300.
local function amount(speed)
	local q = speed / 300
	return q * q / (1 + q)
end
P.Amount = amount

---------------------------------------------------------------- the meshes

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

-- A closed surface of revolution about z, as triangles: profile = {rho, z, ...} runs from the
-- axis round to the axis, counter-clockwise in the (rho, z) half plane.
local function lathe(profile, seg)
	local np = #profile / 2
	local nr, nz = {}, {}
	for k = 1, np do
		local a, b = max(k - 1, 1), min(k + 1, np)
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
			row[k] = { r * c, r * s, z, nr[k] * c, nr[k] * s, nz[k], i / seg, z }
		end
		rows[i] = row
	end
	local out = {}
	for i = 0, seg - 1 do
		local A, B = rows[i], rows[i + 1]
		for k = 1, np - 1 do
			tri(out, A[k], B[k], B[k + 1])
			tri(out, A[k], B[k + 1], A[k + 1])
		end
	end
	return out
end

-- Unit sphere, from the bottom pole round to the top one.
local function sphere(rings)
	local p = {}
	for k = 0, rings do
		local a = pi * k / rings
		p[#p + 1] = sin(a)
		p[#p + 1] = -cos(a)
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

-- (the module's table outlives a reload of this file: meshes an older version built are
-- rebuilt when the version here changes)
local MESHES = 2

local function buildMeshes()
	P.dropMesh = build(lathe(sphere(7), 12))
	P.jetMesh = build(lathe(JET, 14))
	P.meshes = MESHES
end

---------------------------------------------------------------- settings

function P.Configure(s)
	P.enabled = s.splashes
	P.strength = s.splashStrength
	P.maxDrops = s.splashDrops
	P.random = s.splashRandom
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
-- was, h: 0 straight down, 1 grazing.
local function heading(dx, dy, dz)
	local hz = sqrt(dx * dx + dy * dy)
	local l = sqrt(hz * hz + dz * dz)
	if hz < 1e-3 or l < 1e-3 then return 1, 0, 0 end
	return dx / hz, dy / hz, hz / l
end

-- Points round an outline (counter-clockwise {x1, y1, ...}) about SHEET_STEP apart, each
-- with its outward normal; at each corner, a fan of points with the normals turning, so
-- that the sheet, set out along the normals, bends round the corner.
local function rim(poly)
	local n = #poly / 2
	local out = {}
	local function edge(i)
		local j = i % n + 1
		local ex, ey = poly[2 * j - 1] - poly[2 * i - 1], poly[2 * j] - poly[2 * i]
		local l = sqrt(ex * ex + ey * ey)
		return ex, ey, l, ey / max(l, 1e-6), -ex / max(l, 1e-6)
	end
	local _, _, _, pnx, pny = edge(n)
	for i = 1, n do
		local ax, ay = poly[2 * i - 1], poly[2 * i]
		local ex, ey, l, nx, ny = edge(i)
		local a0 = atan2(pny, pnx)
		local da = (atan2(ny, nx) - a0) % TAU
		if da > pi then da = 0 end
		local k = ceil(da / (pi / 6))
		for s = 0, k - 1 do
			local a = a0 + da * s / k
			out[#out + 1] = { ax, ay, cos(a), sin(a) }
		end
		local m = max(1, ceil(l / SHEET_STEP))
		for s = 0, m - 1 do out[#out + 1] = { ax + ex * s / m, ay + ey * s / m, nx, ny } end
		pnx, pny = nx, ny
	end
	return out
end

-- A point on an outline's perimeter, at a fraction f of the way round, and the outward
-- normal there.
local function alongOutline(poly, per, f)
	local n = #poly / 2
	local want, run = f * per, 0
	for i = 1, n do
		local j = i % n + 1
		local ax, ay = poly[2 * i - 1], poly[2 * i]
		local ex, ey = poly[2 * j - 1] - ax, poly[2 * j] - ay
		local l = sqrt(ex * ex + ey * ey)
		if run + l >= want or i == n then
			local t = l > 0 and math.Clamp((want - run) / l, 0, 1) or 0
			return ax + ex * t, ay + ey * t, ey / max(l, 1e-6), -ex / max(l, 1e-6)
		end
		run = run + l
	end
end

-- A sheet thrown up along an outline: rising at vz, its top going out at vout (per unit of
-- height, it leans out vout / vz), its rim breaking into `budget` drops as it rises. It
-- stays whole up to SHEET_MAX hydraulic diameters (4 area / perimeter) high.
-- (fx, fy, h): the way and slant of the hit; seal: how far it closes over a cavity.
local function addSheet(plane, o, vz, vout, fx, fy, h, seal, budget, dropR, thick)
	if #crowns >= MAX_CROWNS or vz <= 1 then return end
	local g = grav()
	local hmax = min(vz * vz / (2 * g), SHEET_MAX * 4 * o.area / max(o.perimeter, 1) + 2)
	if hmax < 0.4 then return end
	local pts = rim(o.poly)
	-- each point's share of the height: the rim's fingers, FINGER apart along the outline,
	-- and a height that wanders smoothly round the sheet (with randomness)
	local k, f1, f2, p1, p2 = {}, random(2, 3), random(4, 6), rand(0, TAU), rand(0, TAU)
	local nf = max(3, floor(o.perimeter / FINGER + 0.5))
	local amp, phase = 0.08 + 0.1 * P.random, P.random > 0 and random() or 0
	local s, px, py = 0, pts[1][1], pts[1][2]
	for j = 1, #pts do
		local p = pts[j]
		s = s + sqrt((p[1] - px) ^ 2 + (p[2] - py) ^ 2)
		px, py = p[1], p[2]
		local u = s / o.perimeter
		k[j] = (1 - amp * (0.5 - 0.5 * cos(TAU * (nf * u + phase))))
			* (1 + 0.2 * P.random * (0.6 * sin(TAU * f1 * u + p1) + 0.4 * sin(TAU * f2 * u + p2)))
	end
	crowns[#crowns + 1] = {
		plane = plane, z = plane.z, t0 = CurTime(), pts = pts, k = k,
		hmax = hmax, rise = 2 * hmax / vz, vz = vz, lean0 = min(0.5 * vout / vz, SHEET_LEAN),
		-- closing over the cavity: no further in than the sheet's middle
		seal = seal, inward = min(1, 0.8 * 2 * o.area / max(o.perimeter, 1) / hmax),
		gap = 0.6 + thick * 0.5, spread = 0.12 * vout, thick = thick,
		fx = fx, fy = fy, slant = h, budget = budget, rate = budget * vz / (2 * hmax), acc = 0, dropR = dropR,
	}
end

-- A jet rising from (x, y) after `delay`, leaning (lx, ly) per unit of height.
local function addJet(plane, x, y, lx, ly, delay, r, vj, tip)
	if #jets >= MAX_JETS or vj < 20 then return end
	jets[#jets + 1] = {
		plane = plane, x = x, y = y, z = plane.z, t0 = CurTime() + delay, r = r, vj = vj, tip = tip, lx = lx, ly = ly,
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

-- A random point inside an outline (or its middle, without randomness).
local function inside(o)
	if P.random <= 0 then return o.x, o.y end
	for _ = 1, 8 do
		local x, y = o.x + rand(-o.r, o.r), o.y + rand(-o.r, o.r)
		if S.inside(o.poly, x, y) then return x, y end
	end
	return o.x, o.y
end

-- A body hit the water, going down at `speed` (units/s) and across it at (vx, vy). outlines:
-- the plan of its part going in (W.Bodies.Footprint); flat: how flat its underside is (0 to
-- 1); share: how much of that is new (1 when it first hits the water). Each outline throws
-- a sheet and spray; a compact one hit hard enough makes a jet.
function P.Entry(plane, outlines, speed, vx, vy, flat, share)
	if not P.enabled or P.strength <= 0 or speed <= 0 then return end
	local s, g = P.strength, grav()
	local fx, fy, h = heading(vx or 0, vy or 0, -speed)
	local E = amount(speed) * s * (share or 1)
	-- a flat underside slams: faster, lower; a round one parts the water: slower, steeper
	local elev = 1.22 - 0.42 * flat
	local vs = min(speed * (0.5 + 0.7 * flat) * sqrt(s), 900)
	for _, o in ipairs(outlines) do
		-- its size as a sheet sees it: the hydraulic diameter, a beam's width rather than its length
		local D = 4 * o.area / max(o.perimeter, 1)
		local fr = speed * speed / (g * max(D, 1))
		local compact = smooth(o.area / (pi * o.r * o.r), 0.25, 0.6)
		local thick = math.Clamp(0.06 * sqrt(D), 0.2, 0.6)
		local dropR = math.Clamp(0.25 + 0.06 * sqrt(D), 0.25, 0.9)
		local e = elev + 0.12 * P.random * (2 * random() - 1)
		addSheet(plane, o, vs * sin(e), vs * cos(e), fx, fy, h,
			smooth(fr, 20, 80) * compact * (1 - 0.6 * flat), count(o.perimeter * 0.15 * E), dropR, thick)
		-- spray from all along the waterline, ahead of the hit at a slant
		local n = min(count(o.perimeter * 0.3 * E * (1 + flat)), MAX_SPRAY)
		local f0 = P.random > 0 and random() or 0
		for i = 1, n do
			local x, y, nx, ny = alongOutline(o.poly, o.perimeter, (f0 + (i - jit(0.5) * 0.5) / n) % 1)
			local ahead = nx * fx + ny * fy
			local sp = vs * jit(0.35) * (1 + 0.6 * h * ahead)
			local a = e + 0.25 * P.random * (2 * random() - 1)
			local out, up = sp * cos(a), sp * sin(a)
			addDrop(plane, x + nx, y + ny, plane.z + 0.5, nx * out + fx * SPRAY_LEAN * h * up,
				ny * out + fy * SPRAY_LEAN * h * up, up, dropR * jit(0.5))
		end
		-- the cavity of a compact body closes into a jet, about 2 sqrt(D / g) after the hit; the
		-- cavity runs along the body's path, so the jet leans back up it
		local jet = smooth(fr, 2, 12) * compact * smooth(D, 48, 24)
		if jet > 0.05 then
			addJet(plane, o.x, o.y, -fx * JET_LEAN * h, -fy * JET_LEAN * h, 2 * sqrt(D / g), math.Clamp(0.22 * D, 0.8, 4),
				min(0.45 * speed * sqrt(jet), 300) * sqrt(s) * jit(0.3), 4)
		end
	end
end

-- A body left the water going up at `speed` (units/s); outlines: the plan of its underside.
-- The water it lifts drains off it (more the faster it came out), and it drips for a while.
function P.Exit(plane, ent, outlines, speed)
	if not P.enabled or P.strength <= 0 then return end
	local E = amount(speed) * P.strength
	local vel = ent:GetVelocity()
	local re = 0
	for _, o in ipairs(outlines) do
		re = re + sqrt(o.area / pi)
		for _ = 1, min(count((o.perimeter * 0.15 + o.area * 0.02) * E), MAX_SPRAY) do
			local x, y = inside(o)
			addDrop(plane, x, y, plane.z + 0.5, vel.x * 0.5 + vary(-20, 20), vel.y * 0.5 + vary(-20, 20),
				speed * vary(0.1, 0.6), vary(0.35, 0.9))
		end
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
	-- the plume: straight up from a shot straight down, and the flatter the shot came in, the
	-- lower and further ahead along its path (pe, its angle from the water)
	local e = math.acos(math.Clamp(h, 0, 1))
	local pe = e + (pi / 2 - e) * PLUME_RISE
	local ce, se = cos(pe), sin(pe)
	-- two directions square to the plume, to spread the spray round it
	local ax, ay, az = -fy, fx, 0
	local bx, by, bz = -fx * se, -fy * se, ce
	local n = count((10 + 8 * power) * s)
	for i = 1, n do
		local sp, a, off = vary(150, 320) * p, TAU * (i + vary(-0.5, 0.5)) / n, vary(0.1, 0.45)
		local ux, uy, uz = fx * ce, fy * ce, se
		-- every fifth drop, or that share at random, goes back up the shot's path, steeply
		if P.random > 0 and random() < BACK_SPRAY or P.random <= 0 and i % 5 == 0 then
			local l = 1 / sqrt(1 + 0.35 * 0.35 * h * h)
			ux, uy, uz, sp = -fx * 0.35 * h * l, -fy * 0.35 * h * l, l, sp * 0.6
		end
		local co, so, ca, sa = cos(off), sin(off), cos(a), sin(a)
		local dx = ux * co + (ax * ca + bx * sa) * so
		local dy = uy * co + (ay * ca + by * sa) * so
		local dz = uz * co + (az * ca + bz * sa) * so
		addDrop(plane, x, y, plane.z + 0.3, dx * sp, dy * sp, dz * sp, vary(0.18, 0.4))
	end
	-- its column, leaning ahead with it (its tip breaks into drops)
	local lean = ce / max(se, 0.25)
	addJet(plane, x, y, fx * lean, fy * lean, 0.04, 1.0 * p, 110 * p * se * sqrt(s) * jit(0.3), 2)
	local r, poly = 1.2 * p, {}
	for i = 0, 9 do
		poly[#poly + 1] = x + r * cos(TAU * i / 10)
		poly[#poly + 1] = y + r * sin(TAU * i / 10)
	end
	addSheet(plane, { poly = poly, area = pi * r * r, perimeter = TAU * r, x = x, y = y, r = r },
		55 * p * sqrt(s), 15 * p, fx, fy, h, 0, 0, 0.25, 0.3)
end

---------------------------------------------------------------- per frame

-- Sheet c at its point j now: its foot (x, y), outward normal, height and lean (outward per
-- unit of height). Taller and leaning further on the side the hit went towards.
local function sheetAt(c, j)
	local p = c.pts[j]
	local nx, ny = p[3], p[4]
	local ahead = c.slant * (nx * c.fx + ny * c.fy)
	local d = c.offset
	return p[1] + nx * d, p[2] + ny * d, nx, ny, c.H * c.k[j] * (1 + SLANT_SHEET * ahead), c.lean + 0.6 * ahead
end

-- Moves everything on by the time since the last frame. Drops that come down on the water
-- make rings there.
function P.Think()
	local now = CurTime()
	local dt = now - (P.last or now)
	P.last = now
	if dt <= 0 then return end
	if dt > 0.1 then dt = 0.1 end
	local g = grav()
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
		local u = age / cr.rise
		-- rising, slowing to a stop at hmax; then falling back
		local vtop
		if u <= 1 then
			cr.H, vtop = cr.hmax * (1 - (1 - u) * (1 - u)), cr.vz * (1 - u)
		else
			local tf = age - cr.rise
			cr.H, vtop = cr.hmax - 0.5 * g * tf * tf, -g * tf
		end
		cr.offset = cr.gap + cr.spread * min(age, cr.rise)
		-- leaning out as it rises; sealing, it turns in over the cavity
		local seal = cr.seal * smooth(u, 0.6, 1.6)
		cr.lean = cr.lean0 * (1 - seal) - cr.inward * seal
		local function rimDrop(j, out, up, r)
			local x, y, nx, ny, hh, lean = sheetAt(cr, j)
			local lift = up > 0 and SPRAY_LEAN * cr.slant * up or 0
			addDrop(cr.plane, x + nx * lean * hh, y + ny * lean * hh, cr.z + hh,
				nx * out + cr.fx * lift, ny * out + cr.fy * lift, up, r)
		end
		if (u > 1 and cr.H <= 0.2) or u >= SHEET_BREAK then
			-- falling back, the rest of the sheet breaks up into drops along it
			if cr.H > 1 then
				for j = 1, #cr.pts, 2 do rimDrop(j, cr.spread * rand(0.5, 2), vtop * rand(0.7, 1), cr.dropR * jit(0.4)) end
			end
			table.remove(crowns, c)
		elseif vtop > 0 and cr.budget > 0 then
			-- while it rises, its rim breaks up into drops
			cr.acc = cr.acc + cr.rate * dt
			while cr.acc >= 1 and cr.budget > 0 do
				cr.acc, cr.budget = cr.acc - 1, cr.budget - 1
				rimDrop(random(1, #cr.pts), cr.vz * cr.lean0 * jit(0.35), vtop * jit(0.25), cr.dropR * jit(0.4))
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

local function vtx(x, y, z, nx, ny, nz, u, v)
	V:SetUnpacked(x, y, z)
	mesh.Position(V)
	NV:SetUnpacked(nx, ny, nz)
	mesh.Normal(NV)
	mesh.TexCoord(0, u, v)
	mesh.AdvanceVertex()
end

-- per point of a sheet: its foot, its rim, the way out through it and its outward normal
local FX, FY, TX, TY, TZ, OX, OY, NX, NY, NZ = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}

-- One sheet, built for this frame (its outline bends, rises and leans, which no transform of
-- a fixed mesh can follow): a closed shell along the outline, `thick` through, from a unit
-- under the surface up to its rim, leaning out. Faces are clockwise seen from outside the
-- shell, so rays enter the water through it and leave it again. Returns the quads drawn.
local function drawSheet(c)
	local n = #c.pts
	local t, z0 = c.thick * 0.5, c.z - 1
	for j = 1, n do
		local x, y, nx, ny, h, lean = sheetAt(c, j)
		local l = lean * h
		FX[j], FY[j] = x, y
		TX[j], TY[j], TZ[j] = x + nx * l, y + ny * l, z0 + h + 1
		OX[j], OY[j] = nx * t, ny * t
		local k = 1 / sqrt(1 + lean * lean)
		NX[j], NY[j], NZ[j] = nx * k, ny * k, -lean * k
	end
	mesh.Begin(MATERIAL_QUADS, n * 4)
	for j = 1, n do
		local q = j % n + 1
		local u0, u1 = (j - 1) / n, j / n
		local ax, ay, bx, by = OX[j], OY[j], OX[q], OY[q]
		local anx, any, anz, bnx, bny, bnz = NX[j], NY[j], NZ[j], NX[q], NY[q], NZ[q]
		-- outside: foot, rim, rim, foot (the points run counter-clockwise seen from above)
		vtx(FX[j] + ax, FY[j] + ay, z0, anx, any, anz, u0, 0)
		vtx(TX[j] + ax, TY[j] + ay, TZ[j], anx, any, anz, u0, 1)
		vtx(TX[q] + bx, TY[q] + by, TZ[q], bnx, bny, bnz, u1, 1)
		vtx(FX[q] + bx, FY[q] + by, z0, bnx, bny, bnz, u1, 0)
		-- inside
		vtx(FX[j] - ax, FY[j] - ay, z0, -anx, -any, -anz, u0, 0)
		vtx(FX[q] - bx, FY[q] - by, z0, -bnx, -bny, -bnz, u1, 0)
		vtx(TX[q] - bx, TY[q] - by, TZ[q], -bnx, -bny, -bnz, u1, 1)
		vtx(TX[j] - ax, TY[j] - ay, TZ[j], -anx, -any, -anz, u0, 1)
		-- over the rim
		vtx(TX[j] + ax, TY[j] + ay, TZ[j], 0, 0, 1, u0, 1)
		vtx(TX[j] - ax, TY[j] - ay, TZ[j], 0, 0, 1, u0, 1)
		vtx(TX[q] - bx, TY[q] - by, TZ[q], 0, 0, 1, u1, 1)
		vtx(TX[q] + bx, TY[q] + by, TZ[q], 0, 0, 1, u1, 1)
		-- under the foot
		vtx(FX[j] + ax, FY[j] + ay, z0, 0, 0, -1, u0, 0)
		vtx(FX[q] + bx, FY[q] + by, z0, 0, 0, -1, u1, 0)
		vtx(FX[q] - bx, FY[q] - by, z0, 0, 0, -1, u1, 0)
		vtx(FX[j] - ax, FY[j] - ay, z0, 0, 0, -1, u0, 0)
	end
	mesh.End()
	return n * 4
end

function P.Draw()
	if #drops == 0 and #crowns == 0 and #jets == 0 then return end
	if not P.mat then return end
	if P.meshes ~= MESHES then buildMeshes() end
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

	-- sheets, up to SHEET_QUADS a frame
	local quads = 0
	for _, c in ipairs(crowns) do
		if c.H and c.H > 0.2 and quads + 4 * #c.pts <= SHEET_QUADS then
			local p = c.pts[1]
			local dx, dy, dz = p[1] - ex, p[2] - ey, c.z - ez
			if dx * dx + dy * dy + dz * dz < far2 then quads = quads + drawSheet(c) end
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
