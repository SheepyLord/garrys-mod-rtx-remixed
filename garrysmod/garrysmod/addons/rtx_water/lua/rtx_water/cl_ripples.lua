-- RTX Water ripples. With the native core the waves are simulated there (a height field
-- with the dispersion of real water, pushed by the shapes of the bodies in it, see
-- cl_bodies.lua and source/rtx_water/wavesim.cpp); this file then only tracks which entities are
-- near water and turns impacts into impulses: bodies hitting the water (as hard as they hit
-- it) or leaving it, bullets (reported by the server, sv_bullets.lua) and splash drops coming
-- down. Without the core, ripples are rings that spread from players, NPCs, objects and
-- bullet impacts, as real geometry: the tiles they cross are tessellated and their vertices
-- lifted, so Remix refracts and reflects through the actual surface.
--
-- Every ripple vertex is Lua work here and hashing plus acceleration-structure
-- work in Remix, so the cost is kept down:
-- * Rebuilt at a fixed rate (rtx_water_interaction_rate, 30 Hz by default) into
--   cached meshes that are drawn every frame; frames in between cost nothing, and
--   Remix sees unchanged geometry on them.
-- * Only tiles near the camera, roughly in view and with visible ripples are
--   tessellated, most important first, within a vertex budget. The rest stays in
--   the static flat meshes.
-- * Cells wholly on the water form one stitched triangle strip (2 vertices a cell);
--   only cells on the water's edge are triangles.
-- * A ripple's shape and slope come from precomputed tables: per vertex and ripple
--   that is one square root and two table reads, no exp or trigonometry.

local W = RTXWater
local S = W.Surface
local R = W.Ripples or {}
W.Ripples = R

local T = S.TILE
local tileKey = S.tileKey
local floor, sqrt, exp, abs, max, min = math.floor, math.sqrt, math.exp, math.abs, math.max, math.min
local mesh_Begin, mesh_End = mesh.Begin, mesh.End
local mesh_Position, mesh_Normal, mesh_TexCoord, mesh_AdvanceVertex = mesh.Position, mesh.Normal, mesh.TexCoord, mesh.AdvanceVertex

---------------------------------------------------------------- ripple shape tables

-- A ripple is a ring-shaped wave packet: profile P(u) = w(u) cos(2 pi u + phase),
-- u = (distance - ring radius) / wavelength, with a compact window w over |u| < U.
-- D = dP/du. Four phases keep neighbouring ripples from looking stamped.
local U = 2.0
local NTAB = 1024
local TABSCALE = NTAB / (2 * U)
local TAB_OFF = U * TABSCALE + 1
local PTAB, DTAB = {}, {}
for ph = 1, 4 do
	local phi = (ph - 1) * math.pi * 0.5
	local P, Dd = { [0] = 0, [NTAB + 1] = 0 }, { [0] = 0, [NTAB + 1] = 0 }
	for i = 1, NTAB do
		local u = (i - 0.5) / TABSCALE - U
		local q = u / U
		local w = (1 - q * q) ^ 2
		local dw = -4 * q * (1 - q * q) / U
		local a = 2 * math.pi * u + phi
		P[i] = w * math.cos(a)
		Dd[i] = dw * math.cos(a) - 2 * math.pi * w * math.sin(a)
	end
	PTAB[ph], DTAB[ph] = P, Dd
end

---------------------------------------------------------------- settings

-- Cells per 64-unit tile side and vertex budget per update, by rtx_water_interaction_quality.
-- The native core draws its simulation's nodes (16 a tile side, every other one at low
-- detail and far away), and its vertices are cheap, so it gets a bigger budget.
local QUALITY = {
	[1] = { n = 4, budget = 12000 },
	[2] = { n = 8, budget = 22000 },
	[3] = { n = 16, budget = 36000 },
}
local QUALITY_NATIVE = {
	[1] = { n = 8, budget = 24000 },
	[2] = { n = 16, budget = 50000 },
	[3] = { n = 16, budget = 100000 },
}
local NEAR, FAR = 900, 2200  -- full detail within NEAR, half up to FAR, flat beyond
local AMP_MIN = 0.02         -- summed ripple height (units) below which a tile stays flat
local MAX_SOURCES = 96
local MAX_STRIP = 30000      -- vertices per mesh
local DAMPING = 0.35         -- 1/s: the core's damping (wavesim.h), over rtx_water_interaction_reach
local DROPS_PER_FRAME = 40   -- splash drops coming down that make rings, per frame at most

R.sources = R.sources or {}
R.tracked = R.tracked or {}
R.active = R.active or {}
R.meshes = R.meshes or {}
R.later = R.later or {}      -- impulses waiting for their time (cavities closing)
R.dropRings = 0
R.stats = { verts = 0, tiles = 0, ms = 0 }
local sources = R.sources

local rateCvar = CreateClientConVar("rtx_water_interaction_rate", "30",
	true, false, "Ripple geometry updates per second (0: every frame)", 0, 240)
cvars.AddChangeCallback("rtx_water_interaction_rate", function() R.rate = rateCvar:GetFloat() end, "RTXWater")
W.cv.rate = rateCvar

function R.Configure(s)
	if R.native and not s.native then R.Clear() end
	R.native = s.native
	R.enabled = s.interaction
	R.strength = s.interactionStrength
	R.reach = s.reach
	local q = s.native and QUALITY_NATIVE or QUALITY
	R.quality = q[s.quality] or q[2]
	-- shortest ripple the grid can carry: a bit over two cells per wavelength
	R.minLambda = 2.2 * T / R.quality.n
	R.bullets = s.bullets
	R.rate = rateCvar:GetFloat()
	R.nextUpdate = 0
	-- reach: waves lose their energy over 1 / damping seconds, so they travel that much
	-- further before they die out
	if s.native then RTXWaterNative.SetWaves({ strength = s.interactionStrength, damping = DAMPING / s.reach }) end
	if not R.enabled then R.Clear() end
end

-- Ripple sources (Lua) or bodies pushing the water (native core).
function R.Count()
	if R.native then return RTXWaterNative.Stats().bodies end
	return #sources
end

---------------------------------------------------------------- sources

-- amp: height in units; lambda: wavelength; speed: ring speed (units/s);
-- decay: amplitude e-folding time (s), times rtx_water_interaction_reach; delay: start later (s)
function R.Add(plane, x, y, amp, lambda, speed, decay, delay)
	-- the native core makes its waves from the bodies themselves
	if not R.enabled or R.native then return end
	amp = amp * (R.strength or 1)
	if amp < 0.01 then return end
	decay = decay * (R.reach or 1)
	if lambda < R.minLambda then
		-- keep the slope when a coarse grid stretches a short ripple
		amp = amp * R.minLambda / lambda
		lambda = R.minLambda
	end
	if #sources >= MAX_SOURCES then table.remove(sources, 1) end
	local ph = math.random(1, 4)
	sources[#sources + 1] = {
		plane = plane, x = x, y = y, t0 = CurTime() + (delay or 0), amp = amp,
		lambda = lambda, tabk = TABSCALE / lambda, speed = speed, decay = decay,
		life = decay * 3.2, P = PTAB[ph], D = DTAB[ph],
	}
end

function R.Clear()
	if R.native and RTXWaterNative then RTXWaterNative.ClearRipples() end
	for i = #sources, 1, -1 do sources[i] = nil end
	R.later = {}
	R.SetActive({})
	R.DestroyMeshes()
end

---------------------------------------------------------------- tile selection

local stamp = 0

function R.SetActive(list)
	stamp = stamp + 1
	for _, tile in ipairs(list) do tile.keep = stamp end
	for _, tile in ipairs(R.active) do
		if tile.keep ~= stamp then
			tile.active = false
			tile.block.active = tile.block.active - 1
			tile.block.partDirty = true
		end
	end
	for _, tile in ipairs(list) do
		if not tile.active then
			tile.active = true
			tile.block.active = tile.block.active + 1
			tile.block.partDirty = true
		end
	end
	R.active = list
end

local function liveSources(now)
	local i = 1
	while i <= #sources do
		local s = sources[i]
		local age = now - s.t0
		if age > s.life then
			table.remove(sources, i)
		else
			s.live = age >= 0
			if s.live then
				local r = s.speed * age
				-- geometric spreading taken at the ring, not per vertex
				s.R = r
				s.a = s.amp * exp(-age / s.decay) / sqrt(1 + r / 40)
				s.ga = s.a / s.lambda
				local hi, lo = r + U * s.lambda, r - U * s.lambda
				s.hi, s.hi2, s.lo2 = hi, hi * hi, lo > 0 and lo * lo or -1
			end
			i = i + 1
		end
	end
end

local function selectTiles(eye, fwd, cosView)
	stamp = stamp + 1
	local cand = {}
	for _, s in ipairs(sources) do
		if s.live and s.a >= AMP_MIN * 0.25 then
			local tiles = s.plane.tiles
			local hi = s.hi
			for gx = floor((s.x - hi) / T), floor((s.x + hi) / T) do
				local tx = gx * T
				local ddx = (s.x < tx) and (tx - s.x) or ((s.x > tx + T) and (s.x - tx - T) or 0)
				local fdx = max(abs(s.x - tx), abs(s.x - tx - T))
				for gy = floor((s.y - hi) / T), floor((s.y + hi) / T) do
					local tile = tiles[tileKey(gx, gy)]
					if tile then
						local ty = gy * T
						local ddy = (s.y < ty) and (ty - s.y) or ((s.y > ty + T) and (s.y - ty - T) or 0)
						local fdy = max(abs(s.y - ty), abs(s.y - ty - T))
						if ddx * ddx + ddy * ddy < s.hi2 and fdx * fdx + fdy * fdy > s.lo2 then
							if tile.mark ~= stamp then
								tile.mark = stamp
								tile.nsrc = 0
								tile.amp = 0
								tile.srcs = tile.srcs or {}
								cand[#cand + 1] = tile
							end
							tile.nsrc = tile.nsrc + 1
							tile.srcs[tile.nsrc] = s
							tile.amp = tile.amp + s.a
						end
					end
				end
			end
		end
	end
	-- keep tiles with visible ripples near the camera and roughly in view
	local keep = {}
	local ex, ey, ez = eye.x, eye.y, eye.z
	local fx, fy, fz = fwd.x, fwd.y, fwd.z
	for _, tile in ipairs(cand) do
		local thr = tile.active and AMP_MIN * 0.5 or AMP_MIN -- hysteresis
		if tile.amp >= thr then
			local dx, dy, dz = tile.x0 + T * 0.5 - ex, tile.y0 + T * 0.5 - ey, tile.plane.z - ez
			local d = sqrt(dx * dx + dy * dy + dz * dz)
			if d < FAR and (d < T * 2 or (dx * fx + dy * fy + dz * fz) > cosView * d) then
				tile.dist = d
				tile.score = tile.amp / (d + 150)
				keep[#keep + 1] = tile
			end
		end
	end
	table.sort(keep, function(a, b) return a.score > b.score end)
	local q = R.quality
	local used, list = 0, {}
	for _, tile in ipairs(keep) do
		local n = tile.dist < NEAR and q.n or max(2, q.n / 2)
		local c = S.TileCells(tile, n)
		local cost = c.verts + 2 * c.nsegs + 3 * c.ntris
		if used + cost <= q.budget then
			tile.n = n
			used = used + cost
			list[#list + 1] = tile
		end
	end
	return list
end

---------------------------------------------------------------- geometry

local H, NX, NY, NZ = {}, {}, {}, {}
local Vt, Nt = Vector(), Vector()

local function evalTile(tile, n)
	local cs = T / n
	local srcs, ns = tile.srcs, tile.nsrc
	local x0, y0 = tile.x0, tile.y0
	local idx = 0
	for j = 0, n do
		local y = y0 + j * cs
		for i = 0, n do
			local x = x0 + i * cs
			local h, gx, gy = 0, 0, 0
			for q = 1, ns do
				local s = srcs[q]
				local dx, dy = x - s.x, y - s.y
				local d2 = dx * dx + dy * dy
				if d2 < s.hi2 and d2 > s.lo2 then
					local d = sqrt(d2)
					local k = floor((d - s.R) * s.tabk + TAB_OFF)
					h = h + s.a * s.P[k]
					if d > 0.01 then
						local g = s.ga * s.D[k] / d
						gx = gx + g * dx
						gy = gy + g * dy
					end
				end
			end
			idx = idx + 1
			H[idx] = h
			local inv = 1 / sqrt(gx * gx + gy * gy + 1)
			NX[idx] = -gx * inv
			NY[idx] = -gy * inv
			NZ[idx] = inv
		end
	end
end

local function vert(x, y, z, nx, ny, nz, inv)
	Vt:SetUnpacked(x, y, z)
	mesh_Position(Vt)
	Nt:SetUnpacked(nx, ny, nz)
	mesh_Normal(Nt)
	mesh_TexCoord(0, x * inv, y * inv)
	mesh_AdvanceVertex()
end

-- Strip of all full cells of the given tiles, rows stitched by repeating a vertex
-- at each end (an even count each, so every triangle keeps the same winding).
local function emitStrip(m, tiles, nverts, inv)
	if m then mesh_Begin(m, MATERIAL_TRIANGLE_STRIP, nverts - 2) else mesh_Begin(MATERIAL_TRIANGLE_STRIP, nverts - 2) end
	local started = false
	local lx, ly, lz, lnx, lny, lnz
	for _, tile in ipairs(tiles) do
		local n = tile.n
		local c = S.TileCells(tile, n)
		evalTile(tile, n)
		local cs = T / n
		local x0, y0, z = tile.x0, tile.y0, tile.plane.z
		local row = n + 1
		local segs = c.segs
		for s = 1, #segs, 3 do
			local j, i0, i1 = segs[s], segs[s + 1], segs[s + 2]
			local ya, yb = y0 + j * cs, y0 + (j + 1) * cs
			local base = j * row + 1
			if started then
				vert(lx, ly, lz, lnx, lny, lnz, inv)
				local a = base + i0
				vert(x0 + i0 * cs, ya, z + H[a], NX[a], NY[a], NZ[a], inv)
			end
			for i = i0, i1 + 1 do
				local x = x0 + i * cs
				local a, b = base + i, base + row + i
				vert(x, ya, z + H[a], NX[a], NY[a], NZ[a], inv)
				vert(x, yb, z + H[b], NX[b], NY[b], NZ[b], inv)
			end
			local b = base + row + i1 + 1
			lx, ly, lz, lnx, lny, lnz = x0 + (i1 + 1) * cs, yb, z + H[b], NX[b], NY[b], NZ[b]
			started = true
		end
		if #c.partial > 0 then
			-- the edge cells are drawn afterwards from a copy of this tile's nodes
			local cnt = (n + 1) * (n + 1)
			local h2, x2, y2, z2 = tile.H or {}, tile.NX or {}, tile.NY or {}, tile.NZ or {}
			for k = 1, cnt do h2[k], x2[k], y2[k], z2[k] = H[k], NX[k], NY[k], NZ[k] end
			tile.H, tile.NX, tile.NY, tile.NZ = h2, x2, y2, z2
		end
	end
	mesh_End()
end

local function edgeVert(tile, n, cs, i, j, x, y, inv)
	local fx, fy = (x - tile.x0) / cs - i, (y - tile.y0) / cs - j
	fx = fx < 0 and 0 or (fx > 1 and 1 or fx)
	fy = fy < 0 and 0 or (fy > 1 and 1 or fy)
	local row = n + 1
	local a = j * row + i + 1
	local b, c, d = a + 1, a + row, a + row + 1
	local w00, w10, w01, w11 = (1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy
	local Hh, X, Y, Z = tile.H, tile.NX, tile.NY, tile.NZ
	local nx = X[a] * w00 + X[b] * w10 + X[c] * w01 + X[d] * w11
	local ny = Y[a] * w00 + Y[b] * w10 + Y[c] * w01 + Y[d] * w11
	local nz = Z[a] * w00 + Z[b] * w10 + Z[c] * w01 + Z[d] * w11
	local l = 1 / sqrt(nx * nx + ny * ny + nz * nz)
	vert(x, y, tile.plane.z + Hh[a] * w00 + Hh[b] * w10 + Hh[c] * w01 + Hh[d] * w11, nx * l, ny * l, nz * l, inv)
end

local function emitEdges(m, tiles, ntris, inv)
	if m then mesh_Begin(m, MATERIAL_TRIANGLES, ntris) else mesh_Begin(MATERIAL_TRIANGLES, ntris) end
	for _, tile in ipairs(tiles) do
		local n = tile.n
		local c = S.TileCells(tile, n)
		local cs = T / n
		for _, cell in ipairs(c.partial) do
			local i, j = cell.i, cell.j
			for _, p in ipairs(cell.polys) do
				local x1, y1 = p[1], p[2]
				for k = 3, #p - 3, 2 do
					edgeVert(tile, n, cs, i, j, x1, y1, inv)
					edgeVert(tile, n, cs, i, j, p[k + 2], p[k + 3], inv)
					edgeVert(tile, n, cs, i, j, p[k], p[k + 1], inv)
				end
			end
		end
	end
	mesh_End()
end

-- Emits the active tiles, into new IMeshes (cached mode) or straight to the
-- renderer (every-frame mode, meshes == nil). Returns the vertex count.
local function emitAll(meshes, inv)
	local total = 0
	-- strips, split so no mesh exceeds MAX_STRIP vertices
	local chunk, verts, segs = {}, 0, 0
	local edgeTiles, ntris = {}, 0
	local function flush()
		if segs == 0 then return end
		local nv = verts + 2 * (segs - 1)
		local m = meshes and Mesh(S.mat) or nil
		emitStrip(m, chunk, nv, inv)
		if m then meshes[#meshes + 1] = m end
		total = total + nv
		chunk, verts, segs = {}, 0, 0
	end
	for _, tile in ipairs(R.active) do
		local c = S.TileCells(tile, tile.n)
		if verts + c.verts + 2 * c.nsegs > MAX_STRIP then flush() end
		if c.nsegs > 0 then
			chunk[#chunk + 1] = tile
			verts = verts + c.verts
			segs = segs + c.nsegs
		elseif #c.partial > 0 then
			-- an edge-only tile still needs its nodes evaluated for the edge pass
			evalTile(tile, tile.n)
			local cnt = (tile.n + 1) * (tile.n + 1)
			tile.H, tile.NX, tile.NY, tile.NZ = {}, {}, {}, {}
			for k = 1, cnt do tile.H[k], tile.NX[k], tile.NY[k], tile.NZ[k] = H[k], NX[k], NY[k], NZ[k] end
		end
		if #c.partial > 0 then
			edgeTiles[#edgeTiles + 1] = tile
			ntris = ntris + c.ntris
		end
	end
	flush()
	if ntris > 0 then
		local m = meshes and Mesh(S.mat) or nil
		emitEdges(m, edgeTiles, ntris, inv)
		if m then meshes[#meshes + 1] = m end
		total = total + 3 * ntris
	end
	return total
end

function R.DestroyMeshes()
	for _, m in ipairs(R.meshes) do m:Destroy() end
	R.meshes = {}
end

---------------------------------------------------------------- per frame

local function viewCone()
	local vs = render.GetViewSetup and render.GetViewSetup() or nil
	local fov = vs and vs.fov or 90
	-- generous: the cached geometry has to cover small turns between updates
	return math.cos(math.rad(math.min(fov * 0.75 + 15, 89)))
end

-- Called once per frame before the static surface is drawn, so the set of tiles
-- that ripple never disagrees with what the static meshes leave out.
function R.Update()
	if not R.enabled then return end
	if not R.native and not S.built then return end
	local frame = FrameNumber()
	if R.frame == frame then return end
	R.frame = frame
	R.dropRings = 0
	R.Track()
	W.Splash.Think()
	if R.native then
		W.Bodies.Send()
		local now = CurTime()
		for i = #R.later, 1, -1 do
			local im = R.later[i]
			if now >= im.t then
				RTXWaterNative.AddImpulse(im.plane.index, im.x, im.y, im.depth, im.radius)
				table.remove(R.later, i)
			end
		end
	end
	local everyFrame = (R.rate or 0) <= 0
	local real = RealTime()
	if not everyFrame and real < (R.nextUpdate or 0) then return end
	R.nextUpdate = real + (everyFrame and 0 or 1 / R.rate)
	if R.native then
		local eye, fwd, q = EyePos(), EyeVector(), R.quality
		local verts, tiles, ms = RTXWaterNative.Update(CurTime(), eye.x, eye.y, eye.z, fwd.x, fwd.y, fwd.z, viewCone(),
			q.n, q.budget, NEAR, FAR)
		R.stats.verts, R.stats.tiles, R.stats.ms = verts, tiles, ms
		return
	end
	local t0 = SysTime()
	liveSources(CurTime())
	if #sources == 0 then
		if #R.active > 0 then R.SetActive({}) end
		R.DestroyMeshes()
		R.stats.verts, R.stats.tiles = 0, 0
		return
	end
	R.SetActive(selectTiles(EyePos(), EyeVector(), viewCone()))
	R.stats.tiles = #R.active
	if not everyFrame then
		local meshes = {}
		R.stats.verts = emitAll(meshes, 1 / S.repeatUnits)
		R.DestroyMeshes()
		R.meshes = meshes
	end
	R.stats.ms = (SysTime() - t0) * 1000
end

function R.Draw()
	if R.native or not R.enabled or #R.active == 0 then return end
	render.SetMaterial(S.mat)
	if (R.rate or 0) <= 0 then
		local t0 = SysTime()
		R.stats.verts = emitAll(nil, 1 / S.repeatUnits)
		R.stats.ms = (SysTime() - t0) * 1000
	else
		for _, m in ipairs(R.meshes) do m:Draw() end
	end
end

---------------------------------------------------------------- what makes ripples

-- Entities that can disturb the water are collected as they are created, so a scan never
-- walks every entity of the map. Those near water (tracked) are looked at on every scan,
-- the others a slice at a time, so each of them is still checked twice a second.
local SCAN = 0.05         -- seconds between scans
local NEAR_MARGIN = 400   -- units around a water plane's bounds that count as near
local FAR_SLICES = 10     -- scans over which the entities away from water are spread

R.candidates = R.candidates or {}

-- Can this kind of entity make ripples? (Whether it currently does is checked per scan.)
local function candidate(ent)
	if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:IsVehicle() or ent:IsScripted() then return true end
	local c = ent:GetClass()
	return c == "prop_physics" or c == "prop_physics_multiplayer" or c == "prop_ragdoll"
end

local function active(ent)
	if ent:IsDormant() then return false end
	if ent:IsPlayer() then return ent:Alive() and ent:GetObserverMode() == OBS_MODE_NONE end
	if ent:IsScripted() and not ent:IsNPC() and not ent:IsNextBot() and not ent:IsVehicle() then
		return ent:GetMoveType() == MOVETYPE_VPHYSICS
	end
	return true
end
R.Active = active

local function nearWater(pos)
	local x, y, z = pos.x, pos.y, pos.z
	for _, plane in ipairs(S.planes) do
		local b = plane.bounds
		if x > b[1] - NEAR_MARGIN and x < b[3] + NEAR_MARGIN and y > b[2] - NEAR_MARGIN and y < b[4] + NEAR_MARGIN
			and z > plane.z - NEAR_MARGIN and z < plane.z + NEAR_MARGIN then
			return true
		end
	end
	return false
end

local function splash(plane, x, y, vz, size)
	local a = math.Clamp(vz / 220, 0.15, 3.5) * sqrt(size)
	R.Add(plane, x, y, a * 1.3, 14 * size ^ 0.3, 36, 1.6)
	R.Add(plane, x, y, a, 10, 28, 1.8, 0.1)
	R.Add(plane, x, y, a * 0.5, 7, 20, 2.0, 0.25)
end

-- One look at an entity near the water: a wake while it moves, a ring now and then while it
-- stands. (Going in and coming out are R.Track's: it sees them on the frame they happen.)
local function visit(ent, now)
	local mins, maxs = ent:WorldSpaceAABB()
	local cx, cy = (mins.x + maxs.x) * 0.5, (mins.y + maxs.y) * 0.5
	local st = R.tracked[ent]
	if not st then
		st = { x = cx, y = cy, z = mins.z, t = now, nextWake = now, nextIdle = now + math.random() * 2 }
		R.tracked[ent] = st
	end
	local dt = max(now - st.t, 1e-3)
	local vx, vy = (cx - st.x) / dt, (cy - st.y) / dt
	local plane = S.PlaneAt(cx, cy, mins.z - 1, maxs.z + 1)
	local size = math.Clamp(max(maxs.x - mins.x, maxs.y - mins.y) / 32, 0.4, 4)
	if plane then
		local v = sqrt(vx * vx + vy * vy)
		if v > 6 and now >= st.nextWake then
			-- a little ahead of the body: its front pushes the water
			local lead = 0.25 * (maxs.x - mins.x) / max(v, 1)
			R.Add(plane, cx + vx * lead, cy + vy * lead, math.Clamp(v / 250, 0.08, 0.7) * sqrt(size), 9, 24, 1.3)
			st.nextWake = now + math.Clamp(0.16 - v / 3000, 0.05, 0.16)
		elseif v <= 6 and now >= st.nextIdle and (ent:IsPlayer() or ent:IsNPC()) then
			R.Add(plane, cx, cy, 0.08 * size, 7, 18, 1.2)
			st.nextIdle = now + 1.2 + math.random() * 1.6
		end
	elseif st.plane and maxs.z < st.plane.z then
		-- gone under: the water closes over it
		R.Add(st.plane, st.x, st.y, 0.15 * size, 9, 24, 1.2)
	end
	st.plane, st.size = plane, size
	st.x, st.y, st.z, st.t = cx, cy, mins.z, now
end

-- A new entity, or one that came into view: one near the water is watched from now on rather
-- than from its turn in the slices (a prop dropped in may be in the water by then).
local function consider(ent)
	if not IsValid(ent) or not candidate(ent) then return end
	R.candidates[ent] = true
	if not R.tracked[ent] and active(ent) and nearWater(ent:GetPos()) then visit(ent, CurTime()) end
end

function R.Scan()
	if not R.enabled or #S.planes == 0 then return end
	local now = CurTime()
	R.scanCount = (R.scanCount or 0) + 1
	local slice, i = R.scanCount % FAR_SLICES, 0
	for ent in pairs(R.candidates) do
		i = i + 1
		local st = R.tracked[ent]
		if not IsValid(ent) then
			R.candidates[ent], R.tracked[ent] = nil, nil
		elseif st or i % FAR_SLICES == slice then
			if active(ent) and nearWater(ent:GetPos()) then
				visit(ent, now)
			elseif st then
				if st.plane and active(ent) then R.Add(st.plane, st.x, st.y, 0.15 * st.size, 9, 24, 1.2) end
				R.tracked[ent] = nil
			end
		end
	end
	-- shapes for the core are made here, outside the frame (see cl_bodies.lua)
	if R.native then W.Bodies.Prepare() end
end

---------------------------------------------------------------- going in and coming out

-- Bodies crossing the surface are seen on the frame it happens (a scan comes every 50 ms, in
-- which a falling body crosses the surface and more), at the speed of their lowest point.
-- Going in, a body opens a cavity wider than itself, the wider and deeper the harder it hits;
-- it closes a moment later into waves that grow with the speed. (The core's push of the
-- body's shape alone makes the same waves however fast it comes in.) Coming out, it lifts
-- the water under it, which falls back. Both splash (cl_splash.lua).
local CROSS_SPEED = 40  -- units/s: slower crossings (wading in, bobbing) make neither
local CROSS_GAP = 0.3   -- s between two crossings of one body

-- Equivalent radius of a body's footprint; hitboxes fill their bounding box less.
local function footprint(ent, mins, maxs)
	local re = 0.5 * sqrt(max(maxs.x - mins.x, 1) * max(maxs.y - mins.y, 1))
	if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then re = re * 0.6 end
	return re
end

-- A body of equivalent radius re hit the water at (x, y), going down at `speed` (units/s) and
-- across it at (vx, vy).
function R.Entry(plane, x, y, speed, re, vx, vy)
	if R.native then
		-- the cavity: one step of pressure where it closes, a Gaussian sigma wide, along the
		-- body's path from where it went in when it went in at a slant
		local k = min(max(speed - 60, 0) / 300, 2.5) ^ 0.8
		if k > 0 then
			local sigma = re * (1 + sqrt(speed / 600)) + 4 * sqrt(speed / 300)
			local depth = min(0.3 * k * min(1, sqrt(16 / re)), 0.35) * sigma * (R.strength or 1)
			local shift = 0.5 * re / sqrt(vx * vx + vy * vy + speed * speed)
			R.later[#R.later + 1] = { t = CurTime() + math.Clamp(1.5 * re / speed + 0.05, 0.05, 0.3),
				plane = plane, x = x + vx * shift, y = y + vy * shift, depth = depth, radius = sigma }
		end
	else
		splash(plane, x, y, speed, math.Clamp(re / 16, 0.4, 4))
	end
	W.Splash.Entry(plane, x, y, speed, re, vx, vy)
end

-- A body left the water at (x, y) at `speed` (units/s, upwards).
function R.Exit(plane, ent, x, y, speed, re)
	local k = min(speed / 300, 2.5)
	if R.native then
		-- the water it lifts: a suction under it for one step
		local sigma = re * 1.2 + 2
		RTXWaterNative.AddImpulse(plane.index, x, y, -0.12 * k * sigma * (R.strength or 1), sigma)
	else
		R.Add(plane, x, y, (0.1 + 0.25 * k) * math.Clamp(re / 16, 0.4, 4), 9, 24, 1.2)
	end
	W.Splash.Exit(plane, ent, speed, re)
end

function R.Track()
	local now = CurTime()
	for ent, st in pairs(R.tracked) do
		if IsValid(ent) and active(ent) then
			local mins, maxs = ent:WorldSpaceAABB()
			local cx, cy = (mins.x + maxs.x) * 0.5, (mins.y + maxs.y) * 0.5
			local bottom, last = mins.z, st.fz
			st.fz = bottom
			-- velocity over 15 ms or more: some entities only move once a tick
			if not st.wt or now - st.wt >= 0.015 then
				if st.wt and st.wx then
					local inv = 1 / (now - st.wt)
					st.vx, st.vy, st.vz = (cx - st.wx) * inv, (cy - st.wy) * inv, (bottom - st.wz) * inv
				else
					st.vx, st.vy, st.vz = 0, 0, 0
				end
				st.wx, st.wy, st.wz, st.wt = cx, cy, bottom, now
			end
			if last and bottom ~= last and now >= (st.nextCross or 0) then
				local plane = S.PlaneAt(cx, cy, min(bottom, last), max(bottom, last))
				if plane then
					local vz = st.vz
					if last >= plane.z and bottom < plane.z and vz < -CROSS_SPEED then
						st.nextCross = now + CROSS_GAP
						R.Entry(plane, cx, cy, -vz, footprint(ent, mins, maxs), st.vx, st.vy)
					elseif last < plane.z and bottom >= plane.z and vz > CROSS_SPEED then
						st.nextCross = now + CROSS_GAP
						R.Exit(plane, ent, cx, cy, vz, footprint(ent, mins, maxs))
					end
				end
			end
		end
	end
end

-- A splash drop of radius r coming down on the water at `speed`.
function R.Drop(plane, x, y, r, speed)
	if not R.enabled or R.dropRings >= DROPS_PER_FRAME then return end
	R.dropRings = R.dropRings + 1
	local k = min(speed / 250, 2)
	if R.native then
		RTXWaterNative.AddImpulse(plane.index, x, y, 0.25 * r * k * (R.strength or 1), max(1.5, 2 * r))
	elseif r >= 0.4 and R.dropRings <= 4 then
		R.Add(plane, x, y, 0.08 * r * k, 5, 18, 0.6)
	end
end

---------------------------------------------------------------- bullets

-- A bullet went into the water at (x, y) of plane, along dir; power is 1 for a pistol round,
-- more for heavier ones. A pressure impulse, of which the simulation makes the crater and its
-- train of rings, and a spout of spray.
function R.Shot(plane, x, y, dir, power)
	if R.native then
		RTXWaterNative.AddImpulse(plane.index, x, y, 2.0 * (R.strength or 1) * power, 3.0 * sqrt(power))
	else
		R.Add(plane, x, y, 0.6 * power, 6, 28, 1.0)
		R.Add(plane, x, y, 0.3 * power, 10, 34, 1.2, 0.05)
	end
	W.Splash.Shot(plane, x, y, dir, power)
end

-- The server reports every shot that reaches the water (sv_bullets.lua).
net.Receive("rtx_water_shots", function()
	for _ = 1, net.ReadUInt(5) do
		local pos, dir, power = net.ReadVector(), net.ReadNormal(), net.ReadUInt(8) / 32
		if R.enabled and R.bullets then
			local plane = S.PlaneAt(pos.x, pos.y, pos.z - 4, pos.z + 4)
			if plane then R.Shot(plane, pos.x, pos.y, dir, power) end
		end
	end
end)

-- On a server without RTX Water, the shots this client predicts (its own, in multiplayer)
-- are all it sees.
local function onBullets(ent, data)
	if not (R.enabled and R.bullets) or not data.Src or not data.Dir then return end
	if util.NetworkStringToID("rtx_water_shots") ~= 0 or not IsFirstTimePredicted() then return end
	local dir = data.Dir:GetNormalized()
	local hit = S.RayHit(data.Src, dir, min(data.Distance or 32768, 32768))
	if not hit then return end
	-- only if the shot reaches the water before anything solid
	local tr = util.TraceLine({ start = data.Src, endpos = data.Src + dir * hit.t, mask = MASK_SHOT, filter = ent })
	if tr.Hit then return end
	R.Shot(hit.plane, hit.x, hit.y, dir, 1)
end

function R.Start()
	R.tracked, R.candidates = {}, {}
	for _, ent in ipairs(ents.GetAll()) do consider(ent) end
	-- an entity's class and type are settled a tick after it is created
	hook.Add("OnEntityCreated", "RTXWater_Candidates", function(ent)
		timer.Simple(0, function() consider(ent) end)
	end)
	hook.Add("EntityRemoved", "RTXWater_Candidates", function(ent)
		R.candidates[ent], R.tracked[ent] = nil, nil
	end)
	hook.Add("NotifyShouldTransmit", "RTXWater_Candidates", function(ent, transmit)
		if transmit then timer.Simple(0, function() consider(ent) end) end
	end)
	timer.Create("RTXWater_Scan", SCAN, 0, function()
		local t0 = SysTime()
		R.Scan()
		W.perf.scan = W.perf.scan * 0.95 + (SysTime() - t0) * 0.05
	end)
	hook.Add("EntityFireBullets", "RTXWater_Bullets", function(ent, data) onBullets(ent, data) end)
end

function R.Stop()
	timer.Remove("RTXWater_Scan")
	hook.Remove("OnEntityCreated", "RTXWater_Candidates")
	hook.Remove("EntityRemoved", "RTXWater_Candidates")
	hook.Remove("NotifyShouldTransmit", "RTXWater_Candidates")
	hook.Remove("EntityFireBullets", "RTXWater_Bullets")
	R.Clear()
	R.tracked, R.candidates = {}, {}
	if W.Bodies then W.Bodies.Reset() end
	if W.Splash then W.Splash.Clear() end
end
