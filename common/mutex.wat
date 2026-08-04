(module
  ;; Mutex type with a lock state field (0 = unlocked, 1 = locked) and a waitqueue reference
  (type $mutex (shared (struct (field $state (mut i32)) (field $waitqueue (ref (shared waitqueue))))))

  ;; Query the runtime to check if the current thread supports atomic waiting
  (import "runtime" "thread_supports_wait" (func $thread_supports_wait (result i32)))

  ;; Allocates and initializes a new mutex with a fresh waitqueue
  (func (export "mutex_new") (result (ref $mutex))
    (struct.new $mutex (i32.const 0) (waitqueue.new))
  )

  ;; Attempts to acquire the mutex without blocking. Returns 1 if acquired, 0 otherwise.
  (func $mutex_try_lock (export "mutex_try_lock") (param $m (ref $mutex)) (result i32)
    (i32.eqz (struct.atomic.rmw.cmpxchg $mutex $state (local.get $m) (i32.const 0) (i32.const 1)))
  )

  ;; Acquires the mutex. If the lock is held:
  ;; - Spins up to 40 times using (pause) before waiting.
  ;; - If the thread supports waiting (workers), it suspends via struct.wait on the waitqueue.
  ;; - If the thread does not support waiting (main browser thread), it continues spinning.
  (func (export "mutex_lock") (param $m (ref $mutex))
    (local $can_wait i32)
    (local $spin i32)
    (local.set $can_wait (call $thread_supports_wait))
    (block $acquired
      (loop $retry
        ;; Bounded spin loop: spin up to 40 times before waiting
        (local.set $spin (i32.const 40))
        (loop $spin_loop
          (if (call $mutex_try_lock (local.get $m))
            (then (br $acquired))
          )
          (pause)
          (local.set $spin (i32.sub (local.get $spin) (i32.const 1)))
          (br_if $spin_loop (i32.gt_s (local.get $spin) (i32.const 0)))
        )

        (if (local.get $can_wait)
          (then
            (drop
              (struct.wait $mutex $state
                (local.get $m)
                (struct.get $mutex $waitqueue (local.get $m))
                (i32.const 1)
                (i64.const -1)
              )
            )
          )
        )
        (br $retry)
      )
    )
  )

  ;; Releases the mutex and notifies one waiting thread on the waitqueue.
  (func (export "mutex_unlock") (param $m (ref $mutex))
    (drop (struct.atomic.rmw.xchg $mutex $state (local.get $m) (i32.const 0)))
    (drop (waitqueue.notify (struct.get $mutex $waitqueue (local.get $m)) (i32.const 1)))
  )
)
