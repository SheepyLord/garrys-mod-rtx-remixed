# rtx_agent: test hooks for AI agents driving Garry's Mod RTX

A client-side addon that makes a running GMod RTX session measurable from outside. It installs nothing until called. Every probe removes what it added when it finishes, writes `garrysmod/data/rtx_agent/<name>.json`, and prints `[RTXAgent] DONE <name>` to the console, so a harness that tails `garrysmod/console.log` (launch with `-condebug`) knows when to read the file.

## Driving it

- **Console commands.** These work from any console channel, for example a `WM_COPYDATA` message to the `Valve001` window (`-hijack`):
  - `rtx_agent_health`: writes `health.json`. It covers the loaded RTX components (`RemixConfig`, `RemixLight`, `MaterialPipeline`, `NikNaks`, `mmdhl`, ...), entity and MMD-model counts, Lua memory, Remix VRAM (`RemixResource.GetVramStats`), key convars, key Remix options, and the number of hooks per event.
  - `rtx_agent_frames <seconds> [name]`: frame-time summary (fps, median, p99, max) and a list of hitches. A hitch is a frame over 25 ms and over twice the running median.
  - `rtx_agent_profile <seconds> [name]`: times every Lua hook for the window, then restores it.
    - `top_per_frame`: cost per frame and calls per frame of each hook.
    - `slowest_single_call`: the worst single call of each hook.
    - `top_allocating`: Lua memory each hook leaves behind per frame (`kb_per_frame`), i.e. the garbage it feeds the collector. Calls during which a GC step ran are not counted, so these are lower bounds.
    - `hitches`: for each hitch frame, the five hooks that cost the most in it. Little Lua time in a hitch frame means the hitch is outside Lua (engine, Remix, GC).
  - `rtx_agent_exercise <rounds> [name]`: each round spawns four props (`gm_spawn`), toggles the flashlight, then undoes them. It samples entities, Lua memory, frame time and Remix VRAM after each step, for leak and stability checks.
  - `rtx_agent_viewoff`: releases a camera set with `RTXAgent.View` and restores HUD and viewmodel drawing.
- **Lua** (single player with `sv_allowcslua 1`, through `lua_run_cl`): `RTXAgent.View(Vector(...), Angle(...), fov)` holds a camera with HUD and viewmodel hidden. Then send `jpeg <name> 95` on the console: the `jpeg` command captures the presented, path-traced frame. `RTXAgent.Health()` returns the same table as the health command.

## Harness

`C:\Users\matt-peng\.rpai\work\_probe\session_run.py` launches the game unattended, loads a save, waits for RTX Lua setup and the skybox mesh build, measures frame time, GPU busy % and per-thread CPU, and quits. It declines the post-crash "RTX Remix Crash Report" prompt and stops early if the game exits. Options:

| Option | Effect |
|---|---|
| `--save=saves/<file>.gms` | load that save |
| `--look=<label>` | reference-state screenshots |
| `--lookcam=ref` | with `--look`, pin both views to the reference camera instead of the player's own view, which can drift after a load |
| `--profile-hooks` | run the hook profiler |
| `--agent` | run this addon's suite: health, 20 s frames, 20 s profile, 6 exercise rounds |
| `--soak=N` | N cycles of exercise, frame timing and a full save reload; records memory, VRAM, FPS and new crash dumps |
| `--ditests`, `--dibisect`, `--directviews` | live RTXDI / direct-lighting toggles and debug views, captured from the same camera |
| `--rtxdifix` | switch RTXDI on live, then capture the direct-diffuse debug view with RTXDI on and off; all black with RTXDI on means RTXDI produces no direct light |
| `option=old:new` | live A/B of a Remix option |
| `--env=NAME=VALUE` | set a variable for the game. A layered `DXVK_RTX_CONFIG_FILE=rtx.conf,extra.conf` does not override `rtx.conf` values for Remix options; change those live or in `rtx.conf` |

Results append to `session_log.jsonl`.

Crash triage tools are in the same folder: `minidump_info.py`, `minidump_strings.py` and `diasym/diasym.exe`.
