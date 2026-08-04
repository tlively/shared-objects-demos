(module
  ;; Shared types
  (type $thread_fn (shared (func (param (ref null (shared any))))))
  (type $mutex (shared (struct (field (mut i32)) (field (ref (shared waitqueue))))))
  (type $philosopher_arg (shared (struct
    (field i32)            ;; philosopher id (0..4)
    (field (ref $mutex))   ;; first fork to acquire
    (field (ref $mutex))   ;; second fork to acquire
    (field i32)            ;; total eating rounds
    (field (ref $mutex))   ;; console log mutex
  )))

  ;; String constants
  (import "'" "Philosopher " (global $str_philo (ref extern)))
  (import "'" " is thinking" (global $str_thinking (ref extern)))
  (import "'" " is eating (round " (global $str_eating (ref extern)))
  (import "'" ")" (global $str_rparen (ref extern)))
  (import "'" " is done" (global $str_done (ref extern)))
  (import "'" "All philosophers have finished dining" (global $str_all_done (ref extern)))

  ;; String builtins from "wasm:js-string"
  (import "wasm:js-string" "concat" (func $string_concat (param externref externref) (result (ref extern))))
  (import "wasm:js-string" "fromCodePoint" (func $string_fromCodePoint (param i32) (result (ref extern))))

  ;; Runtime wrappers imported from "runtime"
  (import "runtime" "spawn_thread" (func $spawn_thread (param (ref $thread_fn)) (param (ref null (shared any))) (result i32)))
  (import "runtime" "join_thread" (func $join_thread (param i32) (result i32)))
  (import "runtime" "console_log" (func $console_log (param externref)))

  ;; Mutex synchronization primitives imported from "common/mutex"
  (import "common/mutex" "mutex_new" (func $mutex_new (result (ref $mutex))))
  (import "common/mutex" "mutex_lock" (func $mutex_lock (param (ref $mutex))))
  (import "common/mutex" "mutex_unlock" (func $mutex_unlock (param (ref $mutex))))

  ;; Helper to log philosopher status: "Philosopher <id><suffix>"
  (func $log_status (param $id i32) (param $suffix (ref extern)) (param $log_lock (ref $mutex))
    (local $id_str (ref extern))
    (local $msg (ref extern))
    (local.set $id_str (call $string_fromCodePoint (i32.add (i32.const 48) (local.get $id))))
    (local.set $msg (call $string_concat (call $string_concat (global.get $str_philo) (local.get $id_str)) (local.get $suffix)))
    (call $mutex_lock (local.get $log_lock))
    (call $console_log (local.get $msg))
    (call $mutex_unlock (local.get $log_lock))
  )

  ;; Helper to log philosopher eating: "Philosopher <id> is eating (round <round>)"
  (func $log_eating (param $id i32) (param $round i32) (param $log_lock (ref $mutex))
    (local $id_str (ref extern))
    (local $round_str (ref extern))
    (local $prefix (ref extern))
    (local $msg (ref extern))
    (local.set $id_str (call $string_fromCodePoint (i32.add (i32.const 48) (local.get $id))))
    (local.set $round_str (call $string_fromCodePoint (i32.add (i32.const 48) (local.get $round))))
    (local.set $prefix (call $string_concat (call $string_concat (global.get $str_philo) (local.get $id_str)) (global.get $str_eating)))
    (local.set $msg (call $string_concat (call $string_concat (local.get $prefix) (local.get $round_str)) (global.get $str_rparen)))
    (call $mutex_lock (local.get $log_lock))
    (call $console_log (local.get $msg))
    (call $mutex_unlock (local.get $log_lock))
  )

  ;; Small spin delay to simulate thinking / eating
  (func $delay
    (local $i i32)
    (local.set $i (i32.const 200))
    (loop $spin
      (pause)
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br_if $spin (i32.gt_s (local.get $i) (i32.const 0)))
    )
  )

  ;; Philosopher thread routine
  (func $philosopher (type $thread_fn) (param $arg (ref null (shared any)))
    (local $info (ref $philosopher_arg))
    (local $id i32)
    (local $fork_a (ref $mutex))
    (local $fork_b (ref $mutex))
    (local $total_rounds i32)
    (local $log_lock (ref $mutex))
    (local $round i32)

    (local.set $info (ref.cast (ref $philosopher_arg) (local.get $arg)))
    (local.set $id (struct.get $philosopher_arg 0 (local.get $info)))
    (local.set $fork_a (struct.get $philosopher_arg 1 (local.get $info)))
    (local.set $fork_b (struct.get $philosopher_arg 2 (local.get $info)))
    (local.set $total_rounds (struct.get $philosopher_arg 3 (local.get $info)))
    (local.set $log_lock (struct.get $philosopher_arg 4 (local.get $info)))

    (local.set $round (i32.const 1))
    (loop $eat_loop
      ;; Think
      (call $log_status (local.get $id) (global.get $str_thinking) (local.get $log_lock))
      (call $delay)

      ;; Acquire forks in strict resource hierarchy order (avoids deadlocks)
      (call $mutex_lock (local.get $fork_a))
      (call $mutex_lock (local.get $fork_b))

      ;; Eat
      (call $log_eating (local.get $id) (local.get $round) (local.get $log_lock))
      (call $delay)

      ;; Release forks
      (call $mutex_unlock (local.get $fork_b))
      (call $mutex_unlock (local.get $fork_a))

      ;; Next round
      (local.set $round (i32.add (local.get $round) (i32.const 1)))
      (br_if $eat_loop (i32.le_s (local.get $round) (local.get $total_rounds)))
    )

    ;; Done dining
    (call $log_status (local.get $id) (global.get $str_done) (local.get $log_lock))
  )

  ;; Main entry point function exported for runtime.c main()
  (func (export "wasm_main")
    ;; 5 fork mutexes
    (local $fork0 (ref $mutex))
    (local $fork1 (ref $mutex))
    (local $fork2 (ref $mutex))
    (local $fork3 (ref $mutex))
    (local $fork4 (ref $mutex))

    ;; Mutex for serializing console log output
    (local $log_lock (ref $mutex))

    ;; Thread IDs
    (local $t0 i32)
    (local $t1 i32)
    (local $t2 i32)
    (local $t3 i32)
    (local $t4 i32)

    ;; Allocate mutexes
    (local.set $fork0 (call $mutex_new))
    (local.set $fork1 (call $mutex_new))
    (local.set $fork2 (call $mutex_new))
    (local.set $fork3 (call $mutex_new))
    (local.set $fork4 (call $mutex_new))
    (local.set $log_lock (call $mutex_new))

    ;; Spawn 5 philosopher threads with asymmetric fork ordering on philosopher 4 to prevent deadlock:
    ;; Philosopher 0: fork 0, fork 1
    (local.set $t0 (call $spawn_thread (ref.func $philosopher)
      (struct.new $philosopher_arg (i32.const 0) (local.get $fork0) (local.get $fork1) (i32.const 3) (local.get $log_lock))))

    ;; Philosopher 1: fork 1, fork 2
    (local.set $t1 (call $spawn_thread (ref.func $philosopher)
      (struct.new $philosopher_arg (i32.const 1) (local.get $fork1) (local.get $fork2) (i32.const 3) (local.get $log_lock))))

    ;; Philosopher 2: fork 2, fork 3
    (local.set $t2 (call $spawn_thread (ref.func $philosopher)
      (struct.new $philosopher_arg (i32.const 2) (local.get $fork2) (local.get $fork3) (i32.const 3) (local.get $log_lock))))

    ;; Philosopher 3: fork 3, fork 4
    (local.set $t3 (call $spawn_thread (ref.func $philosopher)
      (struct.new $philosopher_arg (i32.const 3) (local.get $fork3) (local.get $fork4) (i32.const 3) (local.get $log_lock))))

    ;; Philosopher 4: fork 0, fork 4 (lower index fork 0 first)
    (local.set $t4 (call $spawn_thread (ref.func $philosopher)
      (struct.new $philosopher_arg (i32.const 4) (local.get $fork0) (local.get $fork4) (i32.const 3) (local.get $log_lock))))

    ;; Wait for all philosophers to finish
    (drop (call $join_thread (local.get $t0)))
    (drop (call $join_thread (local.get $t1)))
    (drop (call $join_thread (local.get $t2)))
    (drop (call $join_thread (local.get $t3)))
    (drop (call $join_thread (local.get $t4)))

    ;; Print final completion message
    (call $mutex_lock (local.get $log_lock))
    (call $console_log (global.get $str_all_done))
    (call $mutex_unlock (local.get $log_lock))
  )
)
