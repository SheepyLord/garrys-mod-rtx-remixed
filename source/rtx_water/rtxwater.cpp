// RTX Water native core (gmcl_rtxwater_win64.dll).
//
// Builds the water surface and its ripples in C++ and hands them straight to RTX
// Remix through its C API, so the water costs no per-frame Lua or D3D9 work:
// * Calm water: one flat mesh per 1024-unit block, each behind a persistent Remix
//   instance. Nothing is submitted per frame.
// * Waves: a simulated height field (wavesim.cpp: dispersive like real water, pushed by
//   the actual shapes of the bodies in it). The tiles that carry visible waves are
//   tessellated (indexed, shared vertices) on a worker thread, at the caller's update
//   rate, into one mesh behind one persistent instance; blocks that contain them swap to
//   a mesh without those tiles. Update only hands the worker the view, so the game thread
//   pays microseconds however busy the water is.
// * The water material is a Remix API translucent material, so colour, clarity and
//   refraction change at run time without a mesh rebuild (meshes refer to it by
//   handle).
// * Under water the camera starts inside that material (Remix's camera medium), so the
//   surface seen from below refracts out of the water: Snell's window overhead, total
//   internal reflection past the critical angle.
//
// Geometry conventions match lua/rtx_water/cl_surface.lua: polygons are flat
// {x1, y1, x2, y2, ...} arrays, counter-clockwise seen from above; triangles are
// emitted clockwise (Remix API meshes treat clockwise as the front), so the surface
// faces up and rays enter the water volume through it.
//
// Threading: GMod renders on its own thread (mat_queue_mode -2) while Lua runs on the
// main thread. Remix API calls that emit device commands straight away (DestroyMesh,
// CreateMaterial, DestroyMaterial, SetCameraMediumMaterial) take no device lock, so
// calling them from Lua races the render thread's D3D9 calls and corrupts Remix's
// command stream.
// Here they run on the render thread through the material system's call queue (the
// main thread only touches D3D9 itself under IMaterialSystem::Lock, which first waits
// for the render thread to go idle). Meshes are made with CreateMeshBatched and shown
// with persistent instances; both are only queued, and Remix applies them at Present
// under its device lock.
//
// Lua interface: global table RTXWaterNative (see lua/rtx_water/cl_native.lua).

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <GarrysMod/Lua/Interface.h>
#include <remix/remix_c.h>

#include "wavesim.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

using namespace GarrysMod::Lua;

namespace {

// ---------------------------------------------------------------- constants

constexpr float kTile = 64.0f;       // must match cl_surface.lua and wavesim.h
constexpr int kBlock = 16;           // tiles per block side
constexpr float kAmpMin = 0.02f;     // wave height below which a simulated tile is drawn flat
constexpr int kMaxImpulses = 256;    // queued between two updates at most
constexpr uint64_t kHashBase = 0x5277617465720000ull;  // "Rwater\0\0"
// Frames before a replaced mesh is destroyed. The instance switch away from it is
// applied at the render thread's next Present, which comes before the render thread
// runs anything queued in a later frame.
constexpr int kGraveDelay = 3;

// ---------------------------------------------------------------- Remix API

remixapi_Interface g_api {};
bool g_apiOk = false;
PFN_remixapi_CreatePersistentInstance g_createInst = nullptr;
PFN_remixapi_UpdatePersistentInstance g_updateInst = nullptr;
PFN_remixapi_DestroyPersistentInstance g_destroyInst = nullptr;
std::string g_initError;

std::atomic<uint64_t> g_hashCounter { 1 };
uint64_t nextHash() { return kHashBase + g_hashCounter++; }

bool initApi() {
	if (g_apiOk) return true;
	HMODULE d3d9 = GetModuleHandleW(L"d3d9.dll");
	if (!d3d9) { g_initError = "d3d9.dll (RTX Remix) is not loaded"; return false; }
	auto init = reinterpret_cast<PFN_remixapi_InitializeLibrary>(GetProcAddress(d3d9, "remixapi_InitializeLibrary"));
	g_createInst = reinterpret_cast<PFN_remixapi_CreatePersistentInstance>(GetProcAddress(d3d9, "remixapi_CreatePersistentInstance"));
	g_updateInst = reinterpret_cast<PFN_remixapi_UpdatePersistentInstance>(GetProcAddress(d3d9, "remixapi_UpdatePersistentInstance"));
	g_destroyInst = reinterpret_cast<PFN_remixapi_DestroyPersistentInstance>(GetProcAddress(d3d9, "remixapi_DestroyPersistentInstance"));
	if (!init || !g_createInst || !g_updateInst || !g_destroyInst) {
		g_initError = "this RTX Remix runtime lacks the API functions RTX Water needs (persistent instances)";
		return false;
	}
	remixapi_InitializeLibraryInfo info {};
	info.sType = REMIXAPI_STRUCT_TYPE_INITIALIZE_LIBRARY_INFO;
	info.version = REMIXAPI_VERSION_MAKE(REMIXAPI_VERSION_MAJOR, REMIXAPI_VERSION_MINOR, REMIXAPI_VERSION_PATCH);
	remixapi_ErrorCode r = init(&info, &g_api);
	if (r != REMIXAPI_ERROR_CODE_SUCCESS || !g_api.CreateMeshBatched || !g_api.DestroyMesh ||
	    !g_api.CreateMaterial || !g_api.DestroyMaterial) {
		g_initError = "remixapi_InitializeLibrary failed (" + std::to_string(static_cast<int>(r)) + ")";
		return false;
	}
	g_apiOk = true;
	return true;
}

// ---------------------------------------------------------------- render thread

// GMod's material system has no ICallQueue object behind IMatRenderContext::GetCallQueue:
// in queued mode it returns the queued context's own CMatCallQueue, which client.dll fills
// with inlined code. This does the same, appending { next, functor } elements taken from
// the queue's inline memory stack. The render thread calls each element's functor through
// vtable slot 3 and never touches it again (it then resets the queue's memory), so a job
// deletes itself once it has run. That layout is checked against materialsystem.dll's code
// before first use; if it does not match, the native core stays off.
constexpr int kSlotGetRenderContext = 102;  // IMaterialSystem
constexpr int kSlotGetCallQueue = 145;      // IMatRenderContext
constexpr size_t kQueueStack = 0x10;        // CMatCallQueue: head, tail, then the element stack
constexpr ptrdiff_t kQueueStackSize = 0x1000000;

struct QueueElem {
	QueueElem* next;
	void* functor;
};

void* g_materials = nullptr;
int g_queueLayout = 0;  // 0 not checked yet, 1 recognised, -1 not
std::vector<std::function<void()>> g_jobs;  // waiting for the next flush
// Stats: jobs queued and run, and the thread the last one ran on (vs Lua's).
std::atomic<int> g_jobsQueued { 0 }, g_jobsRun { 0 };
std::atomic<DWORD> g_jobThread { 0 };
DWORD g_luaThread = 0;

template <typename R, typename... A>
R vcall(void* object, int slot, A... args) {
	using Fn = R (*)(void*, A...);
	return (*reinterpret_cast<Fn**>(object))[slot](object, args...);
}

// Laid out like tier1's CFunctor: IRefCounted (AddRef, Release), virtual destructor,
// operator(), user id. Only operator() is called.
class RenderJob {
public:
	explicit RenderJob(std::vector<std::function<void()>>&& fns) : fns_(std::move(fns)) {}
	virtual int AddRef() { return 1; }
	virtual int Release() { return 1; }
	virtual ~RenderJob() = default;
	virtual void operator()() {
		for (auto& fn : fns_) fn();
		g_jobThread = GetCurrentThreadId();
		++g_jobsRun;
		delete this;
	}
	unsigned userId = 0;

private:
	std::vector<std::function<void()>> fns_;
};

// Looks for code in a module's executable sections; -1 in the pattern matches any byte.
bool findCode(HMODULE module, const std::vector<int>& pattern) {
	auto* base = reinterpret_cast<const uint8_t*>(module);
	auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(base + reinterpret_cast<const IMAGE_DOS_HEADER*>(base)->e_lfanew);
	const IMAGE_SECTION_HEADER* sec = IMAGE_FIRST_SECTION(nt);
	for (int s = 0; s < nt->FileHeader.NumberOfSections; ++s, ++sec) {
		if (!(sec->Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
		const uint8_t* p = base + sec->VirtualAddress;
		size_t n = sec->Misc.VirtualSize;
		for (size_t k = 0; k + pattern.size() <= n; ++k) {
			size_t j = 0;
			while (j < pattern.size() && (pattern[j] < 0 || p[k + j] == pattern[j])) ++j;
			if (j == pattern.size()) return true;
		}
	}
	return false;
}

void pushLe32(std::vector<int>& v, uint32_t x) {
	for (int i = 0; i < 4; ++i) v.push_back(static_cast<int>((x >> (8 * i)) & 0xFF));
}

// The queue sits where the queued context's GetCallQueue says, elements are appended as
// the material system's own inlined QueueCall does, and the render thread runs and then
// resets them as expected.
bool queueLayoutOk(void* rc, char* queue) {
	auto* getQueue = (*reinterpret_cast<const uint8_t***>(rc))[kSlotGetCallQueue];
	if (getQueue[0] != 0x48 || getQueue[1] != 0x8D || getQueue[2] != 0x81 || getQueue[7] != 0xC3) return false;
	uint32_t q;
	std::memcpy(&q, getQueue + 3, 4);  // lea rax, [rcx + q]; ret
	if (queue != static_cast<char*>(rc) + q) return false;
	HMODULE ms = GetModuleHandleW(L"materialsystem.dll");
	// lea rdx,[r10+10h] ... mov rcx,[rdx]; bounds check against 1000000h; bump by 10h;
	// link at the tail ([r10+8]) or the head ([r10]); elem = { 0, functor }
	const std::vector<int> append = {
		0x49, 0x8D, 0x52, 0x10, -1, -1, -1, -1, 0x48, 0x8B, 0x0A, 0x48, 0x8B, 0xC1, 0x48, 0x2B,
		0xC2, 0x48, 0x83, 0xC0, 0x08, 0x48, 0x3D, 0x00, 0x00, 0x00, 0x01, 0x77, -1, 0x48, 0x8D, 0x41,
		0x10, 0x48, 0x89, 0x02, 0x48, 0x85, 0xC9, 0x74, -1, 0x49, 0x8B, 0x42, 0x08, 0x48, 0x85, 0xC0,
		0x74, -1, 0x48, 0x89, 0x08, 0x49, 0x89, 0x4A, 0x08, 0x48, 0xC7, 0x01, 0x00, 0x00, 0x00, 0x00,
		0x4C, 0x89, 0x49, 0x08, 0xC3, 0x49, 0x89, 0x0A, 0x49, 0x89, 0x4A, 0x08, 0x48, 0xC7, 0x01, 0x00,
		0x00, 0x00, 0x00, 0x4C, 0x89, 0x49, 0x08, 0xC3,
	};
	// mov rcx,[rbx+8]; mov rax,[rcx]; call [rax+18h]; mov rbx,[rbx]; test rbx,rbx; jne;
	// then tail = 0, stack = its start, head = 0
	std::vector<int> runner = {
		0x48, 0x8B, 0x4B, 0x08, 0x48, 0x8B, 0x01, 0xFF, 0x50, 0x18, 0x48, 0x8B, 0x1B, 0x48, 0x85, 0xDB,
		0x75, -1, 0x48, 0x8D, 0x87,
	};
	pushLe32(runner, q + 0x18);
	runner.insert(runner.end(), { 0x4C, 0x89, 0xA7 });
	pushLe32(runner, q + 0x08);
	runner.insert(runner.end(), { 0x48, 0x89, 0x87 });
	pushLe32(runner, q + 0x10);
	runner.insert(runner.end(), { 0x4C, 0x89, 0xA7 });
	pushLe32(runner, q);
	return ms && findCode(ms, append) && findCode(ms, runner);
}

bool initMaterials() {
	if (!g_materials) {
		HMODULE ms = GetModuleHandleW(L"materialsystem.dll");
		using CreateInterfaceFn = void* (*)(const char*, int*);
		auto ci = ms ? reinterpret_cast<CreateInterfaceFn>(GetProcAddress(ms, "CreateInterface")) : nullptr;
		g_materials = ci ? ci("VMaterialSystem080", nullptr) : nullptr;
		if (!g_materials) {
			g_initError = "the material system interface (VMaterialSystem080) was not found";
			return false;
		}
	}
	// check the queue now if the material system is threaded (otherwise on first use)
	void* rc = vcall<void*>(g_materials, kSlotGetRenderContext);
	char* queue = rc ? vcall<char*>(rc, kSlotGetCallQueue) : nullptr;
	if (queue && g_queueLayout == 0) g_queueLayout = queueLayoutOk(rc, queue) ? 1 : -1;
	if (g_queueLayout < 0) {
		g_initError = "this build of GMod's material system is not recognised (render queue layout)";
		return false;
	}
	return true;
}

// Runs fn on the thread that drives D3D9, at the next flush.
void onRenderThread(std::function<void()> fn) {
	g_jobs.push_back(std::move(fn));
}

// Hands the waiting jobs to the render thread as one job, queued behind the frame being
// built, or runs them here when the material system is not threaded (Lua is then the
// render thread). Called while the frame is being drawn, when the queue takes calls.
// False if the queue cannot be used.
bool flushJobs() {
	if (g_jobs.empty()) return g_queueLayout >= 0;
	void* rc = g_materials ? vcall<void*>(g_materials, kSlotGetRenderContext) : nullptr;
	char* queue = rc ? vcall<char*>(rc, kSlotGetCallQueue) : nullptr;
	if (!queue) {
		std::vector<std::function<void()>> jobs;
		jobs.swap(g_jobs);
		for (auto& fn : jobs) fn();
		return true;
	}
	if (g_queueLayout == 0) g_queueLayout = queueLayoutOk(rc, queue) ? 1 : -1;
	if (g_queueLayout < 0) return false;
	char** stack = reinterpret_cast<char**>(queue + kQueueStack);
	char* e = *stack;
	if (!e || (e - reinterpret_cast<char*>(stack)) + 8 > kQueueStackSize) return true;  // full: next frame
	*stack = e + sizeof(QueueElem);
	auto* elem = reinterpret_cast<QueueElem*>(e);
	elem->next = nullptr;
	elem->functor = new RenderJob(std::move(g_jobs));
	g_jobs.clear();
	auto** head = reinterpret_cast<QueueElem**>(queue);
	auto** tail = reinterpret_cast<QueueElem**>(queue + 8);
	if (*tail) (*tail)->next = elem;
	else *head = elem;
	*tail = elem;
	++g_jobsQueued;
	return true;
}

// Queued jobs run after Lua may have closed this module, so it stays loaded for the
// life of the game (it is reused, state and all, by the next map's Lua state).
void pinModule() {
	HMODULE self = nullptr;
	GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
	                   reinterpret_cast<LPCWSTR>(&pinModule), &self);
}

std::wstring widen(const std::string& s) {
	if (s.empty()) return {};
	int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), nullptr, 0);
	std::wstring w(n, L'\0');
	MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), w.data(), n);
	return w;
}

// Game root (the folder above bin\win64\gmod.exe); texture paths are relative to it.
std::wstring gameRoot() {
	wchar_t buf[MAX_PATH] {};
	GetModuleFileNameW(nullptr, buf, MAX_PATH);
	std::wstring p(buf);
	for (int up = 0; up < 3; ++up) {
		size_t s = p.find_last_of(L"\\/");
		if (s == std::wstring::npos) break;
		p.resize(s);
	}
	return p;
}

// ---------------------------------------------------------------- polygons

using Poly = std::vector<float>;  // x1, y1, x2, y2, ... counter-clockwise

float area(const Poly& p) {
	size_t n = p.size();
	float a = 0, px = p[n - 2], py = p[n - 1];
	for (size_t k = 0; k < n; k += 2) {
		a += px * p[k + 1] - p[k] * py;
		px = p[k];
		py = p[k + 1];
	}
	return a * 0.5f;
}

// Sutherland-Hodgman against a convex counter-clockwise polygon.
Poly clip(const Poly& subject, const Poly& poly) {
	Poly out = subject;
	size_t n = poly.size();
	for (size_t i = 0; i < n && !out.empty(); i += 2) {
		size_t j = (i + 2 >= n) ? 0 : i + 2;
		float ax = poly[i], ay = poly[i + 1];
		float ex = poly[j] - ax, ey = poly[j + 1] - ay;
		Poly in;
		in.swap(out);
		size_t m = in.size();
		float px = in[m - 2], py = in[m - 1];
		float dp = ex * (py - ay) - ey * (px - ax);
		for (size_t k = 0; k < m; k += 2) {
			float qx = in[k], qy = in[k + 1];
			float dq = ex * (qy - ay) - ey * (qx - ax);
			if ((dq >= -1e-6f) != (dp >= -1e-6f)) {
				float t = dp / (dp - dq);
				out.push_back(px + (qx - px) * t);
				out.push_back(py + (qy - py) * t);
			}
			if (dq >= -1e-6f) {
				out.push_back(qx);
				out.push_back(qy);
			}
			px = qx; py = qy; dp = dq;
		}
	}
	return out;
}

bool inside(const Poly& p, float x, float y) {
	size_t n = p.size();
	float px = p[n - 2], py = p[n - 1];
	for (size_t k = 0; k < n; k += 2) {
		float qx = p[k], qy = p[k + 1];
		if ((qx - px) * (y - py) - (qy - py) * (x - px) < -1e-6f) return false;
		px = qx; py = qy;
	}
	return true;
}

// ---------------------------------------------------------------- water layout

struct CellLayout {
	int n = 0;
	std::vector<uint8_t> full;         // n*n, 1 = cell wholly on the water
	int nfull = 0;
	struct Part { int i, j; std::vector<Poly> polys; };
	std::vector<Part> parts;           // cells on the water's edge
	int partVerts = 0, partTris = 0;
};

struct Tile {
	int gx = 0, gy = 0, plane = 0, block = 0;
	float x0 = 0, y0 = 0;
	std::vector<Poly> pieces;
	bool full = false;
	// drawn with waves
	bool active = false;
	int keep = 0, n = 0;
	float dist = 0, score = 0;
	std::unique_ptr<CellLayout> cells[6];  // by log2(n)
};

struct Block {
	int plane = 0;
	float z = 0;
	std::vector<int> tiles;
	remixapi_MeshHandle full = nullptr, part = nullptr;
	remixapi_PersistentInstanceHandle inst = 0;
	remixapi_MeshHandle shown = nullptr;
	int active = 0;
	bool dirty = false;
};

struct Plane {
	float z = 0;
	std::unordered_map<int64_t, int> tileAt;
};

// The water: owned by the worker while it updates, by the main thread (Lua) while it
// reshapes things; g_state guards it all.
std::mutex g_state;
std::vector<Plane> g_planes;
std::vector<Tile> g_tiles;
std::vector<Block> g_blocks;
std::vector<int> g_active;           // tiles drawn with waves
wave::Sim g_sim;
float g_repeatInv = 1.0f / 256.0f;

remixapi_MaterialHandle g_material = nullptr;
uint64_t g_materialHash = 0;
remixapi_MaterialHandle g_cameraMedium = nullptr;  // what the camera was last put in (main thread)
remixapi_InstanceCategoryFlags g_categories = 0;
remixapi_MeshHandle g_rippleMesh = nullptr;
remixapi_PersistentInstanceHandle g_rippleInst = 0;

// Meshes waiting to be destroyed (filled under g_state, emptied by Flush).
struct Grave { int due; remixapi_MeshHandle mesh; };
std::mutex g_graveMutex;
std::deque<Grave> g_graves;
std::atomic<int> g_frames { 0 };  // frames seen by Flush
int g_lastFrame = -1;

struct Stats {
	int verts = 0, tiles = 0, simTiles = 0, simSteps = 0, bodies = 0, staticMeshes = 0, tilesTotal = 0;
	double ms = 0, simMs = 0;
};
Stats g_stats;  // under g_state
std::mutex g_statsMutex;
Stats g_published;  // copy for the main thread, under g_statsMutex

void publishStats() {
	std::lock_guard lock(g_statsMutex);
	g_published = g_stats;
}

int64_t key(int gx, int gy) { return (static_cast<int64_t>(gx) << 32) ^ static_cast<uint32_t>(gy); }

int log2i(int n) { int k = 0; while ((1 << k) < n && k < 5) ++k; return k; }

const CellLayout& layout(Tile& t, int n) {
	auto& slot = t.cells[log2i(n)];
	if (slot && slot->n == n) return *slot;
	slot = std::make_unique<CellLayout>();
	CellLayout& c = *slot;
	c.n = n;
	c.full.assign(static_cast<size_t>(n) * n, 0);
	float cs = kTile / n;
	for (int j = 0; j < n; ++j) {
		for (int i = 0; i < n; ++i) {
			float x0 = t.x0 + i * cs, y0 = t.y0 + j * cs;
			bool whole = t.full;
			if (!whole) {
				for (const Poly& p : t.pieces) {
					if (inside(p, x0, y0) && inside(p, x0 + cs, y0) && inside(p, x0 + cs, y0 + cs) && inside(p, x0, y0 + cs)) {
						whole = true;
						break;
					}
				}
			}
			if (whole) {
				c.full[static_cast<size_t>(j) * n + i] = 1;
				++c.nfull;
				continue;
			}
			Poly sq { x0, y0, x0 + cs, y0, x0 + cs, y0 + cs, x0, y0 + cs };
			CellLayout::Part part { i, j, {} };
			for (const Poly& p : t.pieces) {
				Poly q = clip(sq, p);
				if (q.size() >= 6 && area(q) > 0.01f) {
					c.partVerts += static_cast<int>(q.size() / 2);
					c.partTris += static_cast<int>(q.size() / 2 - 2);
					part.polys.push_back(std::move(q));
				}
			}
			if (!part.polys.empty()) c.parts.push_back(std::move(part));
		}
	}
	return c;
}

// ---------------------------------------------------------------- meshes

remixapi_HardcodedVertex vert(float x, float y, float z, float nx, float ny, float nz) {
	remixapi_HardcodedVertex v {};
	v.position[0] = x; v.position[1] = y; v.position[2] = z;
	v.normal[0] = nx; v.normal[1] = ny; v.normal[2] = nz;
	v.texcoord[0] = x * g_repeatInv;
	v.texcoord[1] = y * g_repeatInv;
	v.color = 0xFFFFFFFFu;
	return v;
}

remixapi_MeshHandle createMesh(const std::vector<remixapi_HardcodedVertex>& v, const std::vector<uint32_t>& idx) {
	if (!g_apiOk || !g_material || v.empty() || idx.empty()) return nullptr;
	remixapi_MeshInfoSurfaceTriangles surf {};
	surf.vertices_values = v.data();
	surf.vertices_count = v.size();
	surf.indices_values = idx.data();
	surf.indices_count = idx.size();
	surf.skinning_hasvalue = 0;
	surf.material = g_material;
	remixapi_MeshInfo info {};
	info.sType = REMIXAPI_STRUCT_TYPE_MESH_INFO;
	info.hash = nextHash();
	info.surfaces_values = &surf;
	info.surfaces_count = 1;
	remixapi_MeshHandle h = nullptr;
	if (g_api.CreateMeshBatched(&info, &h) != REMIXAPI_ERROR_CODE_SUCCESS) return nullptr;
	return h;
}

void bury(remixapi_MeshHandle m) {
	if (!m) return;
	std::lock_guard lock(g_graveMutex);
	g_graves.push_back({ g_frames + kGraveDelay, m });
}

// Destroys the meshes whose instances have moved on, in a render-thread job. Graves left
// at shutdown are kept (the module stays loaded) and reaped in the next map's frames: a
// mesh made in the last frame may still be waiting to be created.
void reap() {
	std::vector<remixapi_MeshHandle> due;
	{
		std::lock_guard lock(g_graveMutex);
		while (!g_graves.empty() && g_graves.front().due <= g_frames) {
			due.push_back(g_graves.front().mesh);
			g_graves.pop_front();
		}
	}
	if (due.empty() || !g_apiOk) return;
	onRenderThread([due = std::move(due)] {
		for (remixapi_MeshHandle m : due) g_api.DestroyMesh(m);
	});
}

remixapi_InstanceInfo instanceInfo(remixapi_MeshHandle mesh) {
	remixapi_InstanceInfo info {};
	info.sType = REMIXAPI_STRUCT_TYPE_INSTANCE_INFO;
	info.categoryFlags = g_categories;
	info.mesh = mesh;
	info.transform.matrix[0][0] = info.transform.matrix[1][1] = info.transform.matrix[2][2] = 1.0f;
	info.doubleSided = 1;
	return info;
}

// Point a persistent instance at a mesh, creating or destroying it as needed.
void showMesh(remixapi_PersistentInstanceHandle& inst, remixapi_MeshHandle mesh) {
	if (!mesh) {
		if (inst) { g_destroyInst(inst); inst = 0; }
		return;
	}
	remixapi_InstanceInfo info = instanceInfo(mesh);
	if (inst) g_updateInst(inst, &info);
	else g_createInst(&info, &inst);
}

remixapi_MeshHandle flatBlockMesh(const Block& b, bool skipActive) {
	std::vector<remixapi_HardcodedVertex> v;
	std::vector<uint32_t> idx;
	for (int ti : b.tiles) {
		const Tile& t = g_tiles[ti];
		if (skipActive && t.active) continue;
		for (const Poly& p : t.pieces) {
			uint32_t base = static_cast<uint32_t>(v.size());
			uint32_t m = static_cast<uint32_t>(p.size() / 2);
			for (uint32_t k = 0; k < m; ++k) v.push_back(vert(p[2 * k], p[2 * k + 1], b.z, 0, 0, 1));
			for (uint32_t k = 1; k + 1 < m; ++k) {  // fan, reversed: clockwise from above
				idx.push_back(base);
				idx.push_back(base + k + 1);
				idx.push_back(base + k);
			}
		}
	}
	return createMesh(v, idx);
}

void destroyStatic() {
	for (Block& b : g_blocks) {
		if (b.inst && g_apiOk) g_destroyInst(b.inst);
		b.inst = 0;
		bury(b.full);
		bury(b.part);
		b.full = b.part = b.shown = nullptr;
	}
}

void buildStatic() {
	destroyStatic();
	int n = 0;
	for (Block& b : g_blocks) {
		b.full = flatBlockMesh(b, false);
		b.part = nullptr;
		b.dirty = b.active > 0;
		b.shown = b.active > 0 ? nullptr : b.full;
		if (b.shown) showMesh(b.inst, b.shown);
		if (b.full) ++n;
	}
	g_stats.staticMeshes = n;
}

void refreshInstances() {
	for (Block& b : g_blocks)
		if (b.inst && b.shown) showMesh(b.inst, b.shown);
	if (g_rippleInst && g_rippleMesh) showMesh(g_rippleInst, g_rippleMesh);
}

// Puts the camera inside a translucent material from the next frame on, or outside any
// (nullptr). Remix copies the material's values when it is called.
void setCameraMedium(remixapi_MaterialHandle m) {
	g_cameraMedium = m;
	if (!g_apiOk || !g_api.SetCameraMediumMaterial) return;
	onRenderThread([m] {
		remixapi_CameraMediumInfo info {};
		info.sType = REMIXAPI_STRUCT_TYPE_CAMERA_MEDIUM_INFO;
		info.medium = m;
		g_api.SetCameraMediumMaterial(&info);
	});
}

// ---------------------------------------------------------------- waves

struct View { float ex, ey, ez, fx, fy, fz, cosView; int n; int budget; float nearD, farD; };

int g_stamp = 0;

// Simulated tiles with visible waves, near the camera and roughly in view, most important
// first within the vertex budget; the rest stay in the flat block meshes.
void selectTiles(const View& v, std::vector<int>& out) {
	std::vector<int> sim, keep;
	g_sim.simulatedTiles(sim);
	for (int ti : sim) {
		Tile& t = g_tiles[ti];
		float amp = g_sim.amplitude(ti);
		if (amp < (t.active ? kAmpMin * 0.5f : kAmpMin)) continue;  // hysteresis
		float dx = t.x0 + kTile * 0.5f - v.ex, dy = t.y0 + kTile * 0.5f - v.ey, dz = g_planes[t.plane].z - v.ez;
		float d = std::sqrt(dx * dx + dy * dy + dz * dz);
		if (d >= v.farD) continue;
		if (d > kTile * 2 && dx * v.fx + dy * v.fy + dz * v.fz <= v.cosView * d) continue;
		t.dist = d;
		t.score = amp / (d + 150);
		keep.push_back(ti);
	}
	std::sort(keep.begin(), keep.end(), [](int a, int b) { return g_tiles[a].score > g_tiles[b].score; });
	int used = 0;
	out.clear();
	for (int ti : keep) {
		Tile& t = g_tiles[ti];
		int n = t.dist < v.nearD ? v.n : std::max(2, v.n / 2);
		const CellLayout& c = layout(t, n);
		int cost = (n + 1) * (n + 1) + c.partVerts;
		if (used + cost > v.budget) continue;
		t.n = n;
		used += cost;
		out.push_back(ti);
	}
}

void setActive(const std::vector<int>& list) {
	++g_stamp;
	for (int ti : list) g_tiles[ti].keep = g_stamp;
	for (int ti : g_active) {
		Tile& t = g_tiles[ti];
		if (t.keep != g_stamp) {
			t.active = false;
			Block& b = g_blocks[t.block];
			--b.active;
			b.dirty = true;
		}
	}
	for (int ti : list) {
		Tile& t = g_tiles[ti];
		if (!t.active) {
			t.active = true;
			Block& b = g_blocks[t.block];
			++b.active;
			b.dirty = true;
		}
	}
	g_active = list;
}

// Static blocks whose set of rippling tiles changed get a mesh without those tiles.
void refreshBlocks() {
	for (Block& b : g_blocks) {
		if (!b.dirty) continue;
		b.dirty = false;
		bury(b.part);
		b.part = nullptr;
		if (b.active > 0) b.part = flatBlockMesh(b, true);
		b.shown = b.active > 0 ? b.part : b.full;
		showMesh(b.inst, b.shown);
	}
}

std::vector<float> g_h, g_nx, g_ny, g_nz;

// Heights and normals of a tile's (n + 1)^2 nodes, from the simulation.
void sampleTile(int ti, int n) {
	size_t cnt = static_cast<size_t>(n + 1) * (n + 1);
	if (g_h.size() < cnt) { g_h.resize(cnt); g_nx.resize(cnt); g_ny.resize(cnt); g_nz.resize(cnt); }
	g_sim.sampleNodes(ti, n, g_h.data(), g_nx.data(), g_ny.data());
	for (size_t k = 0; k < cnt; ++k) {
		float sx = g_nx[k], sy = g_ny[k];
		float inv = 1.0f / std::sqrt(sx * sx + sy * sy + 1);
		g_nx[k] = -sx * inv;
		g_ny[k] = -sy * inv;
		g_nz[k] = inv;
	}
}

std::vector<remixapi_HardcodedVertex> g_rv;
std::vector<uint32_t> g_ri;

void buildRipples() {
	g_rv.clear();
	g_ri.clear();
	for (int ti : g_active) {
		Tile& t = g_tiles[ti];
		int n = t.n;
		const CellLayout& c = layout(t, n);
		sampleTile(ti, n);
		float cs = kTile / n;
		float z = g_planes[t.plane].z;
		int row = n + 1;
		uint32_t base = static_cast<uint32_t>(g_rv.size());
		for (int j = 0; j <= n; ++j)
			for (int i = 0; i <= n; ++i) {
				size_t k = static_cast<size_t>(j) * row + i;
				g_rv.push_back(vert(t.x0 + i * cs, t.y0 + j * cs, z + g_h[k], g_nx[k], g_ny[k], g_nz[k]));
			}
		for (int j = 0; j < n; ++j)
			for (int i = 0; i < n; ++i) {
				if (!c.full[static_cast<size_t>(j) * n + i]) continue;
				uint32_t a = base + j * row + i, b = a + 1, cc = a + row, d = cc + 1;
				// clockwise from above: (a, c, d) and (a, d, b)
				g_ri.push_back(a); g_ri.push_back(cc); g_ri.push_back(d);
				g_ri.push_back(a); g_ri.push_back(d); g_ri.push_back(b);
			}
		// edge cells: clipped polygons, heights and normals interpolated from the nodes
		for (const auto& part : c.parts) {
			for (const Poly& p : part.polys) {
				uint32_t pb = static_cast<uint32_t>(g_rv.size());
				uint32_t m = static_cast<uint32_t>(p.size() / 2);
				for (uint32_t q = 0; q < m; ++q) {
					float x = p[2 * q], y = p[2 * q + 1];
					float fx = std::clamp((x - t.x0) / cs - part.i, 0.0f, 1.0f);
					float fy = std::clamp((y - t.y0) / cs - part.j, 0.0f, 1.0f);
					size_t a = static_cast<size_t>(part.j) * row + part.i, b = a + 1, cc = a + row, d = cc + 1;
					float w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy;
					float hh = g_h[a] * w00 + g_h[b] * w10 + g_h[cc] * w01 + g_h[d] * w11;
					float nx = g_nx[a] * w00 + g_nx[b] * w10 + g_nx[cc] * w01 + g_nx[d] * w11;
					float ny = g_ny[a] * w00 + g_ny[b] * w10 + g_ny[cc] * w01 + g_ny[d] * w11;
					float nz = g_nz[a] * w00 + g_nz[b] * w10 + g_nz[cc] * w01 + g_nz[d] * w11;
					float l = 1.0f / std::sqrt(nx * nx + ny * ny + nz * nz);
					g_rv.push_back(vert(x, y, z + hh, nx * l, ny * l, nz * l));
				}
				for (uint32_t q = 1; q + 1 < m; ++q) {
					g_ri.push_back(pb);
					g_ri.push_back(pb + q + 1);
					g_ri.push_back(pb + q);
				}
			}
		}
	}
	remixapi_MeshHandle mesh = g_ri.empty() ? nullptr : createMesh(g_rv, g_ri);
	showMesh(g_rippleInst, mesh);
	bury(g_rippleMesh);
	g_rippleMesh = mesh;
}

void clearRipples() {
	g_sim.clear();
	setActive({});
	refreshBlocks();
	if (g_rippleInst && g_apiOk) g_destroyInst(g_rippleInst);
	g_rippleInst = 0;
	bury(g_rippleMesh);
	g_rippleMesh = nullptr;
}

void destroyAll() {
	clearRipples();
	destroyStatic();
	if (g_cameraMedium) setCameraMedium(nullptr);  // out of the water before it goes
	if (g_material && g_apiOk) {
		remixapi_MaterialHandle m = g_material;
		onRenderThread([m] { g_api.DestroyMaterial(m); });
	}
	g_material = nullptr;
	g_planes.clear();
	g_tiles.clear();
	g_blocks.clear();
	g_active.clear();
	g_sim.setSurface({}, {});
	g_stats = Stats {};
	publishStats();
}

// ---------------------------------------------------------------- worker

struct Request {
	double now;
	View view;
};

// What Lua sent since the last update: body samples (each a snapshot of all bodies) and
// impulses.
struct Input {
	std::vector<std::pair<double, std::vector<wave::BodyInput>>> bodies;
	struct Impulse { int plane; float x, y, depth, radius; };
	std::vector<Impulse> impulses;
};

std::mutex g_requestMutex;  // the request and the input gathered since the last update
std::condition_variable g_requestCv;
std::optional<Request> g_request;  // the latest view: an update still running skips the ones in between
Input g_input;
bool g_quit = false;
// never destroyed: a joinable std::thread left at process exit would call std::terminate
std::thread* g_worker = nullptr;

void runUpdate(const Request& req, Input& in) {
	LARGE_INTEGER f, t0, t1;
	QueryPerformanceFrequency(&f);
	QueryPerformanceCounter(&t0);
	for (auto& b : in.bodies) g_sim.setBodies(b.first, std::move(b.second));
	for (const Input::Impulse& im : in.impulses) g_sim.addImpulse(im.plane, im.x, im.y, im.depth, im.radius);
	if (g_apiOk && g_material) {
		g_sim.advance(req.now);
		std::vector<int> list;
		selectTiles(req.view, list);
		setActive(list);
		refreshBlocks();
		if (!g_active.empty() || g_rippleMesh) buildRipples();
	}
	QueryPerformanceCounter(&t1);
	wave::Stats ss = g_sim.stats();
	g_stats.ms = (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart;
	g_stats.simMs = ss.ms;
	g_stats.simTiles = ss.tiles;
	g_stats.simSteps = ss.steps;
	g_stats.bodies = ss.bodies;
	g_stats.verts = g_active.empty() ? 0 : static_cast<int>(g_rv.size());
	g_stats.tiles = static_cast<int>(g_active.size());
	publishStats();
}

void workerMain() {
	for (;;) {
		Request req;
		Input in;
		{
			std::unique_lock lock(g_requestMutex);
			g_requestCv.wait(lock, [] { return g_quit || g_request.has_value(); });
			if (g_quit) return;
			req = *g_request;
			g_request.reset();
			std::swap(in, g_input);
		}
		std::lock_guard state(g_state);
		runUpdate(req, in);
	}
}

void startWorker() {
	if (g_worker) return;
	{
		std::lock_guard lock(g_requestMutex);
		g_quit = false;
	}
	g_worker = new std::thread(workerMain);
}

void stopWorker() {
	if (!g_worker) return;
	{
		std::lock_guard lock(g_requestMutex);
		g_quit = true;
	}
	g_requestCv.notify_all();
	g_worker->join();
	delete g_worker;
	g_worker = nullptr;
}

// Forgets input not yet picked up by the worker.
void dropRequests() {
	std::lock_guard lock(g_requestMutex);
	g_request.reset();
	g_input = Input {};
}

// ---------------------------------------------------------------- Lua helpers

double field(ILuaBase* L, int t, const char* name, double def) {
	L->GetField(t, name);
	double v = L->IsType(-1, Type::Number) ? L->GetNumber(-1) : def;
	L->Pop();
	return v;
}

std::string fieldStr(ILuaBase* L, int t, const char* name) {
	L->GetField(t, name);
	std::string v = L->IsType(-1, Type::String) ? L->GetString(-1) : "";
	L->Pop();
	return v;
}

bool fieldBool(ILuaBase* L, int t, const char* name, bool def) {
	L->GetField(t, name);
	bool v = L->IsType(-1, Type::Bool) ? L->GetBool(-1) : def;
	L->Pop();
	return v;
}

// ---------------------------------------------------------------- Lua functions

LUA_FUNCTION(Native_Init) {
	bool ok = initApi() && initMaterials();
	if (ok) startWorker();
	LUA->PushBool(ok);
	LUA->PushString(ok ? "" : g_initError.c_str());
	return 2;
}

// SetMaterial{ color = {r, g, b}, distance, ior, normal = "rel/path.dds", diffuse = "rel/path.dds", animated }
// Texture paths are relative to the game folder. Meshes refer to the material by
// handle, so re-creating it under the same handle restyles all water in place.
LUA_FUNCTION(Native_SetMaterial) {
	if (!g_apiOk) { LUA->PushBool(false); return 1; }
	LUA->CheckType(1, Type::Table);
	double r = 0.62, g = 0.89, b = 0.97;
	LUA->GetField(1, "color");
	if (LUA->IsType(-1, Type::Table)) {
		LUA->PushNumber(1); LUA->GetTable(-2); r = LUA->GetNumber(-1); LUA->Pop();
		LUA->PushNumber(2); LUA->GetTable(-2); g = LUA->GetNumber(-1); LUA->Pop();
		LUA->PushNumber(3); LUA->GetTable(-2); b = LUA->GetNumber(-1); LUA->Pop();
	}
	LUA->Pop();
	float distance = static_cast<float>(field(LUA, 1, "distance", 150));
	float ior = static_cast<float>(field(LUA, 1, "ior", 1.333));
	std::wstring root = gameRoot() + L"\\";
	std::string normalRel = fieldStr(LUA, 1, "normal"), diffuseRel = fieldStr(LUA, 1, "diffuse");
	std::wstring normal = normalRel.empty() ? L"" : root + widen(normalRel);
	std::wstring diffuse = diffuseRel.empty() ? L"" : root + widen(diffuseRel);
	bool animated = fieldBool(LUA, 1, "animated", false);

	std::lock_guard state(g_state);
	// The handle is the hash, so meshes can be made against it before the render thread
	// has created the material.
	if (!g_materialHash) g_materialHash = nextHash();
	remixapi_MaterialHandle h = reinterpret_cast<remixapi_MaterialHandle>(g_materialHash);
	bool replace = g_material != nullptr;
	onRenderThread([=, normal = std::move(normal), diffuse = std::move(diffuse)] {
		remixapi_MaterialInfoTranslucentEXT tr {};
		tr.sType = REMIXAPI_STRUCT_TYPE_MATERIAL_INFO_TRANSLUCENT_EXT;
		tr.transmittanceTexture = diffuse.empty() ? nullptr : diffuse.c_str();
		tr.refractiveIndex = ior;
		tr.transmittanceColor = { static_cast<float>(r), static_cast<float>(g), static_cast<float>(b) };
		tr.transmittanceMeasurementDistance = distance;
		tr.thinWallThickness_hasvalue = 0;
		tr.useDiffuseLayer = diffuse.empty() ? 0 : 1;
		remixapi_MaterialInfo info {};
		info.sType = REMIXAPI_STRUCT_TYPE_MATERIAL_INFO;
		info.pNext = &tr;
		info.hash = g_materialHash;
		info.normalTexture = normal.empty() ? nullptr : normal.c_str();
		info.emissiveIntensity = 0;
		info.spriteSheetRow = info.spriteSheetCol = 1;  // animated water samples through the sprite-sheet maths
		info.filterMode = 1;
		info.wrapModeU = info.wrapModeV = 1;  // repeat
		if (replace) g_api.DestroyMaterial(h);
		remixapi_MaterialHandle created = nullptr;
		g_api.CreateMaterial(&info, &created);
	});
	bool first = g_material == nullptr;
	g_material = h;
	remixapi_InstanceCategoryFlags cats = animated ? REMIXAPI_INSTANCE_CATEGORY_BIT_ANIMATED_WATER : 0;
	if (cats != g_categories) {
		g_categories = cats;
		refreshInstances();
	}
	if (first && !g_blocks.empty()) buildStatic();
	publishStats();
	LUA->PushBool(true);
	return 1;
}

// SetSurface(planes, repeatUnits): planes = { { z = z, polys = { {x1, y1, ...}, ... } }, ... }
// (polygons counter-clockwise from above). Returns the tile count.
LUA_FUNCTION(Native_SetSurface) {
	LUA->CheckType(1, Type::Table);
	dropRequests();
	std::lock_guard state(g_state);
	clearRipples();
	destroyStatic();
	g_planes.clear();
	g_tiles.clear();
	g_blocks.clear();
	g_active.clear();
	g_repeatInv = 1.0f / static_cast<float>(std::max(1.0, LUA->IsType(2, Type::Number) ? LUA->GetNumber(2) : 256.0));
	int np = LUA->ObjLen(1);
	std::unordered_map<int64_t, int> blockAt;
	for (int pi = 1; pi <= np; ++pi) {
		LUA->PushNumber(pi);
		LUA->GetTable(1);
		int pt = LUA->Top();
		Plane plane;
		plane.z = static_cast<float>(field(LUA, pt, "z", 0));
		int planeIndex = static_cast<int>(g_planes.size());
		g_planes.push_back(plane);
		blockAt.clear();
		LUA->GetField(pt, "polys");
		int polysIdx = LUA->Top();
		int npoly = LUA->IsType(polysIdx, Type::Table) ? LUA->ObjLen(polysIdx) : 0;
		for (int k = 1; k <= npoly; ++k) {
			LUA->PushNumber(k);
			LUA->GetTable(polysIdx);
			int polyIdx = LUA->Top();
			Poly poly;
			int nv = LUA->ObjLen(polyIdx);
			poly.reserve(nv);
			for (int q = 1; q <= nv; ++q) {
				LUA->PushNumber(q);
				LUA->GetTable(polyIdx);
				poly.push_back(static_cast<float>(LUA->GetNumber(-1)));
				LUA->Pop();
			}
			LUA->Pop();
			if (poly.size() < 6) continue;
			float x0 = 1e30f, y0 = 1e30f, x1 = -1e30f, y1 = -1e30f;
			for (size_t q = 0; q < poly.size(); q += 2) {
				x0 = std::min(x0, poly[q]); x1 = std::max(x1, poly[q]);
				y0 = std::min(y0, poly[q + 1]); y1 = std::max(y1, poly[q + 1]);
			}
			for (int gx = static_cast<int>(std::floor(x0 / kTile)); gx <= static_cast<int>(std::floor((x1 - 1e-4f) / kTile)); ++gx) {
				for (int gy = static_cast<int>(std::floor(y0 / kTile)); gy <= static_cast<int>(std::floor((y1 - 1e-4f) / kTile)); ++gy) {
					float tx = gx * kTile, ty = gy * kTile;
					Poly piece = clip(Poly { tx, ty, tx + kTile, ty, tx + kTile, ty + kTile, tx, ty + kTile }, poly);
					if (piece.size() < 6 || area(piece) <= 0.05f) continue;
					Plane& pl = g_planes[planeIndex];
					auto it = pl.tileAt.find(key(gx, gy));
					int ti;
					if (it == pl.tileAt.end()) {
						int64_t bk = key(static_cast<int>(std::floor(gx / static_cast<float>(kBlock))), static_cast<int>(std::floor(gy / static_cast<float>(kBlock))));
						auto bit = blockAt.find(bk);
						int bi;
						if (bit == blockAt.end()) {
							bi = static_cast<int>(g_blocks.size());
							Block b;
							b.plane = planeIndex;
							b.z = pl.z;
							g_blocks.push_back(std::move(b));
							blockAt[bk] = bi;
						} else {
							bi = bit->second;
						}
						ti = static_cast<int>(g_tiles.size());
						Tile t;
						t.gx = gx; t.gy = gy; t.x0 = tx; t.y0 = ty; t.plane = planeIndex; t.block = bi;
						g_tiles.push_back(std::move(t));
						pl.tileAt[key(gx, gy)] = ti;
						g_blocks[bi].tiles.push_back(ti);
					} else {
						ti = it->second;
					}
					g_tiles[ti].pieces.push_back(std::move(piece));
				}
			}
		}
		LUA->Pop(2);  // polys, plane
	}
	for (Tile& t : g_tiles) t.full = t.pieces.size() == 1 && area(t.pieces[0]) >= kTile * kTile - 0.5f;
	// the simulation's nodes are on the water where any piece of their tile covers them
	std::vector<float> planeZ;
	for (const Plane& pl : g_planes) planeZ.push_back(pl.z);
	std::vector<wave::TileDesc> descs(g_tiles.size());
	for (size_t i = 0; i < g_tiles.size(); ++i) {
		const Tile& t = g_tiles[i];
		wave::TileDesc& d = descs[i];
		d.plane = t.plane;
		d.gx = t.gx;
		d.gy = t.gy;
		d.water.assign(wave::kN * wave::kN, t.full ? 1 : 0);
		if (t.full) continue;
		for (int ly = 0; ly < wave::kN; ++ly)
			for (int lx = 0; lx < wave::kN; ++lx) {
				float x = t.x0 + lx * wave::kCell, y = t.y0 + ly * wave::kCell;
				for (const Poly& p : t.pieces)
					if (inside(p, x, y)) {
						d.water[ly * wave::kN + lx] = 1;
						break;
					}
			}
	}
	g_sim.setSurface(planeZ, descs);
	if (g_material) buildStatic();
	g_stats.tilesTotal = static_cast<int>(g_tiles.size());
	publishStats();
	LUA->PushNumber(static_cast<double>(g_tiles.size()));
	return 1;
}

// SetRepeat(units): texture repeat of the wave pattern (rebuilds the static meshes)
LUA_FUNCTION(Native_SetRepeat) {
	float inv = 1.0f / static_cast<float>(std::max(1.0, LUA->CheckNumber(1)));
	std::lock_guard state(g_state);
	if (std::fabs(inv - g_repeatInv) > 1e-9f) {
		g_repeatInv = inv;
		if (g_material) buildStatic();
		publishStats();
	}
	return 0;
}

// SetShape(key, parts): parts = { {x1, y1, z1, x2, ...}, ... }, each a convex part as a
// triangle soup in the space of the matrix that places it (see SetBodies).
LUA_FUNCTION(Native_SetShape) {
	int key = static_cast<int>(LUA->CheckNumber(1));
	LUA->CheckType(2, Type::Table);
	std::vector<std::vector<float>> parts;
	int np = LUA->ObjLen(2);
	for (int i = 1; i <= np; ++i) {
		LUA->PushNumber(i);
		LUA->GetTable(2);
		std::vector<float> v;
		if (LUA->IsType(-1, Type::Table)) {
			int nv = LUA->ObjLen(-1);
			v.reserve(nv);
			for (int k = 1; k <= nv; ++k) {
				LUA->PushNumber(k);
				LUA->GetTable(-2);
				v.push_back(static_cast<float>(LUA->GetNumber(-1)));
				LUA->Pop();
			}
		}
		LUA->Pop();
		v.resize(v.size() - v.size() % 9);
		if (!v.empty()) parts.push_back(std::move(v));
	}
	std::lock_guard state(g_state);
	g_sim.setShape(key, parts);
	return 0;
}

// The data of a GMod VMatrix userdata (row-major 4 x 4 floats).
const float* matrixData(ILuaBase* L, int index) {
	return L->GetUserType<float>(index, Type::Matrix);
}

// SetBodies(time, bodies): bodies = { { entityIndex, shapeKey, matrix [, matrix ...] }, ... },
// one matrix placing every part of the shape or one per part. Every body in or near the
// water: those left out are gone.
LUA_FUNCTION(Native_SetBodies) {
	double time = LUA->CheckNumber(1);
	LUA->CheckType(2, Type::Table);
	std::vector<wave::BodyInput> bodies;
	int nb = LUA->ObjLen(2);
	bodies.reserve(nb);
	for (int i = 1; i <= nb; ++i) {
		LUA->PushNumber(i);
		LUA->GetTable(2);
		int bt = LUA->Top();
		if (LUA->IsType(bt, Type::Table)) {
			wave::BodyInput b;
			int n = LUA->ObjLen(bt);
			LUA->PushNumber(1); LUA->GetTable(bt); b.id = static_cast<int>(LUA->GetNumber(-1)); LUA->Pop();
			LUA->PushNumber(2); LUA->GetTable(bt); b.shape = static_cast<int>(LUA->GetNumber(-1)); LUA->Pop();
			for (int k = 3; k <= n; ++k) {
				LUA->PushNumber(k);
				LUA->GetTable(bt);
				if (const float* m = matrixData(LUA, -1)) {
					wave::Mat34 M;
					for (int r = 0; r < 3; ++r)
						for (int c = 0; c < 4; ++c) M.m[r][c] = m[r * 4 + c];
					b.parts.push_back(M);
				}
				LUA->Pop();
			}
			if (!b.parts.empty()) bodies.push_back(std::move(b));
		}
		LUA->Pop();
	}
	std::lock_guard lock(g_requestMutex);
	auto& queue = g_input.bodies;
	if (queue.size() >= 16) queue.erase(queue.begin());  // the worker is behind: keep the latest
	queue.emplace_back(time, std::move(bodies));
	return 0;
}

// AddImpulse(plane, x, y, depth, radius): a dent in the surface (bullets).
LUA_FUNCTION(Native_AddImpulse) {
	Input::Impulse im;
	im.plane = static_cast<int>(LUA->CheckNumber(1)) - 1;
	im.x = static_cast<float>(LUA->CheckNumber(2));
	im.y = static_cast<float>(LUA->CheckNumber(3));
	im.depth = static_cast<float>(LUA->CheckNumber(4));
	im.radius = static_cast<float>(LUA->CheckNumber(5));
	std::lock_guard lock(g_requestMutex);
	if (g_input.impulses.size() < kMaxImpulses) g_input.impulses.push_back(im);
	return 0;
}

// SetWaves{ damping, strength, headMax, tau, maxTiles }: simulation settings (missing ones
// stay as they are).
LUA_FUNCTION(Native_SetWaves) {
	LUA->CheckType(1, Type::Table);
	std::lock_guard state(g_state);
	wave::Settings& w = g_sim.settings;
	w.damping = static_cast<float>(field(LUA, 1, "damping", w.damping));
	w.strength = static_cast<float>(field(LUA, 1, "strength", w.strength));
	w.headMax = static_cast<float>(field(LUA, 1, "headMax", w.headMax));
	w.tau = static_cast<float>(field(LUA, 1, "tau", w.tau));
	w.maxTiles = static_cast<int>(field(LUA, 1, "maxTiles", w.maxTiles));
	return 0;
}

// Update(now, ex, ey, ez, fx, fy, fz, cosView, cellsPerTile, vertexBudget, near, far)
// Asks the worker for an update from this view and returns the last finished update's
// vertices, tiles and milliseconds (worker time).
LUA_FUNCTION(Native_Update) {
	double now = LUA->CheckNumber(1);
	View v;
	v.ex = static_cast<float>(LUA->CheckNumber(2)); v.ey = static_cast<float>(LUA->CheckNumber(3)); v.ez = static_cast<float>(LUA->CheckNumber(4));
	v.fx = static_cast<float>(LUA->CheckNumber(5)); v.fy = static_cast<float>(LUA->CheckNumber(6)); v.fz = static_cast<float>(LUA->CheckNumber(7));
	v.cosView = static_cast<float>(LUA->CheckNumber(8));
	v.n = std::clamp(static_cast<int>(LUA->CheckNumber(9)), 2, 32);
	v.budget = static_cast<int>(LUA->CheckNumber(10));
	v.nearD = static_cast<float>(LUA->CheckNumber(11));
	v.farD = static_cast<float>(LUA->CheckNumber(12));
	{
		std::lock_guard lock(g_requestMutex);
		g_request = Request { now, v };
	}
	g_requestCv.notify_one();
	Stats s;
	{
		std::lock_guard lock(g_statsMutex);
		s = g_published;
	}
	LUA->PushNumber(s.verts);
	LUA->PushNumber(s.tiles);
	LUA->PushNumber(s.ms);
	return 3;
}

// SetCameraInWater(inWater): once per drawn frame, before Flush: whether the view is in
// the water. Under water the camera starts inside the water material, so Remix refracts
// out through the surface instead of into it, and dims the view with the water's colour.
// The medium is sent again every frame: Remix forgets it whenever it clears its scene
// (camera cuts, mod reloads), and a restyled material takes over at once.
LUA_FUNCTION(Native_SetCameraInWater) {
	remixapi_MaterialHandle m = LUA->GetBool(1) ? g_material : nullptr;
	if (m || g_cameraMedium) setCameraMedium(m);
	return 0;
}

// Flush(frameNumber): once per drawn frame, from the draw hook. Destroys meshes that
// have been out of use long enough and hands waiting work to the render thread.
// Returns false if the render queue cannot be used (the native core must then stop).
LUA_FUNCTION(Native_Flush) {
	int frame = static_cast<int>(LUA->CheckNumber(1));
	if (frame != g_lastFrame) {
		g_lastFrame = frame;
		++g_frames;
		reap();
	}
	LUA->PushBool(flushJobs());
	return 1;
}

LUA_FUNCTION(Native_ClearRipples) {
	dropRequests();
	std::lock_guard state(g_state);
	clearRipples();
	publishStats();
	return 0;
}

LUA_FUNCTION(Native_Shutdown) {
	dropRequests();
	std::lock_guard state(g_state);
	destroyAll();
	return 0;
}

LUA_FUNCTION(Native_Stats) {
	Stats s;
	{
		std::lock_guard lock(g_statsMutex);
		s = g_published;
	}
	size_t graves;
	{
		std::lock_guard lock(g_graveMutex);
		graves = g_graves.size();
	}
	LUA->CreateTable();
	LUA->PushNumber(s.verts); LUA->SetField(-2, "verts");
	LUA->PushNumber(s.tiles); LUA->SetField(-2, "tiles");
	LUA->PushNumber(s.ms); LUA->SetField(-2, "ms");
	LUA->PushNumber(s.simTiles); LUA->SetField(-2, "simTiles");
	LUA->PushNumber(s.bodies); LUA->SetField(-2, "bodies");
	LUA->PushNumber(s.simMs); LUA->SetField(-2, "simMs");
	LUA->PushNumber(s.simSteps); LUA->SetField(-2, "simSteps");
	LUA->PushNumber(s.staticMeshes); LUA->SetField(-2, "staticMeshes");
	LUA->PushNumber(s.tilesTotal); LUA->SetField(-2, "tilesTotal");
	LUA->PushNumber(static_cast<double>(graves)); LUA->SetField(-2, "pendingDestroys");
	LUA->PushNumber(g_jobsQueued); LUA->SetField(-2, "jobsQueued");
	LUA->PushNumber(g_jobsRun); LUA->SetField(-2, "jobsRun");
	LUA->PushBool(g_jobThread != 0 && g_jobThread != g_luaThread); LUA->SetField(-2, "jobsOnRenderThread");
	LUA->PushBool(g_cameraMedium != nullptr); LUA->SetField(-2, "cameraInWater");
	return 1;
}

}  // namespace

GMOD_MODULE_OPEN() {
	pinModule();
	g_luaThread = GetCurrentThreadId();
	LUA->PushSpecial(SPECIAL_GLOB);
	LUA->CreateTable();
	LUA->PushCFunction(Native_Init); LUA->SetField(-2, "Init");
	LUA->PushCFunction(Native_SetMaterial); LUA->SetField(-2, "SetMaterial");
	LUA->PushCFunction(Native_SetSurface); LUA->SetField(-2, "SetSurface");
	LUA->PushCFunction(Native_SetRepeat); LUA->SetField(-2, "SetRepeat");
	LUA->PushCFunction(Native_SetShape); LUA->SetField(-2, "SetShape");
	LUA->PushCFunction(Native_SetBodies); LUA->SetField(-2, "SetBodies");
	LUA->PushCFunction(Native_AddImpulse); LUA->SetField(-2, "AddImpulse");
	LUA->PushCFunction(Native_SetWaves); LUA->SetField(-2, "SetWaves");
	LUA->PushCFunction(Native_Update); LUA->SetField(-2, "Update");
	LUA->PushCFunction(Native_SetCameraInWater); LUA->SetField(-2, "SetCameraInWater");
	LUA->PushCFunction(Native_Flush); LUA->SetField(-2, "Flush");
	LUA->PushCFunction(Native_ClearRipples); LUA->SetField(-2, "ClearRipples");
	LUA->PushCFunction(Native_Shutdown); LUA->SetField(-2, "Shutdown");
	LUA->PushCFunction(Native_Stats); LUA->SetField(-2, "Stats");
	LUA->PushNumber(5); LUA->SetField(-2, "Version");
	LUA->SetField(-2, "RTXWaterNative");
	LUA->Pop();
	return 0;
}

GMOD_MODULE_CLOSE() {
	stopWorker();
	dropRequests();
	std::lock_guard state(g_state);
	destroyAll();
	return 0;
}
