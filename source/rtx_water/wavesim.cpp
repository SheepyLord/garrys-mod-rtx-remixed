// RTX Water wave simulation (see wavesim.h).

#include "wavesim.h"

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <immintrin.h>
#include <intrin.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <unordered_map>

namespace wave {
namespace {

// Radial taps of the vertical-derivative kernel, per unit, for kCell = 4, kR = 6 and
// kSpring = 10 (tools/fit_wave_kernel.py). Tap (a, b) applies to the offsets (+-a, +-b) and
// (+-b, +-a). As stepped, against deep water, phase speeds are within 1.2 % from 12 to 64
// units of wavelength and 4 % from 96 to 192 (13 % fast at 256); the shortest waves (two
// cells) are damped by the grid. g R + kSpring is never below 9 / s^2, so the steps are
// stable, and Kelvin wakes keep close to their 19.5 degrees.
struct KernelTap {
	int a, b;
	float w;
};
constexpr KernelTap kKernel[] = {
	{ 0, 0, +3.371498938e-01f },
	{ 1, 0, +2.463361640e-02f },
	{ 1, 1, -6.355932578e-02f },
	{ 2, 0, -4.459326454e-02f },
	{ 2, 1, -8.016419700e-03f },
	{ 2, 2, +1.840441140e-02f },
	{ 3, 0, +1.887157855e-02f },
	{ 3, 1, +1.007970414e-02f },
	{ 3, 2, -9.222485794e-03f },
	{ 3, 3, -3.565634468e-03f },
	{ 4, 0, -1.184604843e-02f },
	{ 4, 1, -8.543691906e-03f },
	{ 4, 2, +6.841157714e-04f },
	{ 4, 3, +3.398630006e-03f },
	{ 4, 4, -1.014706925e-03f },
	{ 5, 0, +5.429091629e-03f },
	{ 5, 1, +4.107296524e-03f },
	{ 5, 2, +6.387001358e-04f },
	{ 5, 3, -1.682754653e-03f },
	{ 5, 4, -7.988129631e-04f },
	{ 6, 0, -2.425486382e-03f },
	{ 6, 1, -1.902414310e-03f },
	{ 6, 2, -1.052706438e-03f },
};

struct Offset {
	int dx, dy;
	float w;
};

std::vector<Offset> expandKernel() {
	std::vector<Offset> out;
	for (const KernelTap& t : kKernel) {
		const int pts[8][2] = { { t.a, t.b }, { -t.a, t.b }, { t.a, -t.b }, { -t.a, -t.b },
		                        { t.b, t.a }, { -t.b, t.a }, { t.b, -t.a }, { -t.b, -t.a } };
		for (int i = 0; i < 8; ++i) {
			bool seen = false;
			for (int j = 0; j < i; ++j) seen |= pts[j][0] == pts[i][0] && pts[j][1] == pts[i][1];
			if (!seen) out.push_back({ pts[i][0], pts[i][1], t.w });
		}
	}
	return out;
}

constexpr int kPad = kN + 2 * kR;      // a tile and the margin its kernel reads
constexpr float kSpring = 10.0f;       // 1/s^2: pulls the free surface back to rest (see the step)
constexpr float kFadeTau = 0.3f;       // s: the push of a body that has gone (removed, out of reach) fades
constexpr float kQuietAmp = 0.01f;     // units: a tile lower than this (half the least drawn)...
constexpr float kQuietRate = 0.004f;   // ...changing less than this a step...
constexpr int kQuietSteps = 90;        // ...for this many steps stops being simulated
constexpr float kSpread = 0.008f;      // waves this high near a side wake the tile beyond it
constexpr float kSub = kCell * 0.5f;   // bodies are rasterised at 2 x 2 samples a cell
constexpr float kDeepFade = 16.0f;     // a part wholly under water pushes less: exp(-depth / this)
constexpr int kMaxBodyCells = 128;     // body footprints larger than this many cells a side are skipped
constexpr int kHistory = 8;            // body samples kept for interpolation
constexpr int kMaxSteps = 6;           // steps an advance takes at most (keeps real time down to 10 fps)
constexpr float kBreakSlope = 0.45f;   // free-surface slope above which waves break
constexpr float kViscosity = 0.04f;    // damping of the surface velocity's curvature (short waves die first)
constexpr float kBreakRate = 0.5f;     // how much of the excess a step takes out
constexpr float kImpulseHead = 30.0f;  // head of an impulse for its one step, per unit of depth

int64_t key3(int a, int b, int c) {
	return (static_cast<int64_t>(a) << 48) ^ (static_cast<int64_t>(static_cast<uint32_t>(b) & 0xFFFFFFu) << 24) ^
	       static_cast<int64_t>(static_cast<uint32_t>(c) & 0xFFFFFFu);
}

int floorDiv(int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); }

// AVX2 and FMA, and an OS that saves the YMM registers.
bool hasAvx2() {
	int r[4];
	__cpuid(r, 0);
	if (r[0] < 7) return false;
	__cpuid(r, 1);
	const bool fma = (r[2] >> 12) & 1, osxsave = (r[2] >> 27) & 1, avx = (r[2] >> 28) & 1;
	if (!fma || !osxsave || !avx || (_xgetbv(0) & 6) != 6) return false;
	__cpuidex(r, 7, 0);
	return (r[1] >> 5) & 1;
}
const bool kAvx2 = hasAvx2();

// The kernel over one tile: vd = K * pad, eight cells a lane, four rows at a time so
// enough multiply-adds are in flight.
void convolveAvx2(const float* pad, const Offset* k, size_t nk, float* vd) {
	for (int y = 0; y < kN; y += 4) {
		__m256 a[8];
		for (__m256& v : a) v = _mm256_setzero_ps();
		for (size_t i = 0; i < nk; ++i) {
			const float* s = pad + (y + kR + k[i].dy) * kPad + kR + k[i].dx;
			const __m256 w = _mm256_set1_ps(k[i].w);
			for (int r = 0; r < 4; ++r) {
				a[2 * r] = _mm256_fmadd_ps(w, _mm256_loadu_ps(s + r * kPad), a[2 * r]);
				a[2 * r + 1] = _mm256_fmadd_ps(w, _mm256_loadu_ps(s + r * kPad + 8), a[2 * r + 1]);
			}
		}
		for (int r = 0; r < 4; ++r) {
			_mm256_storeu_ps(vd + (y + r) * kN, a[2 * r]);
			_mm256_storeu_ps(vd + (y + r) * kN + 8, a[2 * r + 1]);
		}
	}
	_mm256_zeroupper();
}

}  // namespace

struct Sim::Impl {
	explicit Impl(Settings& s) : settings(s) {}

	Settings& settings;
	std::vector<float> planeZ;

	struct Tile {
		int plane = 0, gx = 0, gy = 0;
		int nb[9];                       // the 3 x 3 tiles around it, (dy + 1) * 3 + dx + 1; -1: none
		float water[kN * kN];
		int slot = -1;                   // its simulation state, or -1
		// Walls: each dry position of the kernel's pad (land, or no tile at all) that the
		// kernel reads takes the height of its mirror image in the water, so the edge
		// reflects waves the way a vertical wall does (no flow through it, the surface free
		// to rise and fall against it). ghostOf: pad position -> mirror pad position, or -1;
		// empty for tiles with water all around.
		std::vector<int16_t> ghostOf;
		std::vector<std::pair<int16_t, int16_t>> ghosts;
	};
	std::vector<Tile> tiles;
	std::unordered_map<int64_t, int> tileAt;

	struct Slot {
		int tile = -1;
		alignas(16) float h[kN * kN];    // the simulated surface
		alignas(16) float hp[kN * kN];   // ...a step ago
		alignas(16) float vd[kN * kN];
		alignas(16) float brk[kN * kN];
		alignas(16) float visc[kN * kN];
		alignas(16) float head[kN * kN]; // what bodies push with this step
		alignas(16) float dip[kN * kN];  // drawn = h - dip: bodies' dips pulled inside their waterlines
		bool hasHead = false;
		float amp = 0;                   // largest drawn |h - dip|
		float edge[9] = {};              // largest |h| within kR of each neighbour, by neighbour index
		int quiet = 0;
	};
	std::vector<std::unique_ptr<Slot>> slots;
	std::vector<int> freeSlots;
	std::vector<int> active;            // simulated tiles
	std::vector<int> wake;              // tiles to simulate from the next step on

	struct Part {
		std::vector<float> v;           // triangle soup
	};
	std::unordered_map<int, std::vector<Part>> shapes;
	struct Sample {
		double t = 0;
		std::vector<Mat34> m;
	};
	// A body's push on one cell: the slow (resting) part of what is under water, what
	// pierces the surface, and the dip drawn there.
	struct Slow {
		float s, p, e;
		int plane, cx, cy, stamp;
	};
	struct Body {
		int shape = 0;
		std::deque<Sample> samples;
		bool present = false;
		std::unordered_map<int64_t, Slow> slow;
	};
	std::unordered_map<int, Body> bodies;
	struct Impulse {
		int plane;
		float x, y, depth, radius;
	};
	std::vector<Impulse> impulses;

	std::vector<Offset> kernel = expandKernel();
	double simTime = -1;
	int stamp = 0;
	Stats stats;

	// scratch
	std::vector<Mat34> mats;
	std::vector<float> world, zlo, zhi, subP, subS, cellP, cellS, cellE, tmp;
	alignas(16) float pad[kPad * kPad];   // h + head of a tile and its kernel margin
	alignas(16) float vpad[kPad * kPad];  // h - h_prev (the surface velocity) of the same

	// ------------------------------------------------------------ tiles

	Slot* slotOf(int tile) { return tiles[tile].slot >= 0 ? slots[tiles[tile].slot].get() : nullptr; }
	const Slot* slotOf(int tile) const { return tiles[tile].slot >= 0 ? slots[tiles[tile].slot].get() : nullptr; }

	Slot* activate(int tile) {
		Tile& t = tiles[tile];
		if (t.slot >= 0) return slots[t.slot].get();
		if (static_cast<int>(active.size()) >= settings.maxTiles) return nullptr;
		int s;
		if (!freeSlots.empty()) {
			s = freeSlots.back();
			freeSlots.pop_back();
		} else {
			s = static_cast<int>(slots.size());
			slots.push_back(std::make_unique<Slot>());
		}
		Slot& S = *slots[s];
		std::memset(S.h, 0, sizeof S.h);
		std::memset(S.hp, 0, sizeof S.hp);
		std::memset(S.head, 0, sizeof S.head);
		std::memset(S.dip, 0, sizeof S.dip);
		S.tile = tile;
		S.hasHead = false;
		S.amp = 0;
		S.quiet = 0;
		std::fill(std::begin(S.edge), std::end(S.edge), 0.0f);
		t.slot = s;
		active.push_back(tile);
		return &S;
	}

	void release(int tile) {
		Tile& t = tiles[tile];
		if (t.slot < 0) return;
		freeSlots.push_back(t.slot);
		t.slot = -1;
	}

	int tileOf(int plane, int cx, int cy, int& lx, int& ly) const {
		int gx = floorDiv(cx, kN), gy = floorDiv(cy, kN);
		auto it = tileAt.find(key3(plane, gx, gy));
		if (it == tileAt.end()) return -1;
		lx = cx - gx * kN;
		ly = cy - gy * kN;
		return it->second;
	}

	void addHead(int plane, int cx, int cy, float v, float dip) {
		int lx, ly;
		int t = tileOf(plane, cx, cy, lx, ly);
		if (t < 0 || !tiles[t].water[ly * kN + lx]) return;
		Slot* S = activate(t);
		if (!S) return;
		S->head[ly * kN + lx] += v;
		S->dip[ly * kN + lx] += dip;
		S->hasHead = true;
	}

	// The drawn height of cell (cx, cy) of `tile`'s neighbourhood (cx, cy in [-kR, kN + kR)):
	// the simulated surface less the dip under bodies; dry cells show their mirror image.
	float displayAt(int tile, int cx, int cy) const {
		const Tile& T = tiles[tile];
		if (!T.ghostOf.empty()) {
			int q = T.ghostOf[(cy + kR) * kPad + cx + kR];
			if (q >= 0) {
				cx = q % kPad - kR;
				cy = q / kPad - kR;
			}
		}
		int dx = cx < 0 ? -1 : (cx >= kN ? 1 : 0), dy = cy < 0 ? -1 : (cy >= kN ? 1 : 0);
		int t = T.nb[(dy + 1) * 3 + dx + 1];
		if (t < 0) return 0;
		const Slot* S = slotOf(t);
		if (!S) return 0;
		int k = (cy - dy * kN) * kN + (cx - dx * kN);
		return S->h[k] - S->dip[k];
	}

	// Mirror positions for the dry pad cells of every tile next to land.
	void buildGhosts() {
		const int search = kR + 2;
		uint8_t wet[kPad * kPad];
		for (Tile& t : tiles) {
			t.ghostOf.clear();
			t.ghosts.clear();
			bool dry = false;
			for (int py = 0; py < kPad; ++py)
				for (int px = 0; px < kPad; ++px) {
					int cx = px - kR, cy = py - kR;
					int dx = cx < 0 ? -1 : (cx >= kN ? 1 : 0), dy = cy < 0 ? -1 : (cy >= kN ? 1 : 0);
					int nt = t.nb[(dy + 1) * 3 + dx + 1];
					bool w = nt >= 0 && tiles[nt].water[(cy - dy * kN) * kN + (cx - dx * kN)] > 0;
					wet[py * kPad + px] = w;
					dry |= !w;
				}
			if (!dry) continue;
			t.ghostOf.assign(kPad * kPad, -1);
			for (int py = 0; py < kPad; ++py)
				for (int px = 0; px < kPad; ++px) {
					if (wet[py * kPad + px]) continue;
					// only what the kernel (radius kR + 0.5) of one of the tile's own cells reads
					int ox = std::max({ kR - px, 0, px - (kR + kN - 1) }), oy = std::max({ kR - py, 0, py - (kR + kN - 1) });
					if (ox * ox + oy * oy > (kR + 1) * (kR + 1)) continue;
					int best = -1, bestD = 1 << 30;
					for (int sy = -search; sy <= search; ++sy)
						for (int sx = -search; sx <= search; ++sx) {
							int qx = px + sx, qy = py + sy;
							if (qx < 0 || qy < 0 || qx >= kPad || qy >= kPad || !wet[qy * kPad + qx]) continue;
							int d = sx * sx + sy * sy;
							if (d < bestD) {
								bestD = d;
								best = qy * kPad + qx;
							}
						}
					if (best < 0) continue;
					// reflect through the wall, which runs half a cell beyond the nearest water
					int wx = best % kPad, wy = best / kPad;
					int mx = 2 * wx + (px > wx) - (px < wx) - px, my = 2 * wy + (py > wy) - (py < wy) - py;
					int q = (mx >= 0 && my >= 0 && mx < kPad && my < kPad && wet[my * kPad + mx]) ? my * kPad + mx : best;
					t.ghostOf[py * kPad + px] = static_cast<int16_t>(q);
					t.ghosts.push_back({ static_cast<int16_t>(py * kPad + px), static_cast<int16_t>(q) });
				}
		}
	}

	// ------------------------------------------------------------ bodies

	bool interpolate(const Body& b, double t, std::vector<Mat34>& out) const {
		if (b.samples.empty()) return false;
		const Sample* a = &b.samples.front();
		const Sample* c = a;
		for (const Sample& s : b.samples) {
			if (s.t <= t) a = &s;
			c = &s;
			if (s.t >= t) break;
		}
		if (c->t < a->t || c->m.size() != a->m.size() || c->t - a->t < 1e-6) {
			out = (t >= c->t) ? c->m : a->m;
			return true;
		}
		float u = static_cast<float>(std::clamp((t - a->t) / (c->t - a->t), 0.0, 1.0));
		out.resize(a->m.size());
		for (size_t i = 0; i < out.size(); ++i)
			for (int r = 0; r < 3; ++r)
				for (int k = 0; k < 4; ++k) out[i].m[r][k] = a->m[i].m[r][k] + (c->m[i].m[r][k] - a->m[i].m[r][k]) * u;
		return true;
	}

	// The push of body b this step, added to the tiles. Each column where the body pierces
	// the surface presses with the depth it reaches below it there (capped), as a pressure
	// patch does in linear ship-wave theory: moving, that makes the bow wave, the trough
	// behind and the wake; at rest, the surface settles into the body's dip and lies flat
	// around it. Parts wholly under water push only with what changed lately (high-passed
	// with settings.tau), and less the deeper they are: a body resting on the bottom leaves
	// the surface alone, one moving under it does not. The surface is simulated with the
	// push blurred over a cell, which keeps grid noise down; what is drawn has the dip
	// pulled back a cell inside the waterline, so it stays hidden in the body (hollow hulls
	// stay dry inside) and the water around a floating body shows no moat.
	void bodyHeads(Body& b, double t, float dt) {
		const float followS = std::min(1.0f, dt / std::max(settings.tau, 0.01f));
		const float fade = b.present ? 1.0f : std::min(1.0f, dt / kFadeTau);
		auto sh = shapes.find(b.shape);
		if (b.present && sh != shapes.end() && interpolate(b, t, mats)) {
			const std::vector<Part>& parts = sh->second;
			// parts in world space, and their bounds
			world.clear();
			float x0 = 1e30f, y0 = 1e30f, z0 = 1e30f, x1 = -1e30f, y1 = -1e30f, z1 = -1e30f;
			for (size_t pi = 0; pi < parts.size(); ++pi) {
				const Mat34& M = mats.size() == 1 ? mats[0] : mats[std::min(pi, mats.size() - 1)];
				const std::vector<float>& v = parts[pi].v;
				for (size_t k = 0; k + 2 < v.size(); k += 3) {
					float x = M.m[0][0] * v[k] + M.m[0][1] * v[k + 1] + M.m[0][2] * v[k + 2] + M.m[0][3];
					float y = M.m[1][0] * v[k] + M.m[1][1] * v[k + 1] + M.m[1][2] * v[k + 2] + M.m[1][3];
					float z = M.m[2][0] * v[k] + M.m[2][1] * v[k + 1] + M.m[2][2] * v[k + 2] + M.m[2][3];
					world.push_back(x);
					world.push_back(y);
					world.push_back(z);
					x0 = std::min(x0, x); x1 = std::max(x1, x);
					y0 = std::min(y0, y); y1 = std::max(y1, y);
					z0 = std::min(z0, z); z1 = std::max(z1, z);
				}
			}
			for (int plane = 0; plane < static_cast<int>(planeZ.size()); ++plane) {
				const float zs = planeZ[plane];
				if (z0 > zs + 1.0f || z1 < zs - settings.depthMax) continue;
				// cell grid around the footprint, one cell of margin for the blur
				int cx0 = static_cast<int>(std::floor(x0 / kCell + 0.5f)) - 1, cx1 = static_cast<int>(std::floor(x1 / kCell + 0.5f)) + 1;
				int cy0 = static_cast<int>(std::floor(y0 / kCell + 0.5f)) - 1, cy1 = static_cast<int>(std::floor(y1 / kCell + 0.5f)) + 1;
				int w = cx1 - cx0 + 1, hgt = cy1 - cy0 + 1;
				if (w > kMaxBodyCells || hgt > kMaxBodyCells) continue;
				int sw = 2 * w, shh = 2 * hgt;
				subP.assign(static_cast<size_t>(sw) * shh, 0.0f);
				subS.assign(subP.size(), 0.0f);
				zlo.resize(subP.size());
				zhi.resize(subP.size());
				size_t vbase = 0;
				for (size_t pi = 0; pi < parts.size(); ++pi) {
					size_t nv = parts[pi].v.size() / 3;
					rasterisePart(world.data() + vbase * 3, nv, zs, cx0, cy0, sw, shh);
					vbase += nv;
				}
				// cells: the mean of their samples (partly covered edge cells press less)
				cellP.assign(static_cast<size_t>(w) * hgt, 0.0f);
				cellS.assign(cellP.size(), 0.0f);
				for (int j = 0; j < hgt; ++j)
					for (int i = 0; i < w; ++i) {
						size_t s0 = static_cast<size_t>(2 * j) * sw + 2 * i, s1 = s0 + sw;
						cellP[j * w + i] = 0.25f * (subP[s0] + subP[s0 + 1] + subP[s1] + subP[s1 + 1]);
						cellS[j * w + i] = 0.25f * (subS[s0] + subS[s0 + 1] + subS[s1] + subS[s1 + 1]);
					}
				// the drawn dip stays a cell inside the waterline, where the body hides it
				erode(cellP, cellE, w, hgt);
				blur(cellS, w, hgt);
				blur(cellP, w, hgt);
				const float k = settings.strength;
				for (int j = 0; j < hgt; ++j)
					for (int i = 0; i < w; ++i) {
						float p = cellP[j * w + i] * k, d = cellS[j * w + i] * k, e = cellE[j * w + i] * k;
						int cx = cx0 + i, cy = cy0 + j;
						int64_t key = key3(plane, cx, cy);
						auto it = b.slow.find(key);
						if (p <= 0.0f && d <= 0.0f && it == b.slow.end()) continue;
						if (it == b.slow.end()) it = b.slow.emplace(key, Slow { 0.0f, 0.0f, 0.0f, plane, cx, cy, 0 }).first;
						Slow& s = it->second;
						s.s += (d - s.s) * followS;
						s.p = p;
						s.e = e;
						s.stamp = stamp;
						addHead(plane, cx, cy, p + (d - s.s), e - p);
					}
			}
		}
		// cells the body has left: what pierced them is gone at once (the water rushes in),
		// what was under water fades with its high-pass. A body that is gone altogether
		// (removed, out of reach) lets go over kFadeTau rather than leaving a hole at once.
		for (auto it = b.slow.begin(); it != b.slow.end();) {
			Slow& s = it->second;
			if (s.stamp == stamp) {
				++it;
				continue;
			}
			s.s -= s.s * followS;
			s.p -= s.p * fade;
			s.e -= s.e * fade;
			addHead(s.plane, s.cx, s.cy, s.p - s.s, s.e - s.p);
			bool gone = std::fabs(s.s) < 1e-4f && std::fabs(s.p) < 1e-4f && std::fabs(s.e) < 1e-4f;
			it = gone ? b.slow.erase(it) : std::next(it);
		}
	}

	// Per sample: the vertical extent of one convex part, then its submerged head.
	void rasterisePart(const float* v, size_t nv, float zs, int cx0, int cy0, int sw, int shh) {
		std::fill(zlo.begin(), zlo.end(), 1e30f);
		std::fill(zhi.begin(), zhi.end(), -1e30f);
		int iLo = sw, iHi = -1, jLo = shh, jHi = -1;
		// sample (i, j) sits at ((cx0 + 0.5 i - 0.25) kCell, (cy0 + 0.5 j - 0.25) kCell)
		const float ox = (cx0 - 0.25f) * kCell, oy = (cy0 - 0.25f) * kCell;
		for (size_t t = 0; t + 2 < nv; t += 3) {
			const float* a = v + t * 3;
			const float* b = a + 3;
			const float* c = b + 3;
			float area = (b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1]);
			if (std::fabs(area) < 1e-4f) continue;  // edge-on from above
			float inv = 1.0f / area;
			int i0 = std::max(0, static_cast<int>(std::ceil((std::min({ a[0], b[0], c[0] }) - ox) / kSub)));
			int i1 = std::min(sw - 1, static_cast<int>(std::floor((std::max({ a[0], b[0], c[0] }) - ox) / kSub)));
			int j0 = std::max(0, static_cast<int>(std::ceil((std::min({ a[1], b[1], c[1] }) - oy) / kSub)));
			int j1 = std::min(shh - 1, static_cast<int>(std::floor((std::max({ a[1], b[1], c[1] }) - oy) / kSub)));
			for (int j = j0; j <= j1; ++j) {
				float py = oy + j * kSub;
				for (int i = i0; i <= i1; ++i) {
					float px = ox + i * kSub;
					float wa = ((b[0] - px) * (c[1] - py) - (c[0] - px) * (b[1] - py)) * inv;
					float wb = ((c[0] - px) * (a[1] - py) - (a[0] - px) * (c[1] - py)) * inv;
					float wc = 1.0f - wa - wb;
					if (wa < -1e-5f || wb < -1e-5f || wc < -1e-5f) continue;
					float z = wa * a[2] + wb * b[2] + wc * c[2];
					size_t k = static_cast<size_t>(j) * sw + i;
					zlo[k] = std::min(zlo[k], z);
					zhi[k] = std::max(zhi[k], z);
					iLo = std::min(iLo, i); iHi = std::max(iHi, i);
					jLo = std::min(jLo, j); jHi = std::max(jHi, j);
				}
			}
		}
		const float lo = zs - settings.depthMax;
		for (int j = jLo; j <= jHi; ++j)
			for (int i = iLo; i <= iHi; ++i) {
				size_t k = static_cast<size_t>(j) * sw + i;
				if (zhi[k] < zlo[k]) continue;
				float s = std::min(zhi[k], zs) - std::max(zlo[k], lo);
				if (s <= 0.0f) continue;
				float hd = std::min(s, settings.headMax);
				if (zhi[k] >= zs) {
					subP[k] = std::max(subP[k], hd);
				} else {
					subS[k] = std::max(subS[k], hd * std::exp(-(zs - zhi[k]) / kDeepFade));
				}
			}
	}

	void blur(std::vector<float>& cell, int w, int hgt) {
		tmp.assign(cell.size(), 0.0f);
		for (int j = 0; j < hgt; ++j)
			for (int i = 0; i < w; ++i) {
				float c = cell[j * w + i] * 2.0f;
				if (i > 0) c += cell[j * w + i - 1];
				if (i + 1 < w) c += cell[j * w + i + 1];
				tmp[j * w + i] = c * 0.25f;
			}
		for (int j = 0; j < hgt; ++j)
			for (int i = 0; i < w; ++i) {
				float c = tmp[j * w + i] * 2.0f;
				if (j > 0) c += tmp[(j - 1) * w + i];
				if (j + 1 < hgt) c += tmp[(j + 1) * w + i];
				cell[j * w + i] = c * 0.25f;
			}
	}

	// Smallest value of each cell's 3 x 3 neighbourhood (the grid's border is outside).
	static void erode(const std::vector<float>& in, std::vector<float>& out, int w, int hgt) {
		out.assign(in.size(), 0.0f);
		for (int j = 1; j + 1 < hgt; ++j)
			for (int i = 1; i + 1 < w; ++i) {
				float m = in[j * w + i];
				for (int dj = -1; dj <= 1; ++dj)
					for (int di = -1; di <= 1; ++di) m = std::min(m, in[(j + dj) * w + i + di]);
				out[j * w + i] = m;
			}
	}

	// ------------------------------------------------------------ the step

	// An impulse is a pressure on the surface for one step (a head of kImpulseHead per unit
	// of depth): the kernel turns it into a push down in the middle and up around it, with no
	// net flow, so the crater refills from its rim instead of leaving the area sunk.
	void applyImpulses() {
		for (const Impulse& im : impulses) {
			if (im.plane < 0 || im.plane >= static_cast<int>(planeZ.size())) continue;
			float sigma = std::max(im.radius, kCell * 0.5f);
			float reach = 2.5f * sigma;
			int cx0 = static_cast<int>(std::ceil((im.x - reach) / kCell)), cx1 = static_cast<int>(std::floor((im.x + reach) / kCell));
			int cy0 = static_cast<int>(std::ceil((im.y - reach) / kCell)), cy1 = static_cast<int>(std::floor((im.y + reach) / kCell));
			for (int cy = cy0; cy <= cy1; ++cy)
				for (int cx = cx0; cx <= cx1; ++cx) {
					float dx = cx * kCell - im.x, dy = cy * kCell - im.y;
					float d2 = dx * dx + dy * dy;
					if (d2 > reach * reach) continue;
					int lx, ly;
					int t = tileOf(im.plane, cx, cy, lx, ly);
					if (t < 0 || !tiles[t].water[ly * kN + lx]) continue;
					Slot* S = activate(t);
					if (!S) continue;
					S->head[ly * kN + lx] += im.depth * kImpulseHead * std::exp(-d2 / (2.0f * sigma * sigma));
					S->hasHead = true;
				}
		}
		impulses.clear();
	}

	void gather(const Tile& T) {
		std::memset(pad, 0, sizeof pad);
		std::memset(vpad, 0, sizeof vpad);
		for (int dy = -1; dy <= 1; ++dy)
			for (int dx = -1; dx <= 1; ++dx) {
				int nt = T.nb[(dy + 1) * 3 + dx + 1];
				if (nt < 0) continue;
				const Slot* S = slotOf(nt);
				if (!S) continue;
				int x0 = std::max(0, kR + dx * kN), x1 = std::min(kPad, kR + dx * kN + kN);
				int y0 = std::max(0, kR + dy * kN), y1 = std::min(kPad, kR + dy * kN + kN);
				const int shift = kR + dx * kN;  // pad column = tile column + shift
				for (int yp = y0; yp < y1; ++yp) {
					int yt = yp - kR - dy * kN;
					const float* hr = S->h + yt * kN;
					const float* qr = S->hp + yt * kN;
					const float* dr = S->head + yt * kN;
					float* pr = pad + yp * kPad;
					float* vr = vpad + yp * kPad;
					if (S->hasHead)
						for (int xp = x0; xp < x1; ++xp) pr[xp] = hr[xp - shift] + dr[xp - shift];
					else
						for (int xp = x0; xp < x1; ++xp) pr[xp] = hr[xp - shift];
					for (int xp = x0; xp < x1; ++xp) vr[xp] = hr[xp - shift] - qr[xp - shift];
				}
			}
		for (const auto& g : T.ghosts) {
			pad[g.first] = pad[g.second];
			vpad[g.first] = vpad[g.second];
		}
	}

	void convolve(float* vd) {
		if (kAvx2) {
			convolveAvx2(pad, kernel.data(), kernel.size(), vd);
			return;
		}
		for (int y = 0; y < kN; ++y) {
			__m128 a0 = _mm_setzero_ps(), a1 = _mm_setzero_ps(), a2 = _mm_setzero_ps(), a3 = _mm_setzero_ps();
			for (const Offset& o : kernel) {
				const float* s = pad + (y + kR + o.dy) * kPad + kR + o.dx;
				__m128 w = _mm_set1_ps(o.w);
				a0 = _mm_add_ps(a0, _mm_mul_ps(w, _mm_loadu_ps(s)));
				a1 = _mm_add_ps(a1, _mm_mul_ps(w, _mm_loadu_ps(s + 4)));
				a2 = _mm_add_ps(a2, _mm_mul_ps(w, _mm_loadu_ps(s + 8)));
				a3 = _mm_add_ps(a3, _mm_mul_ps(w, _mm_loadu_ps(s + 12)));
			}
			_mm_store_ps(vd + y * kN, a0);
			_mm_store_ps(vd + y * kN + 4, a1);
			_mm_store_ps(vd + y * kN + 8, a2);
			_mm_store_ps(vd + y * kN + 12, a3);
		}
	}

	// Linear waves can grow steeper than real water allows (a blunt body at the wrong speed
	// keeps feeding its own wake). Where the free surface (h + head) is steeper than
	// kBreakSlope, the Stokes limit, its vertical motion is damped: the energy a breaking
	// crest loses (white-capping). Damping only takes energy out, so it stays stable. The
	// slope comes from a 3 x 3 (Sobel) stencil and the damping is blurred over 3 x 3: a
	// damping that switches on and off from one cell to the next, measured with central
	// differences (blind to them), feeds waves two cells long that line a wake like stitches.
	void breaking(float* brk) const {
		constexpr int M = kN + 2;
		// a Sobel slope is at most 0.354 times the largest |value| it reads: tiles whose
		// waves are lower than that cannot break
		float top = 0;
		for (int y = -2; y < kN + 2; ++y) {
			const float* c = pad + (y + kR) * kPad + kR - 2;
			for (int x = 0; x < kN + 4; ++x) top = std::max(top, std::fabs(c[x]));
		}
		if (top * 0.354f <= kBreakSlope) {
			std::memset(brk, 0, sizeof(float) * kN * kN);
			return;
		}
		float raw[M * M];
		for (int y = -1; y <= kN; ++y)
			for (int x = -1; x <= kN; ++x) {
				const float* c = pad + (y + kR) * kPad + x + kR;
				float gx = (2.0f * (c[1] - c[-1]) + (c[1 + kPad] - c[-1 + kPad]) + (c[1 - kPad] - c[-1 - kPad])) * (0.125f / kCell);
				float gy = (2.0f * (c[kPad] - c[-kPad]) + (c[kPad + 1] - c[-kPad + 1]) + (c[kPad - 1] - c[-kPad - 1])) * (0.125f / kCell);
				float s2 = gx * gx + gy * gy;
				raw[(y + 1) * M + x + 1] = s2 > kBreakSlope * kBreakSlope
				                               ? std::min(1.0f, (std::sqrt(s2) - kBreakSlope) / kBreakSlope) * kBreakRate
				                               : 0.0f;
			}
		for (int y = 0; y < kN; ++y)
			for (int x = 0; x < kN; ++x) {
				const float* r = raw + (y + 1) * M + x + 1;
				brk[y * kN + x] = (4.0f * r[0] + 2.0f * (r[1] + r[-1] + r[M] + r[-M]) + r[M + 1] + r[M - 1] + r[-M + 1] + r[-M - 1]) *
				                  (1.0f / 16.0f);
			}
	}

	// Viscosity on the surface velocity: its discrete Laplacian, so the damping rate grows with
	// k^2 and the grid's shortest waves (noise from sharp shapes) die within a few steps while
	// long waves keep travelling.
	void viscosity(float* visc) const {
		for (int y = 0; y < kN; ++y)
			for (int x = 0; x < kN; ++x) {
				const float* c = vpad + (y + kR) * kPad + x + kR;
				visc[y * kN + x] = 0.25f * (c[1] + c[-1] + c[kPad] + c[-kPad]) - c[0];
			}
	}

	void step(double t) {
		const float dt = static_cast<float>(kStep);
		++stamp;
		for (int tile : active) {
			Slot& S = *slots[tiles[tile].slot];
			if (S.hasHead) {
				std::memset(S.head, 0, sizeof S.head);
				std::memset(S.dip, 0, sizeof S.dip);
				S.hasHead = false;
			}
		}
		for (int tile : wake) activate(tile);
		wake.clear();
		for (auto it = bodies.begin(); it != bodies.end();) {
			bodyHeads(it->second, t, dt);
			it = (!it->second.present && it->second.slow.empty()) ? bodies.erase(it) : std::next(it);
		}
		applyImpulses();

		// iWave, d2h/dt2 + a dh/dt = -(g K + kSpring) (h + head), with the damping on the
		// velocity only: h' = h + (h - h_prev - dt^2 (g K + kSpring) (h + head)) / (1 + a dt),
		// plus viscosity and breaking, which damp the velocity too. (Tessendorf's paper has
		// (2 - a dt) / (1 + a dt) for the factor of h, which also pulls the height itself back to
		// rest: a stiff spring, waves up to 70 % too fast, and bodies that never settle.)
		// g K + kSpring together are fitted to g |k|: the kernel, a few cells wide, cannot
		// carry the longest waves alone, and the spring gives them what it lacks. Acting on
		// the free surface h + head, the spring also keeps the rest state exact (h = -head
		// under a floating body) and lets the water a body displaces go, as into the whole
		// pool, instead of spreading it as a swell over every tile.
		for (int tile : active) {
			gather(tiles[tile]);
			Slot& S = *slots[tiles[tile].slot];
			convolve(S.vd);
			breaking(S.brk);
			viscosity(S.visc);
		}
		const float c2 = 1.0f / (1.0f + settings.damping * dt);
		const float cg = kGravity * dt * dt * c2, cs = kSpring * dt * dt * c2;
		size_t keep = 0;
		for (size_t ai = 0; ai < active.size(); ++ai) {
			int tile = active[ai];
			Tile& T = tiles[tile];
			Slot& S = *slots[T.slot];
			float amp = 0, shown = 0, rate = 0;
			float edge[9] = {};
			for (int y = 0; y < kN; ++y) {
				int ey = y < kR ? 0 : (y >= kN - kR ? 2 : 1);
				for (int x = 0; x < kN; ++x) {
					int k = y * kN + x;
					float v = S.h[k] - S.hp[k];
					float hn = (S.h[k] + c2 * (v * (1.0f - S.brk[k]) + kViscosity * S.visc[k]) - cg * S.vd[k] - cs * (S.h[k] + S.head[k])) * T.water[k];
					float a = std::fabs(hn);
					rate = std::max(rate, std::fabs(hn - S.h[k]));
					S.hp[k] = S.h[k];
					S.h[k] = hn;
					amp = std::max(amp, a);
					shown = std::max(shown, std::fabs(hn - S.dip[k]));
					int ex = x < kR ? 0 : (x >= kN - kR ? 2 : 1);
					if (ex != 1) edge[3 + ex] = std::max(edge[3 + ex], a);
					if (ey != 1) edge[ey * 3 + 1] = std::max(edge[ey * 3 + 1], a);
					if (ex != 1 && ey != 1) edge[ey * 3 + ex] = std::max(edge[ey * 3 + ex], a);
				}
			}
			S.amp = shown;
			std::copy(std::begin(edge), std::end(edge), S.edge);
			for (int n = 0; n < 9; ++n)
				if (n != 4 && edge[n] > kSpread && T.nb[n] >= 0 && tiles[T.nb[n]].slot < 0) wake.push_back(T.nb[n]);
			S.quiet = (amp < kQuietAmp && rate < kQuietRate && !S.hasHead) ? S.quiet + 1 : 0;
			if (S.quiet > kQuietSteps) {
				release(tile);
				continue;
			}
			active[keep++] = tile;
		}
		active.resize(keep);
	}
};

Sim::Sim() : p_(std::make_unique<Impl>(settings)) {}
Sim::~Sim() = default;

void Sim::setSurface(const std::vector<float>& planeZ, const std::vector<TileDesc>& tiles) {
	Impl& I = *p_;
	clear();
	I.planeZ = planeZ;
	I.tiles.assign(tiles.size(), Impl::Tile {});
	I.tileAt.clear();
	for (size_t i = 0; i < tiles.size(); ++i) I.tileAt[key3(tiles[i].plane, tiles[i].gx, tiles[i].gy)] = static_cast<int>(i);
	for (size_t i = 0; i < tiles.size(); ++i) {
		Impl::Tile& t = I.tiles[i];
		t.plane = tiles[i].plane;
		t.gx = tiles[i].gx;
		t.gy = tiles[i].gy;
		for (int k = 0; k < kN * kN; ++k) t.water[k] = (k < static_cast<int>(tiles[i].water.size()) && tiles[i].water[k]) ? 1.0f : 0.0f;
		for (int dy = -1; dy <= 1; ++dy)
			for (int dx = -1; dx <= 1; ++dx) {
				auto it = I.tileAt.find(key3(t.plane, t.gx + dx, t.gy + dy));
				t.nb[(dy + 1) * 3 + dx + 1] = it == I.tileAt.end() ? -1 : it->second;
			}
	}
	I.buildGhosts();
}

void Sim::setShape(int key, const std::vector<std::vector<float>>& parts) {
	std::vector<Impl::Part>& dst = p_->shapes[key];
	dst.clear();
	for (const std::vector<float>& v : parts) dst.push_back({ v });
}

void Sim::setBodies(double time, std::vector<BodyInput> bodies) {
	Impl& I = *p_;
	for (auto& kv : I.bodies) kv.second.present = false;
	for (BodyInput& in : bodies) {
		Impl::Body& b = I.bodies[in.id];
		if (b.shape != in.shape) {
			b.shape = in.shape;
			b.samples.clear();
		}
		if (!b.samples.empty() && time <= b.samples.back().t) b.samples.back() = { time, std::move(in.parts) };
		else b.samples.push_back({ time, std::move(in.parts) });
		while (b.samples.size() > static_cast<size_t>(kHistory)) b.samples.pop_front();
		b.present = true;
	}
}

void Sim::addImpulse(int plane, float x, float y, float depth, float radius) {
	p_->impulses.push_back({ plane, x, y, depth, radius });
}

void Sim::clear() {
	Impl& I = *p_;
	for (int tile : I.active) I.release(tile);
	I.active.clear();
	I.wake.clear();
	I.bodies.clear();
	I.impulses.clear();
	I.simTime = -1;
}

void Sim::advance(double now) {
	Impl& I = *p_;
	I.stats.steps = 0;
	if (I.tiles.empty()) return;
	LARGE_INTEGER f, t0, t1;
	QueryPerformanceFrequency(&f);
	QueryPerformanceCounter(&t0);
	double target = now - kStep;  // a step behind: body samples are interpolated, not extrapolated
	if (I.simTime < 0 || target - I.simTime > 0.5 || target < I.simTime - 1.0) I.simTime = target - kStep;
	int n = 0;
	while (I.simTime + kStep <= target && n < kMaxSteps) {
		I.simTime += kStep;
		I.step(I.simTime);
		++n;
	}
	if (I.simTime + kStep <= target) I.simTime = target;  // fell behind: skip ahead
	QueryPerformanceCounter(&t1);
	I.stats.steps = n;
	I.stats.ms = (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart;
	I.stats.tiles = static_cast<int>(I.active.size());
	int b = 0;
	for (const auto& kv : I.bodies) b += kv.second.present ? 1 : 0;
	I.stats.bodies = b;
}

bool Sim::simulated(int tile) const { return tile >= 0 && tile < static_cast<int>(p_->tiles.size()) && p_->tiles[tile].slot >= 0; }

float Sim::amplitude(int tile) const {
	const Impl::Slot* S = simulated(tile) ? p_->slotOf(tile) : nullptr;
	return S ? S->amp : 0.0f;
}

void Sim::simulatedTiles(std::vector<int>& out) const { out = p_->active; }

void Sim::sampleNodes(int tile, int n, float* h, float* sx, float* sy) const {
	const Impl& I = *p_;
	int st = kN / n;
	const float inv = 1.0f / (2.0f * kCell);
	size_t k = 0;
	for (int j = 0; j <= n; ++j)
		for (int i = 0; i <= n; ++i, ++k) {
			int cx = i * st, cy = j * st;
			h[k] = I.displayAt(tile, cx, cy);
			sx[k] = (I.displayAt(tile, cx + 1, cy) - I.displayAt(tile, cx - 1, cy)) * inv;
			sy[k] = (I.displayAt(tile, cx, cy + 1) - I.displayAt(tile, cx, cy - 1)) * inv;
		}
}

Stats Sim::stats() const { return p_->stats; }

}  // namespace wave
