(module
  ;; Function types for worker thread routines
  (type $thread_fn (shared (func (param (ref null (shared any))))))
  (type $task (shared (struct (field (ref $thread_fn)) (field (ref null (shared any))))))

  ;; Imports from JS runtime environment ("env")
  (global $shared_heap_root (export "_shared_heap_root") (import "env" "_shared_heap_root") (mut (ref null (shared any))))
  (import "env" "console_log" (func $c_console_log (param externref)))

  ;; Imports from the C runtime module ("runtime")
  (import "runtime" "runtime_pthread_create" (func $c_pthread_create (result i32)))
  (import "runtime" "runtime_pthread_join" (func $c_pthread_join (param i32) (result i32)))
  (import "runtime" "runtime_thread_supports_wait" (func $c_thread_supports_wait (result i32)))

  ;; Globals for Emscripten's -sSHARED_WASMGC thread state transfer (exported for JS runtime)
  (global $gc_thread_state (export "_gc_thread_state") (mut (ref null (shared any))) (ref.null (shared none)))
  (global $gc_spawn_arg (export "_gc_spawn_arg") (mut (ref null (shared any))) (ref.null (shared none)))

  ;; Queries whether the calling thread supports atomic waiting (1 = worker, 0 = main thread)
  (func (export "thread_supports_wait") (result i32)
    (call $c_thread_supports_wait)
  )

  ;; Prints an externref (JS string) to the console
  (func (export "console_log") (param $str externref)
    (call $c_console_log (local.get $str))
  )

  ;; Spawns a new worker thread running the given function reference and argument.
  (func (export "spawn_thread") (param $fn (ref $thread_fn)) (param $arg (ref null (shared any))) (result i32)
    (local $tid i32)
    (global.set $gc_spawn_arg (struct.new $task (local.get $fn) (local.get $arg)))
    (local.set $tid (call $c_pthread_create))
    (global.set $gc_spawn_arg (ref.null (shared none)))
    (local.get $tid)
  )

  ;; Joins a thread by thread ID, returning the join status code.
  (func (export "join_thread") (param $tid i32) (result i32)
    (call $c_pthread_join (local.get $tid))
  )

  ;; Thread entry point invoked by worker threads in runtime.c
  (func (export "wasm_thread_entry")
    (local $task (ref $task))
    (local.set $task (ref.cast (ref $task) (global.get $gc_thread_state)))
    (call_ref $thread_fn
      (struct.get $task 1 (local.get $task))
      (struct.get $task 0 (local.get $task))
    )
  )
)
