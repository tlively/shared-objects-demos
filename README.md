# Shared Wasm GC Demos

Demonstration programs and synchronization utilities for shared WebAssembly Garbage Collection (Wasm GC) objects running on top of a standalone, lightweight JavaScript runtime (`runtime.js`) using Web Workers and Wasm GC waitqueue synchronization.

---

## 1. Building and Running

### Prerequisites

- **Binaryen** (`wasm-merge`, `wasm-opt`)
- **Python 3**
- **Modern Browser** supporting shared Wasm GC (e.g. Chrome Canary with `--js-flags="--experimental-wasm-shared"`)

### Building

Tools are looked up from `PATH` by default, or can be specified via environment variables:

```bash
# Build all demos and the top-level index.html
make

# Or specify custom tool locations
WASM_OPT=/path/to/wasm-opt \
WASM_MERGE=/path/to/wasm-merge \
make
```

This compiles:
- `index.html`: Top-level index page generated from `index.html.in`
- `build/<demo>/main.wasm`: Standalone WebAssembly binary linking the demo with the runtime and synchronization utilities
- `build/<demo>/runtime.js`: Standalone JavaScript runtime harness
- `build/<demo>/main.html`: Browser shell page

### Running Demos

Build all demos and launch the local HTTP development server with Cross-Origin Isolation headers (`COOP: same-origin` and `COEP: require-corp`):
```bash
make serve
```
Then open `http://localhost:8080/` to browse and launch any demo.

You can also run the server script directly with a custom port:
```bash
python3 scripts/serve.py -p 8000
```

### Adding a New Demo

1. Create a directory `<demo_name>/` containing `main.wat`.
2. In `<demo_name>/main.wat`, define and export the main entrypoint: `(func (export "main") ...)`.
3. Spawn threads with `(call $thread_spawn (ref.func $my_worker) $arg)`.
4. Join threads with `(drop (call $thread_join $thread_handle))`.
5. Clean up with `(call $thread_exit)` before returning. (Note: `thread_exit` is not called automatically upon returning from the thread function because threads may want to return to the browser event loop before exiting.)
6. Add `<demo_name>` to the `DEMOS` list in the `Makefile`.
7. Run `make <demo_name>` or `make serve`.

---

## 2. System Architecture

Demos are built entirely from WebAssembly text files (`.wat`) and run with a self-contained JavaScript runtime (`runtime.js`).

```
┌─────────────────────────────────────────────────────────────┐
│                    Demo Logic (e.g. hello/main.wat)         │
│                        exports main                         │
├───────────────────────────────┬─────────────────────────────┤
│   Common Sync Utilities       │    Wasm GC Runtime Layer    │
│   (e.g. common/mutex.wat)     │       (runtime.wat)         │
├───────────────────────────────┴─────────────────────────────┤
│                    Standalone JavaScript Runtime            │
│                            (runtime.js)                     │
│                  Delegate Worker & Thread Worker Pool       │
└─────────────────────────────────────────────────────────────┘
```

### Standalone JavaScript Runtime (`runtime.js`)

A single, zero-dependency browser JavaScript runtime implementing the coordinator architecture:
- **Main Browser Thread**: Runs `main()`, initializes the shared heap root, and connects to the delegate worker.
- **Delegate Worker**: Spawns and manages the pool of Web Workers, tracks active/idle workers, and routes all inter-thread control messages.
- **Thread Workers**: Receive task assignments via `"thread_start"` and execute user thread routines in Wasm.
- **Atomic Waiting & Feature Detection**: Detects `struct.wait` capability dynamically via `waitProbeBytes`. Thread workers block on waitqueues, while the main browser thread spins on atomic status fields using `(pause)`.

### Wasm GC Runtime Layer (`runtime.wat`)

Provides typed Wasm GC signatures, monotonic TID allocation, and waitqueue synchronization:
- **`thread_spawn`**: Allocates a unique thread ID (TID) atomically in Wasm GC (`struct.atomic.rmw.add`), instantiates a shared `$thread` descriptor, and requests worker allocation via the delegate. Returns `(ref $thread)`.
- **`_thread_entry`**: Executed on worker threads; sets thread-local `$current_thread` and runs the thread function via `call_ref`.
- **`thread_exit`**: Transitions `$current_thread`'s `status` to `1 (EXITED)`, wakes any waiting joiners via `waitqueue.notify`, and informs the delegate worker. Note: `thread_exit` is not called automatically upon returning from a thread routine because threads may want to return to the browser event loop before exiting.
- **`thread_join`**: Waits on the target `(ref $thread)` descriptor until its `status` becomes `1 (EXITED)`.
- **`thread_supports_wait`**: Dynamically queries whether atomic wait is supported in the calling context.
- **`console_log`**: Prints a shared externref (JS string) to the browser console.

### String Constants and JS String Builtins

Demos can use:
- **Imported String Constants**: e.g., `(import "'" "hello from thread " (global $str_prefix (ref (shared extern))))`
- **JS String Builtins (`wasm:js-string`)**:
  - `(import "wasm:js-string" "concat" (func $string_concat (param (ref null (shared extern)) (ref null (shared extern))) (result (ref (shared extern)))))`
  - `(import "wasm:js-string" "fromCodePoint" (func $string_fromCodePoint (param i32) (result (ref (shared extern)))))`

### Build and Lowering Pipeline

1. **Dependency Resolution**: `scripts/gendep.py` inspects `.wat` imports and writes `.deps/*.wat.d` makefiles.
2. **Merge & Lower (`build/<demo>/main.wasm`)**: Merges all dependent `.wat` modules (`demo/main.wat`, `runtime.wat`, `common/mutex.wat`, etc.) and lowers shared function references into an isolated table via `wasm-opt -O3 --make-shared-objects -O1`.
3. **Runtime Harness**: Copies `runtime.js` and produces `main.html` from `template.html` (or `default_template.html`).

---

## 3. Common Utilities (`common/`)

### Mutex (`common/mutex.wat`)

A fair, hybrid waitqueue mutex designed for shared Wasm GC objects.

- **Type Definition**:
  ```wat
  (type $mutex (shared (struct (field $state (mut i32)) (field $waitqueue (ref (shared waitqueue))))))
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

### Queue (`common/queue.wat`)

A blocking, thread-safe Multi-Producer Multi-Consumer (MPMC) linked-list queue for shared Wasm GC objects with `struct.wait` & `waitqueue.notify` thread signaling.

- **Type Definition**:
  ```wat
  (type $node (shared (struct (field $val (ref null (shared any))) (field $next (mut (ref null $node))))))
  (type $queue (shared (struct
    (field $lock (ref $mutex))
    (field $head (mut (ref null $node)))
    (field $tail (mut (ref null $node)))
    (field $size (mut i32))
    (field $waitqueue (ref (shared waitqueue)))
    (field $signal (mut i32))
  )))
  ```

- **Functions**:
  - `queue_new () -> (ref $queue)`: Allocates and initializes an empty queue.
  - `queue_push (param $q (ref $queue)) (param $val (ref null (shared any)))`: Enqueues a shared work item and notifies one waiting worker thread.
  - `queue_pop (param $q (ref $queue)) -> (ref null (shared any))`: Dequeues a work item, blocking on the waitqueue if empty until an item is pushed.
  - `queue_size (param $q (ref $queue)) -> i32`: Thread-safe query of the current backlog depth.

---

## 4. Repository Structure

```
.
├── Makefile               # Build automation producing index.html, .html, runtime.js, and .wasm
├── README.md              # Repository documentation and architecture overview
├── default_template.html  # Default HTML shell template for console-based demos
├── index.html.in          # HTML template for the top-level index page
├── runtime.js             # Standalone zero-dependency JavaScript runtime & delegate worker coordinator
├── runtime.wat            # Wasm GC signatures, TID allocation, waitqueue synchronization, and runtime helpers
├── scripts/
│   ├── gendep.py          # Generates Makefile .d dependency files from WAT imports
│   ├── gen_index.py       # Generates top-level index.html from template
│   └── serve.py           # Local HTTP server with COOP/COEP headers
├── common/
│   ├── mutex.wat          # Waitqueue-based mutex with struct.wait and runtime thread wait detection
│   └── queue.wat          # Blocking MPMC queue with waitqueue notification
├── hello/                 # Multithreaded "Hello, World!" demonstration
│   └── main.wat           # Spawns worker threads using string constants & string builtins
├── philosophers/          # Dining Philosophers demonstration
│   └── main.wat           # Multithreaded deadlock-free dining philosophers with mutexes
└── workqueue/             # Producer-Consumer Work Queue demonstration
    ├── main.wat           # Producer pushes Fibonacci tasks; worker pool dequeues & computes
    └── template.html      # Interactive dashboard displaying live throughput & scale button
```
