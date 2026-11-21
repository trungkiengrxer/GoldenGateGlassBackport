# glass-harness

Offline harness for the GGGlass shader (`shaders/glass26_replica.metal`). Runs in its own process with Metal, reads QuartzCore's `default.metallib` read-only, never touches WindowServer and opens no windows. Requires macOS 26.6 (25G72).

## Build

```bash
glass-harness/build.sh
```

## Tests

Run from `glass-harness/`:

```bash
build/classify
build/compare shaders/glass26_replica.metal replica_glass_background_sdf_lpf
build/abicompare
build/group
```

| Tool | Checks |
|---|---|
| `classify` | 26.6 face recognition (`classify_glass26`), the automatic 27 parameter path vs forced function constants, animation interpolation, per-glass appearance, app recipe codes. Ends with `TOTAL: N/N passed` |
| `compare` | The transcribed 26.6 shader is bit-exact with Apple's `glass_background_sdf_lpf` over random uniforms. Ends with `TOTAL: N/N passed` |
| `abicompare` | Every replacement in `shaders/gg27-entries.txt` has the same binding ABI as the Apple function it replaces |
| `group` | Renders a button group (26.6 vs 27) and checks the automatic path, slider, texture vs SDF variants and diagnostics; prints `-> OK` / `-> FAIL` per check and exits 1 on failure. Writes PNGs to `../renders` (created if missing) |
| `render` | Renders comparison images to `../renders` (no checks) |
| `reflect` | Dumps the ABI of Apple's glass shaders as JSON |

`classify` reads `../measurements/glass-states-25G72.json`; `group` uses system wallpapers, and real screenshots in `../renders` are optional.
