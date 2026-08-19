(module
  ;; Function types matching runtime interface
  (type $thread_fn (shared (func (param (ref null (shared any))))))
  (type $thread (shared (struct
    (field $id i32)
    (field $status (mut i32))
    (field $waitqueue (ref (shared waitqueue)))
  )))
  (type $mutex (shared (struct (field $state (mut i32)) (field $waitqueue (ref (shared waitqueue))))))
  (type $thread_arg (shared (struct (field $id i32) (field $lock (ref $mutex)))))

  ;; Imported string constant (prefix)
  (import "'" "hello from thread " (global $str_prefix (ref (shared extern))))

  ;; String builtins from "wasm:js-string"
  (import "wasm:js-string" "concat" (func $string_concat (param (ref null (shared extern)) (ref null (shared extern))) (result (ref (shared extern)))))
  (import "wasm:js-string" "fromCodePoint" (func $string_fromCodePoint (param i32) (result (ref (shared extern)))))

  ;; Runtime wrappers imported from "runtime"
  (import "runtime" "thread_spawn" (func $thread_spawn (param (ref $thread_fn)) (param (ref null (shared any))) (result (ref $thread))))
  (import "runtime" "thread_join" (func $thread_join (param (ref $thread)) (result i32)))
  (import "runtime" "thread_exit" (func $thread_exit))
  (import "runtime" "console_log" (func $console_log (param (ref null (shared extern)))))

  ;; Mutex synchronization primitives imported from "common/mutex"
  (import "common/mutex" "mutex_new" (func $mutex_new (result (ref $mutex))))
  (import "common/mutex" "mutex_lock" (func $mutex_lock (param (ref $mutex))))
  (import "common/mutex" "mutex_unlock" (func $mutex_unlock (param (ref $mutex))))

  ;; Worker thread function executed when spawned
  (func $worker (type $thread_fn) (param $arg (ref null (shared any)))
    (local $info (ref $thread_arg))
    (local $id i32)
    (local $lock (ref $mutex))
    (local $id_str (ref (shared extern)))
    (local $msg (ref (shared extern)))

    (local.set $info (ref.cast (ref $thread_arg) (local.get $arg)))
    (local.set $id (struct.get $thread_arg $id (local.get $info)))
    (local.set $lock (struct.get $thread_arg $lock (local.get $info)))

    ;; Construct "hello from thread <id>" using string builtins
    ;; 48 is ASCII '0', so 48 + id gives the digit character code
    (local.set $id_str (call $string_fromCodePoint (i32.add (i32.const 48) (local.get $id))))
    (local.set $msg (call $string_concat (global.get $str_prefix) (local.get $id_str)))

    ;; Synchronize console output using the shared waitqueue mutex
    (call $mutex_lock (local.get $lock))
    (call $console_log (local.get $msg))
    (call $mutex_unlock (local.get $lock))

    ;; Signal thread exit
    (call $thread_exit)
  )

  ;; Main entry point function exported for runtime
  (func (export "main")
    (local $lock (ref $mutex))
    (local $t1 (ref $thread))
    (local $t2 (ref $thread))
    (local $t3 (ref $thread))

    ;; Initialize the shared waitqueue mutex
    (local.set $lock (call $mutex_new))

    ;; Spawn 3 worker threads with IDs 1, 2, and 3
    (local.set $t1 (call $thread_spawn (ref.func $worker) (struct.new $thread_arg (i32.const 1) (local.get $lock))))
    (local.set $t2 (call $thread_spawn (ref.func $worker) (struct.new $thread_arg (i32.const 2) (local.get $lock))))
    (local.set $t3 (call $thread_spawn (ref.func $worker) (struct.new $thread_arg (i32.const 3) (local.get $lock))))

    ;; Wait for all worker threads to finish
    (drop (call $thread_join (local.get $t1)))
    (drop (call $thread_join (local.get $t2)))
    (drop (call $thread_join (local.get $t3)))

    ;; Clean up runtime workers
    (call $thread_exit)
  )
)
