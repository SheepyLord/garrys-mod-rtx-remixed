# gm_poolrooms RTX: the build pipeline

The remaster is documented in [docs/GM_POOLROOMS_RTX.md](../../docs/GM_POOLROOMS_RTX.md). This
folder holds the pipeline that builds its addon data and Remix mod under `garrysmod/`:

- `tools/`: the scripts (see the doc's Rebuilding table). `poolrooms_paths.py` says where
  everything lives; `extract_map.py` unpacks the workshop map into `map_extract/`, the first step
  on a new checkout; `game.py` and `restart.py` drive the RTX game install (`POOLRTX_GAME`).
- `map_extract/`: the extracted workshop map, the pipeline's input. It is the map author's work,
  so it is not in git.
- `work/`: intermediates and screenshots, not in git.
