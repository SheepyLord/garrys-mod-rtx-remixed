-- RTX Water surface: every world water face, cut into a grid of tiles and drawn as
-- this addon's own mesh. Calm tiles are flat and live in one static mesh per block;
-- tiles that carry ripples are tessellated each frame by cl_ripples.lua.
--
-- Polygons are flat arrays {x1, y1, x2, y2, ...}, counter-clockwise seen from above.
-- Source treats clockwise as the front, so triangles are emitted reversed: the
-- surface faces up, as the map's own water faces do, and Remix enters the water
-- volume through it.

local W = RTXWater
local S = W.Surface or {}
W.Surface = S

S.TILE = 64    -- units
S.BLOCK = 16   -- tiles per block side
S.planes = S.planes or {}
S.worldMaterials = S.worldMaterials or {}
S.entityMaterials = S.entityMaterials or {}

local T = S.TILE
local floor, huge = math.floor, math.huge
local UP = Vector(0, 0, 1)
local V = Vector()

local function tileKey(gx, gy) return (gx + 32768) * 65536 + (gy + 32768) end
S.tileKey = tileKey

local function area(p)
	local n = #p
	local a, px, py = 0, p[n - 1], p[n]
	for k = 1, n, 2 do
		local qx, qy = p[k], p[k + 1]
		a = a + px * qy - qx * py
		px, py = qx, qy
	end
	return a * 0.5
end
S.area = area

-- Sutherland-Hodgman: subject clipped by a convex counter-clockwise polygon
local function clip(subject, poly)
	local out = subject
	local n = #poly
	for i = 1, n, 2 do
		local j = (i + 2 > n) and 1 or i + 2
		local ax, ay = poly[i], poly[i + 1]
		local ex, ey = poly[j] - ax, poly[j + 1] - ay
		local inp = out
		local m = #inp
		if m == 0 then return inp end
		out = {}
		local px, py = inp[m - 1], inp[m]
		local dp = ex * (py - ay) - ey * (px - ax)
		for k = 1, m, 2 do
			local qx, qy = inp[k], inp[k + 1]
			local dq = ex * (qy - ay) - ey * (qx - ax)
			if (dq >= -1e-6) ~= (dp >= -1e-6) then
				local t = dp / (dp - dq)
				out[#out + 1] = px + (qx - px) * t
				out[#out + 1] = py + (qy - py) * t
			end
			if dq >= -1e-6 then
				out[#out + 1] = qx
				out[#out + 1] = qy
			end
			px, py, dp = qx, qy, dq
		end
	end
	return out
end
S.clip = clip

local function inside(p, x, y)
	local n = #p
	local px, py = p[n - 1], p[n]
	for k = 1, n, 2 do
		local qx, qy = p[k], p[k + 1]
		if (qx - px) * (y - py) - (qy - py) * (x - px) < -1e-6 then return false end
		px, py = qx, qy
	end
	return true
end
S.inside = inside

---------------------------------------------------------------- discovery

local function addPolygon(byZ, verts)
	local flat, zsum, zmin, zmax = {}, 0, huge, -huge
	for _, v in ipairs(verts) do
		flat[#flat + 1] = v.x
		flat[#flat + 1] = v.y
		zsum = zsum + v.z
		if v.z < zmin then zmin = v.z end
		if v.z > zmax then zmax = v.z end
	end
	if #verts < 3 or zmax - zmin > 0.5 then return false end -- horizontal only
	-- clockwise from above is the top of the water; its underside is wound the other way
	if area(flat) > -1 then return false end
	local ccw = {}
	for k = #flat - 1, 1, -2 do
		ccw[#ccw + 1] = flat[k]
		ccw[#ccw + 1] = flat[k + 1]
	end
	local z = zsum / #verts
	local kz = floor(z * 4 + 0.5)
	local plane = byZ[kz]
	if not plane then
		plane = { z = z, polys = {}, tiles = {}, blocks = {} }
		byZ[kz] = plane
	end
	plane.polys[#plane.polys + 1] = ccw
	return true
end

local function buildTiles(plane)
	local B = S.BLOCK
	local count = 0
	for _, poly in ipairs(plane.polys) do
		local x0, y0, x1, y1 = huge, huge, -huge, -huge
		for k = 1, #poly, 2 do
			x0, x1 = math.min(x0, poly[k]), math.max(x1, poly[k])
			y0, y1 = math.min(y0, poly[k + 1]), math.max(y1, poly[k + 1])
		end
		for gx = floor(x0 / T), floor((x1 - 1e-4) / T) do
			for gy = floor(y0 / T), floor((y1 - 1e-4) / T) do
				local tx, ty = gx * T, gy * T
				local piece = clip({ tx, ty, tx + T, ty, tx + T, ty + T, tx, ty + T }, poly)
				if #piece >= 6 and area(piece) > 0.05 then
					local k = tileKey(gx, gy)
					local tile = plane.tiles[k]
					if not tile then
						local bk = tileKey(floor(gx / B), floor(gy / B))
						local block = plane.blocks[bk]
						if not block then
							block = { tiles = {}, active = 0 }
							plane.blocks[bk] = block
						end
						tile = { gx = gx, gy = gy, x0 = tx, y0 = ty, pieces = {}, plane = plane, block = block, active = false }
						plane.tiles[k] = tile
						block.tiles[#block.tiles + 1] = tile
						count = count + 1
					end
					tile.pieces[#tile.pieces + 1] = piece
				end
			end
		end
	end
	for _, tile in pairs(plane.tiles) do
		tile.full = #tile.pieces == 1 and area(tile.pieces[1]) >= T * T - 0.5
	end
	return count
end

function S.Discover()
	S.Destroy()
	S.planes, S.worldMaterials, S.entityMaterials = {}, {}, {}
	local byZ, faces = {}, 0
	-- (IsValid is false for the world entity, so test it directly)
	local world = game.GetWorld()
	for _, surf in ipairs(world and world:GetBrushSurfaces() or {}) do
		if surf:IsWater() then
			local mat = surf:GetMaterial()
			if mat and not mat:IsError() then
				S.worldMaterials[mat:GetName()] = true
				if addPolygon(byZ, surf:GetVertices()) then faces = faces + 1 end
			end
		end
	end
	-- underside materials are hidden with the top ones
	for name in pairs(table.Copy(S.worldMaterials)) do
		local b = Material(name):GetString("$bottommaterial")
		if b and b ~= "" then S.worldMaterials[string.lower(b)] = true end
	end
	-- water on brush entities (func_water_analog...) keeps the map's faces, with our material
	for _, ent in ipairs(ents.GetAll()) do
		if IsValid(ent) and ent:GetBrushPlaneCount() > 0 then
			local ok, surfs = pcall(ent.GetBrushSurfaces, ent)
			for _, surf in ipairs(ok and surfs or {}) do
				local mat = surf:IsWater() and surf:GetMaterial()
				if mat and not mat:IsError() and not S.worldMaterials[mat:GetName()] then
					S.entityMaterials[mat:GetName()] = true
				end
			end
		end
	end
	local tiles = 0
	for _, plane in pairs(byZ) do
		tiles = tiles + buildTiles(plane)
		local x0, y0, x1, y1 = huge, huge, -huge, -huge
		for _, poly in ipairs(plane.polys) do
			for k = 1, #poly, 2 do
				x0, x1 = math.min(x0, poly[k]), math.max(x1, poly[k])
				y0, y1 = math.min(y0, poly[k + 1]), math.max(y1, poly[k + 1])
			end
		end
		plane.bounds = { x0, y0, x1, y1 }
		S.planes[#S.planes + 1] = plane
	end
	table.sort(S.planes, function(a, b) return a.z < b.z end)
	return { faces = faces, planes = #S.planes, tiles = tiles }
end

---------------------------------------------------------------- queries

local function tileContains(tile, x, y)
	if tile.full then return true end
	for _, p in ipairs(tile.pieces) do
		if inside(p, x, y) then return true end
	end
	return false
end

-- The water plane under (x, y) whose height lies within [zlo, zhi], if any.
function S.PlaneAt(x, y, zlo, zhi)
	for _, plane in ipairs(S.planes) do
		if plane.z >= zlo and plane.z <= zhi then
			local tile = plane.tiles[tileKey(floor(x / T), floor(y / T))]
			if tile and tileContains(tile, x, y) then return plane end
		end
	end
end

-- First water surface along a ray: {t, plane, x, y}
function S.RayHit(start, dir, maxDist)
	local best
	if math.abs(dir.z) < 1e-4 then return nil end
	for _, plane in ipairs(S.planes) do
		local t = (plane.z - start.z) / dir.z
		if t > 0 and t < maxDist and (not best or t < best.t) then
			local x, y = start.x + dir.x * t, start.y + dir.y * t
			local tile = plane.tiles[tileKey(floor(x / T), floor(y / T))]
			if tile and tileContains(tile, x, y) then best = { t = t, plane = plane, x = x, y = y } end
		end
	end
	return best
end

-- Cell layout of a tile at n x n cells, cached per tile and n:
--   segs     flat list {j, i0, i1, ...}: runs of cells wholly on the water, drawn as
--            triangle-strip rows (2 vertices per cell)
--   verts    strip vertices of all runs, without the stitches between them
--   partial  cells crossing the water's edge: {i, j, polys}, drawn as triangles
function S.TileCells(tile, n)
	tile.cells = tile.cells or {}
	local c = tile.cells[n]
	if c then return c end
	c = { segs = {}, nsegs = 0, verts = 0, partial = {}, ntris = 0 }
	local cs = T / n
	local segs = c.segs
	for j = 0, n - 1 do
		local run = nil
		for i = 0, n do
			local whole = false
			if i < n then
				local x0, y0 = tile.x0 + i * cs, tile.y0 + j * cs
				whole = tile.full
				if not whole then
					for _, p in ipairs(tile.pieces) do
						if inside(p, x0, y0) and inside(p, x0 + cs, y0) and inside(p, x0 + cs, y0 + cs) and inside(p, x0, y0 + cs) then
							whole = true
							break
						end
					end
				end
				if not whole then
					local polys = {}
					local sq = { x0, y0, x0 + cs, y0, x0 + cs, y0 + cs, x0, y0 + cs }
					for _, p in ipairs(tile.pieces) do
						local q = clip(sq, p)
						if #q >= 6 and area(q) > 0.01 then
							polys[#polys + 1] = q
							c.ntris = c.ntris + #q / 2 - 2
						end
					end
					if #polys > 0 then c.partial[#c.partial + 1] = { i = i, j = j, polys = polys } end
				end
			end
			if whole and not run then
				run = i
			elseif not whole and run then
				segs[#segs + 1] = j
				segs[#segs + 1] = run
				segs[#segs + 1] = i - 1
				c.nsegs = c.nsegs + 1
				c.verts = c.verts + 2 * (i - run + 1)
				run = nil
			end
		end
	end
	tile.cells[n] = c
	return c
end

---------------------------------------------------------------- drawing

function S.SetTag(texture)
	if not S.mat then
		S.mat = CreateMaterial("RTXWater_Surface", "UnlitGeneric", { ["$basetexture"] = texture, ["$nocull"] = 1 })
	end
	local t = S.mat:GetTexture("$basetexture")
	if not t or t:GetName() ~= texture then S.mat:SetTexture("$basetexture", texture) end
end

local function vert(x, y, z, inv)
	V:SetUnpacked(x, y, z)
	mesh.Position(V)
	mesh.Normal(UP)
	mesh.TexCoord(0, x * inv, y * inv)
	mesh.Color(255, 255, 255, 255)
	mesh.AdvanceVertex()
end

local function emitPiece(p, z, inv)
	local x1, y1 = p[1], p[2]
	for k = 3, #p - 3, 2 do
		vert(x1, y1, z, inv)
		vert(p[k + 2], p[k + 3], z, inv)
		vert(p[k], p[k + 1], z, inv)
	end
end

local function countTris(tiles, activeOnly)
	local n = 0
	for _, tile in ipairs(tiles) do
		if not (activeOnly and tile.active) then
			for _, p in ipairs(tile.pieces) do n = n + #p / 2 - 2 end
		end
	end
	return n
end

local function buildBlockMesh(block, z, inv, skipActive)
	local ntris = countTris(block.tiles, skipActive)
	if ntris == 0 then return nil end
	local m = Mesh(S.mat)
	mesh.Begin(m, MATERIAL_TRIANGLES, ntris)
	for _, tile in ipairs(block.tiles) do
		if not (skipActive and tile.active) then
			for _, p in ipairs(tile.pieces) do emitPiece(p, z, inv) end
		end
	end
	mesh.End()
	return m
end

-- One static mesh per block with all of its tiles flat. While some of a block's
-- tiles ripple, a second mesh holds the rest; cl_ripples.lua marks it dirty when
-- that set changes, so calm water costs no per-frame vertex work.
function S.Build(repeatUnits)
	S.Destroy()
	S.repeatUnits = repeatUnits
	local inv = 1 / repeatUnits
	S.blockList = {}
	for _, plane in ipairs(S.planes) do
		for _, block in pairs(plane.blocks) do
			block.z = plane.z
			block.mesh = buildBlockMesh(block, plane.z, inv, false)
			block.partDirty = true
			S.blockList[#S.blockList + 1] = block
		end
	end
	S.built = true
end

function S.Destroy()
	for _, plane in ipairs(S.planes or {}) do
		for _, block in pairs(plane.blocks) do
			if block.mesh then block.mesh:Destroy() block.mesh = nil end
			if block.partMesh then block.partMesh:Destroy() block.partMesh = nil end
		end
	end
	S.blockList = {}
	S.built = false
end

function S.Draw()
	if not S.built then return end
	render.SetMaterial(S.mat)
	local inv = 1 / S.repeatUnits
	for _, block in ipairs(S.blockList) do
		if block.active == 0 then
			if block.mesh then block.mesh:Draw() end
		else
			if block.partDirty then
				if block.partMesh then block.partMesh:Destroy() end
				block.partMesh = buildBlockMesh(block, block.z, inv, true)
				block.partDirty = false
			end
			if block.partMesh then block.partMesh:Draw() end
		end
	end
end
