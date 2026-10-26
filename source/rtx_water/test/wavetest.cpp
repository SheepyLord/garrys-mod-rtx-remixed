// Offline check of wavesim: runs scenarios on a synthetic pool and writes the drawn height
// field as raw floats (view with test/view.py).
//
//     wavetest wake [speed]     a hull crossing the pool
//     wavetest kelvin [speed]   the same, started gently (for measuring the wake angle)
//     wavetest drop             a tilted box dropped near a wall
//     wavetest walk             two legs wading forward
//     wavetest float            a crate floating at rest
//     wavetest plank [speed]    a beam pushed lengthwise, then sideways
//     wavetest bullet           a bullet's impulse, next to a round pillar
#include "../wavesim.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

using namespace wave;

namespace {

constexpr int kTilesX = 40, kTilesY = 20;  // 2560 x 1280 units

// Axis-aligned box hull, half extents (hx, hy, hz), as a triangle soup.
std::vector<float> box(float hx, float hy, float hz) {
	const float c[8][3] = { { -hx, -hy, -hz }, { hx, -hy, -hz }, { hx, hy, -hz }, { -hx, hy, -hz },
	                        { -hx, -hy, hz }, { hx, -hy, hz }, { hx, hy, hz }, { -hx, hy, hz } };
	const int f[12][3] = { { 0, 2, 1 }, { 0, 3, 2 }, { 4, 5, 6 }, { 4, 6, 7 }, { 0, 1, 5 }, { 0, 5, 4 },
	                       { 1, 2, 6 }, { 1, 6, 5 }, { 2, 3, 7 }, { 2, 7, 6 }, { 3, 0, 4 }, { 3, 4, 7 } };
	std::vector<float> v;
	for (const auto& t : f)
		for (int k = 0; k < 3; ++k)
			for (int a = 0; a < 3; ++a) v.push_back(c[t[k]][a]);
	return v;
}

Mat34 place(float x, float y, float z, float yaw = 0.0f, float roll = 0.0f) {
	float cy = std::cos(yaw), sy = std::sin(yaw), cr = std::cos(roll), sr = std::sin(roll);
	// yaw about z, then roll about the body's x axis
	Mat34 m {};
	m.m[0][0] = cy; m.m[0][1] = -sy * cr; m.m[0][2] = sy * sr; m.m[0][3] = x;
	m.m[1][0] = sy; m.m[1][1] = cy * cr;  m.m[1][2] = -cy * sr; m.m[1][3] = y;
	m.m[2][0] = 0;  m.m[2][1] = sr;       m.m[2][2] = cr;       m.m[2][3] = z;
	return m;
}

// Which tiles exist (row-major, so the dump can find them again).
std::vector<int> g_tileIndex;

// The pool: a wall (the left 4 tiles are dry ground), or a round pillar of radius 40 at
// (1000, 640), or open water.
void surface(Sim& sim, const std::string& what) {
	std::vector<TileDesc> tiles;
	g_tileIndex.assign(kTilesX * kTilesY, -1);
	for (int gy = 0; gy < kTilesY; ++gy)
		for (int gx = 0; gx < kTilesX; ++gx) {
			if (what == "drop" && gx < 4) continue;
			TileDesc t;
			t.plane = 0;
			t.gx = gx;
			t.gy = gy;
			t.water.assign(kN * kN, 1);
			if (what == "bullet")
				for (int j = 0; j < kN; ++j)
					for (int i = 0; i < kN; ++i) {
						float x = (gx * kN + i) * kCell - 1000.0f, y = (gy * kN + j) * kCell - 640.0f;
						if (x * x + y * y < 40.0f * 40.0f) t.water[j * kN + i] = 0;
					}
			g_tileIndex[gy * kTilesX + gx] = static_cast<int>(tiles.size());
			tiles.push_back(t);
		}
	sim.setSurface({ 0.0f }, tiles);
}

void dump(const Sim& sim, const char* path) {
	// sample every node of the pool into one image
	const int W = kTilesX * kN, H = kTilesY * kN;
	std::vector<float> img(static_cast<size_t>(W) * H, 0.0f);
	std::vector<float> h((kN + 1) * (kN + 1)), sx(h.size()), sy(h.size());
	for (int gy = 0; gy < kTilesY; ++gy)
		for (int gx = 0; gx < kTilesX; ++gx) {
			int tile = g_tileIndex[gy * kTilesX + gx];
			if (tile < 0 || !sim.simulated(tile)) continue;
			sim.sampleNodes(tile, kN, h.data(), sx.data(), sy.data());
			for (int j = 0; j < kN; ++j)
				for (int i = 0; i < kN; ++i) img[static_cast<size_t>(gy * kN + j) * W + gx * kN + i] = h[j * (kN + 1) + i];
		}
	FILE* f = std::fopen(path, "wb");
	std::fwrite(&W, 4, 1, f);
	std::fwrite(&H, 4, 1, f);
	std::fwrite(img.data(), 4, img.size(), f);
	std::fclose(f);
}

}  // namespace

int main(int argc, char** argv) {
	std::string what = argc > 1 ? argv[1] : "wake";
	Sim sim;
	surface(sim, what);
	double total = 0;
	int frames = 0, maxTiles = 0;
	auto run = [&](double t) {
		auto a = std::chrono::high_resolution_clock::now();
		sim.advance(t);
		auto b = std::chrono::high_resolution_clock::now();
		total += std::chrono::duration<double, std::milli>(b - a).count();
		++frames;
		maxTiles = std::max(maxTiles, sim.stats().tiles);
	};
	if (what == "wake") {
		float speed = argc > 2 ? static_cast<float>(std::atof(argv[2])) : 80.0f;
		sim.setShape(1, { box(24, 8, 12) });
		for (int i = 0; i <= 9 * 60; ++i) {
			double t = i / 60.0;
			sim.setBodies(t, { BodyInput { 1, 1, { place(400.0f + speed * static_cast<float>(t), 640.0f, 0.0f) } } });
			run(t);
		}
		dump(sim, ("wake_" + std::to_string(static_cast<int>(speed)) + ".raw").c_str());
	} else if (what == "kelvin") {
		// the same hull, lowered in over 2 s, brought up to speed over the next 2 s, then
		// steady to 14 s: a wake without the splash of a sudden start
		float speed = argc > 2 ? static_cast<float>(std::atof(argv[2])) : 80.0f;
		sim.setShape(1, { box(24, 8, 12) });
		float x = 300.0f;
		for (int i = 0; i <= 14 * 60; ++i) {
			double t = i / 60.0;
			float z = t < 2.0 ? 24.0f * static_cast<float>(1.0 - t / 2.0) : 0.0f;
			float u = t < 2.0 ? 0.0f : speed * static_cast<float>(std::min(1.0, (t - 2.0) / 2.0));
			x += u / 60.0f;
			sim.setBodies(t, { BodyInput { 1, 1, { place(x, 640.0f, z) } } });
			run(t);
		}
		std::printf("body at x %.0f\n", x);
		dump(sim, ("kelvin_" + std::to_string(static_cast<int>(speed)) + ".raw").c_str());
	} else if (what == "drop") {
		sim.setShape(1, { box(30, 12, 10) });
		for (int i = 0; i <= 5 * 60; ++i) {
			double t = i / 60.0;
			float z = std::max(40.0f - 260.0f * static_cast<float>(t), 0.0f);  // falls, then floats half in
			sim.setBodies(t, { BodyInput { 1, 1, { place(500.0f, 640.0f, z, 0.6f) } } });
			run(t);
			if (i == 90) dump(sim, "drop_90.raw");
		}
		dump(sim, "drop_end.raw");
	} else if (what == "float") {
		// a crate floating half in, at rest: the water around it should stay flat
		sim.setShape(1, { box(20, 20, 20) });
		for (int i = 0; i <= 6 * 60; ++i) {
			double t = i / 60.0;
			sim.setBodies(t, { BodyInput { 1, 1, { place(500.0f, 640.0f, 0.0f) } } });
			run(t);
		}
		dump(sim, "float.raw");
	} else if (what == "plank") {
		// a 96 x 12 x 12 beam, half in, pushed lengthwise and then sideways
		float speed = argc > 2 ? static_cast<float>(std::atof(argv[2])) : 60.0f;
		sim.setShape(1, { box(48, 6, 6) });
		for (int side = 0; side < 2; ++side) {
			sim.clear();
			for (int i = 0; i <= 8 * 60; ++i) {
				double t = i / 60.0;
				float yaw = side ? 1.5707963f : 0.0f;
				sim.setBodies(t, { BodyInput { 1, 1, { place(300.0f + speed * static_cast<float>(t), 640.0f, 0.0f, yaw) } } });
				run(t);
			}
			dump(sim, side ? "plank_side.raw" : "plank_long.raw");
		}
	} else if (what == "bullet") {
		// one impulse 60 units from the pillar's edge
		for (int i = 0; i <= 3 * 60; ++i) {
			double t = i / 60.0;
			if (i == 1) sim.addImpulse(0, 900.0f, 640.0f, 2.0f, 3.0f);
			run(t);
			if (i == 30) dump(sim, "bullet_05.raw");
			if (i == 60) dump(sim, "bullet_10.raw");
		}
		dump(sim, "bullet_30.raw");
	} else if (what == "walk") {
		// legs: two boxes 6 x 6 x 40 reaching from the floor (z -36) to above the surface
		sim.setShape(1, { box(3, 3, 20), box(3, 3, 20) });
		for (int i = 0; i <= 6 * 60; ++i) {
			double t = i / 60.0;
			float body = 300.0f + 60.0f * static_cast<float>(t);
			std::vector<Mat34> legs;
			for (int side = 0; side < 2; ++side) {
				float p = std::fmod(static_cast<float>(t) * 1.8f + side * 0.5f, 1.0f);
				float lead = 18.0f * (p < 0.5f ? std::sin(3.14159f * p) : -std::sin(3.14159f * (p - 0.5f)));
				legs.push_back(place(body + lead, 640.0f + (side ? 6.0f : -6.0f), -16.0f));
			}
			sim.setBodies(t, { BodyInput { 1, 1, legs } });
			run(t);
		}
		dump(sim, "walk.raw");
	}
	std::printf("%s: %d frames, %.3f ms per frame (%.3f ms per step), up to %d tiles\n", what.c_str(), frames,
	            total / frames, total / frames / 1.0, maxTiles);
	return 0;
}
