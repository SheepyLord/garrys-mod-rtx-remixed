# Material lookup and viewmodel performance

Two independent fixes reduce repeated CPU work in the RTX client: a reverse index for texture-hash ownership, and cached mounted-content checks in the optional HL2 RTX viewmodel addon. Neither changes imported map geometry, collision, texture resolution or renderer quality settings.

## Texture-hash ownership

`MaterialHashLookup` in [source/material_hash_lookup.h](../source/material_hash_lookup.h) records each material's texture variants and all material names owning a hash. Shared textures and animated variants retain their owners until the last corresponding association is removed. Results are sorted and unique. Repeated observations of an unchanged owner do not advance the ownership revision; new/removed owners and cache resets do.

[D3D9TextureTracker](../source/d3d9_texture_tracker.cpp) shares a refresh between reverse lookups and revision queries, normally at most once per second. A refresh hashes each distinct tracked texture once, even when multiple materials share it. Temporary COM references protect the snapshot while Remix calls run outside the tracker mutex. Concurrent cache changes invalidate the snapshot; failed or incomplete resolution reports unavailable rather than treating uncertainty as proof that a material has no other owners.

The additive client Lua API is:

| API | Result and meaning |
|---|---|
| `RemixMaterial.FindMaterialByHash(hexString)` | Material-name table, plus an ownership revision string; a `nil` revision means unavailable. Existing callers can continue using the first result. |
| `RemixMaterial.GetMaterialHashRevision()` | Current ownership revision, or `nil` when a trustworthy ownership view is unavailable. May trigger the shared refresh. |
| `RemixMaterial.GetMaterialHashStats()` | Process-lifetime counters and current inventory sizes. This getter does not refresh or call Remix. |

Use hexadecimal strings for hashes to preserve all 64 bits. Treat revision strings as opaque equality tokens. A caller caching an exclusivity decision must invalidate it when the revision changes or becomes unavailable; an empty owner list with a `nil` revision is not a verified empty result. Queries belong in bounded update work, not every draw callback.

Stats include `lookup_calls`, `revision_polls`, `refreshes`, `hash_calls`, `cache_hits`, `discarded_refreshes`, `failed_refreshes`, `materials`, `variants`, `hashes`, `available` and `revision`. Capture them at diagnostic boundaries to compare work without adding texture refreshes. Verbose lookup/tracking notices honor `r_remix_material_debug`, which defaults to `0`; set it to `1` only when collecting those diagnostics. Error reporting remains independent.

The CPU ownership oracle is [tests/material_hash_lookup_test.cpp](../tests/material_hash_lookup_test.cpp), including 180,000 differential lookups against a separate full-scan model.

## HL2 RTX combined viewmodels

The optional [mount-hl2rtx client script](../garrysmod/garrysmod/addons/mount-hl2rtx/lua/autorun/client/hl2rtx_model_compat_viewmodels.lua) previously searched `GAME` for `.rtxlauncher-hl2rtx-overlay.json` from both viewmodel render hooks, including for the unmapped physgun. Model validity was also checked repeatedly for mapped weapons. A negative filesystem lookup can traverse many mounted addon search paths.

The script now rejects invalid/unmapped weapons early and uses cached marker availability and validity for its twelve known replacement models. Both present and absent results are cached. Initial load builds the cache; `InitPostEntity`, `GameContentChanged` and `OnReloaded` invalidate it and coalesce a refresh into a named one-shot timer. There is no recurring polling timer. Unmounted content performs no model validation or precaching. `GameContentChanged` covers addon/game mount and unmount events according to the [Facepunch hook documentation](https://wiki.facepunch.com/gmod/GM%3AGameContentChanged).

After externally changing overlay files without an engine content event, run `hl2rtx_model_compat_refresh`. `hl2rtx_model_compat_status` displays the cached mounted state and its last refresh reason. The existing enable and debug convars retain their purpose. Separate hands are hidden only when the replacement is cached-valid and the actual viewmodel uses it; missing models or failed substitutions keep hands visible.

[tests/test_hl2rtx_viewmodels.py](../tests/test_hl2rtx_viewmodels.py) executes the actual Lua source with Lupa. Nine tests cover thousands of render calls without filesystem/model checks, positive and negative cache entries, refresh/invalidation, failed substitutions, deferred entity checks and debug deduplication. Run with Python and Lupa available:

```text
python -m unittest discover -s tests -p test_hl2rtx_viewmodels.py -v
```

## Measured diagnosis, 2026-09-06

The controlled Subway RTX run `subway_rtx_compat_diagnostic_01` changed only `hl2rtx_model_compat_combined_viewmodels` between the following stationary phases. Each phase retained normal entity/viewmodel drawing and recorded 100% focus. The native ownership-cache candidate was already present, so this comparison identifies a separate compatibility-hook cost.

| Same-run phase | Compatibility setting | Mean frame interval | Mean PreRender–PostRender span |
|---|---:|---:|---:|
| Forward | 1 | 16.136 ms | 12.624 ms |
| Compatibility disabled | 0 | 4.082 ms | 0.907 ms |
| Restored | 1 | 15.862 ms | 12.801 ms |

The forward mean includes one 447.744 ms frame gap. These are measured wall-clock intervals, not GPU execution times or generated-frame rates. The camera was held at the same grounded position; gravity had settled the requested starting height before measurement.

Separate engine VProf captures support the diagnosis: `subway_rtx_fixed_01/vprof_external` sampled 627 frames over 10.00 seconds at 15.94 ms/frame; the disabled compatibility run sampled 2,446 frames over 9.99 seconds at 4.08 ms/frame. Both report 11 `C_BaseAnimating::DrawModel` calls per frame. The enabled capture reports four `CBaseFileSystem::FileExists` calls per frame averaging 8.327 ms including children, plus four `IsDirectory` calls averaging 3.194 ms. Those scopes are absent from the disabled capture. These separate profiler windows explain the filesystem work; the table above is the direct same-run toggle comparison.

The permanent cached-state patch subsequently passed [enabled-state profiling acceptance and owned-process cleanup](../../!map_importer_astra/build/render_performance_20260906/subway_rtx_final_01/result.json) in `subway_rtx_final_01`; the compatibility setting remained `1` in every recorded phase. Its [engine VProf capture](../../!map_importer_astra/build/render_performance_20260906/subway_rtx_final_01/vprof_external/flat.txt) sampled 2,439 frames over 9.99 seconds at 4.10 ms/frame (244.17 fps). `CViewRender::Render` averaged 0.952 ms/frame and `C_BaseAnimating::DrawModel` averaged 0.144 ms/frame with 11 calls/frame. `FileExists`, `IsDirectory` and `Open` scopes are absent from that report. These profiling results complement the nine passing offline Lua regressions; they do not replace full map collision/material acceptance.

Those evidence links refer to the local sibling importer workspace, under `!map_importer_astra/build/render_performance_20260906/`; they are not bundled source documentation assets. Each run retains `result.json`, `raw/client.json` and `vprof_external/{flat.txt,hierarchy.txt,result.json}`. This diagnosis applies to the tested RTX installation with the compatibility addon mounted; it does not establish that stock Garry's Mod has that addon or the same bottleneck.
