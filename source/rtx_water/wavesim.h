// RTX Water wave simulation.
//
// The water surface is a height field (displacement from rest) on a grid of 4-unit
// cells, advanced with Tessendorf's iWave scheme ("Interactive Water Surfaces", Game
// Programming Gems 4), its damping acting on the velocity only:
//
//     d2h/dt2 + a dh/dt = -(g sqrt(-laplacian) + spring) (h + head)
//
// sqrt(-laplacian) is a convolution with a radial kernel; kernel and spring together are
// fitted to deep-water dispersion, omega^2 = g k (tools/fit_wave_kernel.py), so waves keep
// the speeds of real water: a splash spreads into a train of rings with the long waves
// ahead, and anything moving leaves a Kelvin wake. Bodies push the water as a pressure
// patch whose head is the submerged depth of each column under them, as in linear
// ship-wave theory; the depths are rasterised from their actual shapes (physics meshes,
// hitboxes), so a plank pushed lengthwise and the same plank pushed sideways make
// different waves. A body at rest settles into its dip, drawn inside its waterline, with
// the water flat around it. The water's outline reflects waves as a vertical wall does:
// cells past it mirror the water, so the surface rises and falls freely against the wall.
//
// The grid only exists where there are waves: each 64-unit tile of the water surface is
// simulated while it carries any and dropped when it settles.
#pragma once

#include <cstdint>
#include <memory>
#include <vector>

namespace wave {

constexpr int kN = 16;                  // cells per tile side
constexpr float kTile = 64.0f;          // units; must match the water layout
constexpr float kCell = kTile / kN;     // 4 units (the kernel is fitted for this)
constexpr int kR = 6;                   // kernel radius, cells
constexpr float kGravity = 386.0f;      // units/s^2 (1 unit = 1 inch)
constexpr double kStep = 1.0 / 60.0;    // simulation time step, s

// Row-major 3x4 transform: world = m * (x, y, z, 1).
struct Mat34 {
	float m[3][4];
};

struct TileDesc {
	int plane = 0;
	int gx = 0, gy = 0;                 // tile coordinates (x0 = gx * kTile)
	std::vector<uint8_t> water;         // kN * kN nodes, 1 where the node is on the water
};

// One sample of a body: its shape and where each part of it is.
struct BodyInput {
	int id = 0;
	int shape = 0;
	std::vector<Mat34> parts;           // one matrix for all parts, or one per part
};

struct Settings {
	float damping = 0.35f;              // 1/s
	float strength = 1.0f;              // head multiplier (rtx_water_interaction_strength)
	float headMax = 12.0f;              // largest head of a column, units
	float depthMax = 48.0f;             // submerged depth that counts towards the head, units
	float tau = 0.5f;                   // s; heads of parts wholly under water are high-passed with this
	int maxTiles = 1500;                // simulated tiles at most
};

struct Stats {
	int tiles = 0;                      // simulated tiles
	int bodies = 0;                     // bodies pushing the water
	int steps = 0;                      // steps in the last advance
	double ms = 0;                      // time of the last advance
};

class Sim {
public:
	Sim();
	~Sim();

	// planeZ: rest height of each water plane; tiles: in the caller's tile order.
	void setSurface(const std::vector<float>& planeZ, const std::vector<TileDesc>& tiles);
	// Convex parts, each a triangle soup (x, y, z per vertex, three vertices a triangle) in
	// the space of the matrix that will place it.
	void setShape(int key, const std::vector<std::vector<float>>& parts);
	// Every body in or near the water at `time`; bodies left out are gone.
	void setBodies(double time, std::vector<BodyInput> bodies);
	// A dent in the surface (bullets, small splashes).
	void addImpulse(int plane, float x, float y, float depth, float radius);
	void clear();
	// Runs simulation steps up to `now` (a step behind it, so body samples interpolate).
	void advance(double now);

	Settings settings;

	bool simulated(int tile) const;
	float amplitude(int tile) const;    // largest drawn height on the tile after the last step
	void simulatedTiles(std::vector<int>& out) const;
	// Drawn heights and slopes at the (n + 1)^2 nodes of a tile (n = 16, 8, 4 or 2).
	void sampleNodes(int tile, int n, float* h, float* sx, float* sy) const;
	Stats stats() const;

private:
	struct Impl;
	std::unique_ptr<Impl> p_;
};

}  // namespace wave
