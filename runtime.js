/**
 * Shared Wasm GC Standalone Browser Runtime
 * =========================================
 *
 * This runtime provides a lightweight, zero-dependency browser execution environment
 * for multithreaded WebAssembly programs using shared Wasm GC objects and waitqueues.
 *
 * Architecture Overview
 * ---------------------
 * The runtime consists of two complementary components:
 * 1. `runtime.wat`: The Wasm GC layer defining the shared `$thread` descriptor struct,
 *    monotonic 32-bit TID allocation, imported `$shared_heap_root`, and exported thread
 *    lifecycle APIs (`thread_spawn`, `thread_join`, `thread_exit`, `console_log`).
 * 2. `runtime.js`: This file, which coordinates Web Worker lifecycle, module instantiation,
 *    and inter-thread message routing.
 *
 * Dynamically, execution involves three distinct roles:
 * - **Main Browser Thread**: Instantiates the Wasm module with a null `$shared_heap_root`
 *   WebAssembly.Global (which is initialized by Wasm's `(start)` function), spawns the
 *   single Delegate Worker passing the initialized root value, runs `main()`, and displays
 *   console/UI output.
 * - **Delegate Worker**: A single dedicated Web Worker acting as the central coordinator.
 *   It manages the pool of execution workers, passing the shared heap root to thread workers
 *   upon initialization.
 * - **Thread Workers**: Web Workers that instantiate the WebAssembly module with the shared
 *   heap root and execute user thread routines (`$thread_fn`) dispatched via `_thread_entry`.
 *
 * Atomic Waiting & Feature Detection
 * ----------------------------------
 * The runtime includes an embedded 53-byte WebAssembly probe module (`waitProbeBytes`) that
 * executes a 0-nanosecond `struct.wait` instruction at startup in each execution context:
 * - On **Thread Workers**, where atomic blocking is permitted, `thread_supports_wait` is set
 *   to `1`, and threads synchronize using `struct.wait` and `waitqueue.notify`.
 * - On the **Main Browser Thread**, where `struct.wait` is prohibited, `thread_supports_wait`
 *   is set to `0`, and waiting operations spin with `(pause)` on shared atomic status fields.
 *   This allows workers to make forward progress without blocking the browser event loop.
 *
 * Thread Descriptor & Lifecycle Protocol
 * --------------------------------------
 * Each thread is represented by a shared Wasm GC struct:
 *   `(type $thread (shared (struct (field $id i32) (field $status (mut i32)) (field $waitqueue (ref (shared waitqueue))))))`
 *
 * Status progression:
 * - `0 (RUNNING)`: Created directly in the running state and dispatched asynchronously.
 * - `1 (EXITED)`: Thread routine finished and invoked `thread_exit`.
 *
 * Joining a thread (`thread_join`) is entirely self-contained within WebAssembly: joiners
 * wait directly on the `$thread` struct's waitqueue until its status becomes `1 (EXITED)`.
 */

'use strict';

const isBrowser = typeof window !== 'undefined';

const compileOptions = {
  builtins: ['js-string'],
  importedStringConstants: "'"
};

// Embedded Wasm probe module to feature detect atomic wait support on the calling thread.
// Equivalent WAT:
// (module
//   (type $probe (shared (struct (field (mut i32)))))
//   (func (export "test") (result i32)
//     (struct.wait $probe 0
//       (struct.new_default $probe)
//       (waitqueue.new)
//       (i32.const 0)
//       (i64.const 0)
//     )
//   )
// )
// prettier-ignore
const waitProbeBytes = new Uint8Array([
  // --- WASM binary header ---
  0x00, 0x61, 0x73, 0x6d,                       // magic: "\0asm"
  0x01, 0x00, 0x00, 0x00,                       // version: 1

  // --- Type Section (id 1, size 10, 2 types) ---
  0x01, 0x0a, 0x02,
  // Type 0: (type (shared (struct (field (mut i32))))))
  0x65, 0x5f, 0x01,                             // shared struct with 1 field
  0x7f, 0x01,                                   // field 0: (mut i32)
  // Type 1: (type (func (result i32)))
  0x60, 0x00, 0x01, 0x7f,                       // func with 0 params, 1 result (i32)

  // --- Function Section (id 3, size 2, 1 func) ---
  0x03, 0x02, 0x01, 0x01,                       // func 0 uses type index 1

  // --- Export Section (id 7, size 8, 1 export) ---
  0x07, 0x08, 0x01,                             // 1 export entry
  0x04, 0x74, 0x65, 0x73, 0x74,                 // name: "test" (length 4)
  0x00, 0x00,                                   // kind: func (0), index: 0

  // --- Code Section (id 10, size 17, 1 func body) ---
  0x0a, 0x11, 0x01,                             // 1 function body
  0x0f,                                         // body size in bytes (15)
  0x00,                                         // 0 local variables
  0xfb, 0x01, 0x00,                             // struct.new_default type 0
  0xfe, 0x07,                                   // waitqueue.new (allocates waitqueue)
  0x41, 0x00,                                   // i32.const 0 (expected field 0 value)
  0x42, 0x00,                                   // i64.const 0 (timeout_ns = 0 for immediate return)
  0xfe, 0x05, 0x00, 0x00,                       // struct.wait type 0, field 0
  0x0b                                          // end
]);

function detectThreadSupportsWait() {
  try {
    const probeModule = new WebAssembly.Module(waitProbeBytes);
    const probeInstance = new WebAssembly.Instance(probeModule);
    probeInstance.exports.test();
    return 1;
  } catch (e) {
    return 0;
  }
}

const threadSupportsWait = detectThreadSupportsWait();

// Embedded Wasm helper module to create and export a WebAssembly.Global of type (mut (ref null (shared any))).
// Equivalent WAT:
// (module
//   (global (export "g") (mut (ref null (shared any))) (ref.null (shared none)))
// )
// prettier-ignore
const sharedHeapRootGlobalBytes = new Uint8Array([
  // --- WASM binary header ---
  0x00, 0x61, 0x73, 0x6d,                       // magic: "\0asm"
  0x01, 0x00, 0x00, 0x00,                       // version: 1

  // --- Global Section (id 6, size 9, 1 global) ---
  0x06, 0x09, 0x01,
  0x63, 0x65, 0x6e,                             // type: (ref null (shared any))
  0x01,                                         // mutability: 1 (mut)
  0xd0, 0x65, 0x71,                             // init expr: (ref.null (shared none))
  0x0b,                                         // end

  // --- Export Section (id 7, size 5, 1 export) ---
  0x07, 0x05, 0x01,
  0x01, 0x67,                                   // name: "g"
  0x03, 0x00                                    // kind: global (3), index: 0
]);

function createSharedHeapRootGlobal(initialValue = null) {
  const mod = new WebAssembly.Module(sharedHeapRootGlobalBytes);
  const inst = new WebAssembly.Instance(mod);
  const g = inst.exports.g;
  if (initialValue !== null) {
    g.value = initialValue;
  }
  return g;
}

// ==========================================
// 1. Worker Execution Logic (Delegate & Thread Workers)
// ==========================================
if (!isBrowser) {
  let role = null; // 'delegate' | 'thread_worker'
  let wasmModule = null;
  let scriptUrl = null;
  let sharedHeapRoot = null;
  let wasmInstance = null;

  // Delegate worker pool
  const workerPool = []; // array of Worker instances
  const freeWorkers = []; // array of worker IDs

  self.onmessage = function(e) {
    const msg = e.data;
    if (!msg || !msg.cmd) return;

    // 'init_delegate': Sent from the main browser thread to initialize this Worker
    // as the central coordinator (Delegate Worker).
    if (msg.cmd === 'init_delegate') {
      role = 'delegate';
      wasmModule = msg.wasmModule;
      scriptUrl = msg.scriptUrl;
      sharedHeapRoot = msg.sharedHeapRoot;
      self.postMessage({ cmd: 'delegate_ready' });
    // 'init_thread_worker': Sent from the Delegate Worker to initialize a new Worker
    // as a dedicated execution thread (Thread Worker).
    } else if (msg.cmd === 'init_thread_worker') {
      role = 'thread_worker';
      wasmModule = msg.wasmModule;
      sharedHeapRoot = msg.sharedHeapRoot;

      const workerImports = {
        env: {
          thread_supports_wait: threadSupportsWait,
          shared_heap_root: createSharedHeapRootGlobal(sharedHeapRoot),
          console_log: (text) => self.postMessage({ cmd: 'log', text }),
          js_thread_spawn: (fn, arg, thread) => self.postMessage({ cmd: 'thread_spawn', fn, arg, thread }),
          js_thread_exit: () => self.postMessage({ cmd: 'thread_exit' })
        }
      };
      wasmInstance = new WebAssembly.Instance(wasmModule, workerImports);
    } else if (msg.cmd === 'thread_start') {
      try {
        wasmInstance.exports._thread_entry(msg.thread, msg.fn, msg.arg);
      } catch (err) {
        self.postMessage({ cmd: 'error', error: String(err) });
      }
    } else if (role === 'delegate') {
      if (msg.cmd === 'thread_spawn') {
        handleSpawn(msg.fn, msg.arg, msg.thread);
      } else if (msg.cmd === 'log') {
        self.postMessage({ cmd: 'log', text: msg.text });
      } else if (msg.cmd === 'error') {
        self.postMessage({ cmd: 'error', error: msg.error });
      } else if (msg.cmd === 'shutdown') {
        for (const worker of workerPool) {
          worker.terminate();
        }
        self.close();
      }
    }
  };

  function handleSpawn(fn, arg, thread) {
    let worker;
    if (freeWorkers.length > 0) {
      const workerId = freeWorkers.pop();
      worker = workerPool[workerId];
    } else {
      const id = workerPool.length;
      worker = new Worker(scriptUrl);
      workerPool.push(worker);

      worker.onmessage = function(e) {
        const wmsg = e.data;
        if (!wmsg || !wmsg.cmd) return;
        if (wmsg.cmd === 'thread_spawn') {
          handleSpawn(wmsg.fn, wmsg.arg, wmsg.thread);
        } else if (wmsg.cmd === 'thread_exit') {
          freeWorkers.push(id);
        } else if (wmsg.cmd === 'log') {
          self.postMessage({ cmd: 'log', text: wmsg.text });
        } else if (wmsg.cmd === 'error') {
          self.postMessage({ cmd: 'error', error: wmsg.error });
        }
      };

      worker.postMessage({
        cmd: 'init_thread_worker',
        wasmModule,
        sharedHeapRoot
      });
    }

    worker.postMessage({
      cmd: 'thread_start',
      fn,
      arg,
      thread
    });
  }
}

// ==========================================
// 2. Main Browser Thread Initialization
// ==========================================
if (isBrowser) {
  const scriptUrl = document.currentScript ? document.currentScript.src : 'runtime.js';
  const printOutput = (window.Module && window.Module.print) || console.log;
  const printError = (window.Module && window.Module.printErr) || console.error;

  async function initRuntime() {
    // Spawn the single delegate worker
    const delegateWorker = new Worker(scriptUrl);

    let delegateReadyResolve;
    const delegateReadyPromise = new Promise((resolve) => {
      delegateReadyResolve = resolve;
    });

    delegateWorker.onmessage = function(e) {
      const data = e.data;
      if (!data) return;
      if (data.cmd === 'delegate_ready') {
        delegateReadyResolve();
      } else if (data.cmd === 'log') {
        printOutput(data.text);
      } else if (data.cmd === 'error') {
        printError(data.error);
      }
    };

    const sharedHeapRootGlobal = createSharedHeapRootGlobal(null);

    const mainImports = {
      env: {
        thread_supports_wait: threadSupportsWait,
        shared_heap_root: sharedHeapRootGlobal,
        console_log: printOutput,
        js_thread_spawn: (fn, arg, thread) => {
          delegateWorker.postMessage({ cmd: 'thread_spawn', fn, arg, thread });
        },
        js_thread_exit: () => {
          delegateWorker.postMessage({ cmd: 'shutdown' });
        }
      }
    };

    const { module: wasmModule, instance: mainInstance } =
      await WebAssembly.instantiateStreaming(fetch('main.wasm'), mainImports, compileOptions);

    // After module instantiation (and its Wasm start function), sharedHeapRootGlobal.value contains
    // the initialized root object (if set).
    delegateWorker.postMessage({
      cmd: 'init_delegate',
      wasmModule,
      scriptUrl,
      sharedHeapRoot: sharedHeapRootGlobal.value
    });

    // Wait for the delegate worker to confirm it is ready before invoking main()
    await delegateReadyPromise;

    window.Module = window.Module || {};
    window.Module.wasmExports = mainInstance.exports;

    // Run main entry point
    try {
      mainInstance.exports.main();
    } catch (err) {
      printError(String(err));
    }
  }

  if (document.readyState === 'loading') {
    window.addEventListener('DOMContentLoaded', initRuntime);
  } else {
    initRuntime();
  }
}
