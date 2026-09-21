# Patches to the vendored Stockfish 19 source

Upstream: Stockfish 19, tag `sf_19`, GPLv3 (`stockfish/Copying.txt`, `stockfish/AUTHORS`).
The tree under `stockfish/src` is otherwise byte-for-byte upstream.

Every patch is marked in the source with `Chess TV PATCH BEGIN` / `Chess TV PATCH END`,
so `grep -rn "Chess TV PATCH" stockfish/src` lists them all.

## 1. `src/misc.h` — per-architecture SIMD gate

Inserted just above `#define stringify2(x) #x`.

SwiftPM can condition a `-D` flag on the platform but not on the architecture, and an
Apple simulator build compiles an arm64 and an x86_64 slice from a single set of
`cxxSettings`. Passing `-DUSE_NEON=8` unconditionally therefore breaks the x86_64
tvOS Simulator slice (`arm_neon.h` does not exist there).

The package now defines only `SF_APPLE_ARCH_GATE` and the real selection happens in
`misc.h`, which every translation unit sees before any `USE_*` macro is tested:

* `__aarch64__` / `__ARM_NEON` → `USE_NEON 8`, plus `USE_NEON_DOTPROD` when the
  compiler advertises `__ARM_FEATURE_DOTPROD` (Apple TV 4K is ARMv8.2+, so it does).
* anything else (the x86_64 simulator slice) → no SIMD macros, and Stockfish falls
  back to its portable code paths. The baseline x86_64 ABI guarantees only SSE2 and
  the package passes no `-m` flags, so enabling `USE_SSE41` there would not compile.

No behaviour change on arm64: the macros end up exactly as Stockfish's own Makefile
sets them for `ARCH=apple-silicon`.

## 2. `src/nnue/simd.h` — include `../misc.h` first

Inserted immediately after the include guard.

`simd.h` tests `USE_AVX2` / `USE_NEON` / … at the top of the file and only reaches
`misc.h` later, indirectly through `../types.h`. The gate above has to be visible
before those tests, so `#include "../misc.h"` moved to the top. `misc.h` has its own
include guard and no dependency on `simd.h`, so this cannot cycle.

## Not patched, excluded instead (see `Package.swift`)

* `src/main.cpp` — defines `main()`. `Sources/CStockfish/stockfish_bridge.cpp`
  replicates it without the symbol.
* `src/universal/` — the universal-binary launchers. They define their own `main()`
  and `entry_*.cpp` calls `getauxval(AT_HWCAP)` via `<sys/auxv.h>`, which does not
  exist on Darwin at all.
* `src/Makefile`, `src/incbin/UNLICENCE` — not sources; SwiftPM would flag them as
  unhandled files.

`src/incbin/incbin.h` stays in the tree but is inert: `NNUE_EMBEDDING_OFF` makes
`nnue/network.cpp` declare a one-byte stub instead of invoking `INCBIN`, so the
98 MB network is never assembled into the binary. The app passes its bundle path
through `setoption name EvalFile`.

## tvOS audit (nothing needed patching)

* No `fork`, `system`, `popen`, `posix_spawn` or `execve` anywhere outside
  `src/universal/`, which is excluded.
* `numa.h` compiles its "no NUMA" branch on Apple platforms: the CPU-affinity code
  is gated on `__linux__` / `_WIN64`.
* `shm.h` / `shm_unix.h` use `mmap(MAP_SHARED)`, `flock` and a unix socket under
  `/tmp/stockfish-<uid>`. On tvOS `/tmp` resolves inside the app sandbox, so the
  path is writable and the code degrades to the local-allocation fallback if it is
  not. No API on the tvOS forbidden list is used.
* `std::thread`, `<atomic>` and the large static tables compile and link for
  `appletvos` and `appletvsimulator`.

## Known risk, not patched

Stockfish calls `exit(EXIT_FAILURE)` on unrecoverable errors — a missing or corrupt
`EvalFile` (`nnue/network.cpp:188`), a failed large-page allocation, a bad option
value. Inside an app that terminates the whole process. `UCIEngine.init` checks the
network file exists before starting the engine and only ever sends options it
generates itself, which covers every path the app can reach. Patching these out
would mean threading error returns through most of the engine.
