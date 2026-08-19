(module
  ;; Function type for worker thread routines
  (type $thread_fn (shared (func (param (ref null (shared any))))))

  ;; Thread lifecycle state struct (id, status: 0=RUNNING, 1=EXITED, waitqueue)
  (type $thread (shared (struct
    (field $id i32)
    (field $status (mut i32))
    (field $waitqueue (ref (shared waitqueue)))
  )))

  ;; Root shared heap structure holding runtime state and user payload
  (type $shared_heap_root (shared (struct
    (field $tid_counter (mut i32))
    (field $user_data (mut (ref null (shared any))))
  )))

  ;; Imported immutable global: 1 if atomic waiting is supported, 0 otherwise
  (global $thread_supports_wait (import "env" "thread_supports_wait") i32)

  ;; Imported mutable shared heap root global from host environment
  (global $shared_heap_root (import "env" "shared_heap_root") (mut (ref null (shared any))))

  ;; Imported host functions from JS environment ("env")
  (import "env" "console_log" (func $env_console_log (param (ref null (shared extern)))))
  (import "env" "js_thread_spawn" (func $env_js_thread_spawn (param (ref $thread_fn)) (param (ref null (shared any))) (param (ref $thread))))
  (import "env" "js_thread_exit" (func $env_js_thread_exit))

  ;; Module globals
  (global $current_thread (mut (ref null $thread)) (ref.null (shared none)))

  ;; Module start function: initializes shared heap root and main thread descriptor
  (func $init
    (if (ref.is_null (global.get $shared_heap_root))
      (then
        (global.set $shared_heap_root
          (struct.new $shared_heap_root
            (i32.const 1)
            (ref.null (shared none))
          )
        )
        (global.set $current_thread
          (struct.new $thread
            (call $alloc_tid)
            (i32.const 0)
            (waitqueue.new)
          )
        )
      )
    )
  )
  (start $init)

  ;; Allocates the next monotonic 32-bit TID
  (func $alloc_tid (result i32)
    (struct.atomic.rmw.add $shared_heap_root $tid_counter
      (ref.cast (ref $shared_heap_root) (global.get $shared_heap_root))
      (i32.const 1)
    )
  )

  ;; Retrieves the user data from the shared heap root
  (func (export "get_shared_root") (result (ref null (shared any)))
    (struct.get $shared_heap_root $user_data
      (ref.cast (ref $shared_heap_root) (global.get $shared_heap_root))
    )
  )

  ;; Sets the user data in the shared heap root
  (func (export "set_shared_root") (param $data (ref null (shared any)))
    (struct.set $shared_heap_root $user_data
      (ref.cast (ref $shared_heap_root) (global.get $shared_heap_root))
      (local.get $data)
    )
  )

  ;; Queries whether atomic waiting is supported (1 if struct.wait is allowed, 0 if main thread)
  (func (export "thread_supports_wait") (result i32)
    (global.get $thread_supports_wait)
  )

  ;; Prints a shared externref (JS string) to the console
  (func (export "console_log") (param $str (ref null (shared extern)))
    (call $env_console_log (local.get $str))
  )

  ;; Spawns a new thread asynchronously in the RUNNING state (0)
  (func (export "thread_spawn") (param $fn (ref $thread_fn)) (param $arg (ref null (shared any))) (result (ref $thread))
    (local $t (ref $thread))
    ;; Create thread descriptor directly in status 0 (RUNNING)
    (local.set $t (struct.new $thread
      (call $alloc_tid)
      (i32.const 0)
      (waitqueue.new)
    ))
    ;; Inform host environment / delegate worker to start the thread
    (call $env_js_thread_spawn
      (local.get $fn)
      (local.get $arg)
      (local.get $t)
    )
    (local.get $t)
  )

  ;; Worker thread entry trampoline
  (func (export "_thread_entry") (param $thread (ref $thread)) (param $fn (ref $thread_fn)) (param $arg (ref null (shared any)))
    (global.set $current_thread (local.get $thread))
    (call_ref $thread_fn
      (local.get $arg)
      (local.get $fn)
    )
  )

  ;; Terminates the calling thread
  (func (export "thread_exit")
    (struct.atomic.set $thread $status (global.get $current_thread) (i32.const 1))
    (drop (waitqueue.notify (struct.get $thread $waitqueue (global.get $current_thread)) (i32.const -1)))
    (call $env_js_thread_exit)
  )

  ;; Waits for target thread to exit (status == 1).
  (func (export "thread_join") (param $thread (ref $thread)) (result i32)
    (if (global.get $thread_supports_wait)
      (then
        (drop
          (struct.wait $thread $status
            (local.get $thread)
            (struct.get $thread $waitqueue (local.get $thread))
            (i32.const 0)
            (i64.const -1)
          )
        )
      )
      (else
        ;; Main browser thread: spin with (pause)
        (loop $spin_loop
          (if (i32.ne (struct.atomic.get $thread $status (local.get $thread)) (i32.const 1))
            (then
              (pause)
              (br $spin_loop)
            )
          )
        )
      )
    )
    (i32.const 0)
  )
)
