# Shared Wasm GC Demos

Demonstration programs and synchronization utilities for shared WebAssembly Garbage Collection (Wasm GC) objects running on top of Emscripten threads using the experimental `-sSHARED_WASMGC` feature.

---

## 1. Building and Running

### Prerequisites

- **Emscripten** (built with `-sSHARED_WASMGC` support)
- **Binaryen** (`wasm-merge`, `wasm-opt`)
- **Python 3**
- **Node.js** (v22+ with `--experimental-wasm-shared`) or modern browser supporting shared Wasm GC and string builtins

### Building

Tools are looked up from `PATH` by default, or can be specified via environment variables:

```bash
# Build all demos and the top-level index.html
make

# Or specify custom tool locations
EMCC=/path/to/emcc \
WASM_OPT=/path/to/wasm-opt \
WASM_MERGE=/path/to/wasm-merge \
make
```

This compiles:
- `index.html`: Top-level index page generated from `index.html.in`
- `build/<demo>/main.wasm`: Merged WebAssembly binary linking the C runtime with the lowered Wasm GC bundle
- `build/<demo>/main.js`: Modular JavaScript harness
- `build/<demo>/main.html`: Browser shell page

### Running Demos

- **In the Browser**:
  Build all demos and launch the local HTTP development server with Cross-Origin Isolation headers (`COOP: same-origin` and `COEP: require-corp`):
  ```bash
  make serve
  ```
  Then open `http://localhost:8080/` to browse and launch any demo.

  You can also run the server script directly with a custom port:
  ```bash
  python3 scripts/serve.py -p 8000
  ```

- **In Node.js**:
  ```bash
  make run-hello
  ```

### Adding a New Demo

1. Create a directory `<demo_name>/` containing `main.wat`.
2. In `<demo_name>/main.wat`, define and export the main entrypoint: `(func (export "wasm_main") ...)`.
3. Spawn threads with `(call $spawn_thread (ref.func $my_worker) $arg)`.
4. Add `<demo_name>` to the `DEMOS` list in the `Makefile`.
5. Run `make <demo_name>`, `make run-<demo_name>`, or `make serve`.

---

## 2. System Architecture

Because LLVM does not directly emit Wasm GC instructions or shared object types, applications are structured in complementary layers and linked post-compile using Binaryen's `wasm-merge` and `wasm-opt`.

```
┌─────────────────────────────────────────────────────────────┐
│                    Demo Logic (e.g. hello/main.wat)         │
│                        exports wasm_main                    │
├───────────────────────────────┬─────────────────────────────┤
│   Common Sync Utilities       │    Wasm GC Runtime Layer    │
│   (e.g. common/mutex.wat)     │       (runtime.wat)         │
├───────────────────────────────┴─────────────────────────────┤
│                    C / Emscripten Runtime Layer             │
│                 (runtime.c, libruntime.js)                  │
│                   imports wasm_main & thread_entry          │
└─────────────────────────────────────────────────────────────┘
```

### C / JavaScript Runtime Layer (`runtime.c`, `libruntime.js`)

A single, shared C runtime compiled once with `-sSHARED_WASMGC`, `-pthread`, and `--js-library libruntime.js`:
- Initializes Emscripten's pthread worker pool and linear memory.
- Bridges C/POSIX threading APIs (`pthread_create`, `pthread_join`) and console logging to Wasm GC.
- `libruntime.js` provides `console_log` to log JavaScript strings (`externref`) directly to the browser console.
- Queries `_emscripten_thread_supports_atomics_wait()` to detect whether the active thread is allowed to perform blocking waits.
- Invokes `wasm_main` (exported by the demo's `main.wat`) on the main thread and `wasm_thread_entry` (exported by `runtime.wat`) on worker threads.

### Wasm GC Runtime Layer (`runtime.wat`)

Provides typed Wasm GC signatures and bridges runtime operations:
- **`spawn_thread`**: Accepts a shared function reference `(type $thread_fn (shared (func (param (ref null (shared any))))))` and a shared argument. Packs them into a shared task object and invokes `pthread_create`.
- **`wasm_thread_entry`**: Executed on worker threads; retrieves the task object and dispatches to the thread function via `call_ref`.
- **`join_thread`**: Joins a worker thread by its integer thread ID.
- **`thread_supports_wait`**: Returns `1` on worker threads (where atomic blocking is supported) and `0` on the main browser thread.
- **`console_log`**: Prints an `externref` (JS string) to the browser console.

### String Constants and JS String Builtins

Demos can use:
- **Imported String Constants**: e.g., `(import "'" "hello from thread " (global $str_prefix (ref extern)))`
- **JS String Builtins (`wasm:js-string`)**:
  - `(import "wasm:js-string" "concat" (func $string_concat (param externref externref) (result (ref extern))))`
  - `(import "wasm:js-string" "fromCodePoint" (func $string_fromCodePoint (param i32) (result (ref extern))))`

### Build and Lowering Pipeline

1. **WAT Bundle & Lower (`build/<demo>/wat.wasm`)**: Merges all dependent `.wat` modules (`demo/main.wat`, `runtime.wat`, `common/mutex.wat`) and lowers shared function references into an isolated table via `wasm-opt -O3 --make-shared-objects -O1`.
2. **C Runtime Link (`build/<demo>/main.wasm`)**: Merges the C `runtime.wasm` with `wat.wasm`, linking `runtime.c`'s `wasm_main` import directly to the demo's exported `wasm_main` and preserving Emscripten's `__indirect_function_table` for pthread trampolines.

---

## 3. Common Utilities (`common/`)

### Mutex (`common/mutex.wat`)

A fair, hybrid waitqueue mutex designed for shared Wasm GC objects.

- **Type Definition**:
  ```wat
  (type $mutex (shared (struct (field (mut i32)) (field (ref (shared waitqueue))))))
  ```

- **Functions**:
  - `mutex_new () -> (ref $mutex)`:
    Allocates a new mutex initialized to unlocked (`0`) with a dedicated waitqueue created via `(waitqueue.new)`.
  - `mutex_try_lock (param (ref $mutex)) -> i32`:
    Non-blocking atomic compare-and-swap (`struct.atomic.rmw.cmpxchg`) transitioning state from `0` to `1`. Returns `1` if acquired, `0` otherwise.
  - `mutex_lock (param (ref $mutex))`:
    Acquires the lock. If contention occurs:
    - Runs a bounded spin loop up to 40 times using `(pause)` before waiting.
    - On worker threads (`thread_supports_wait == 1`): Suspends execution on the waitqueue via `struct.wait` until woken, consuming no CPU.
    - On the main browser thread (`thread_supports_wait == 0`): Continues spinning to prevent blocking the browser UI thread.
  - `mutex_unlock (param (ref $mutex))`:
    Atomically clears the lock state to `0` and wakes one waiting thread via `(waitqueue.notify ... 1)`.

---

## 4. Repository Structure

```
.
├── Makefile             # Build automation producing index.html, .html, .js, and .wasm
├── README.md            # Repository documentation and architecture overview
├── index.html.in        # HTML template for the top-level index page
├── libruntime.js        # Emscripten JS library extension providing console printing
├── runtime.c            # Single shared C runtime (compiled once for all demos)
├── runtime.wat          # Wasm GC signatures, thread dispatching, and runtime helpers
├── scripts/
│   ├── gendep.py        # Generates Makefile .d dependency files from WAT imports
│   ├── gen_index.py     # Generates top-level index.html from template
│   └── serve.py         # Local HTTP server with COOP/COEP headers
├── common/
│   └── mutex.wat        # Waitqueue-based mutex with struct.wait and runtime thread wait detection
└── hello/               # Multithreaded "Hello, World!" demonstration
    └── main.wat         # Spawns worker threads using string constants & string builtins
```
