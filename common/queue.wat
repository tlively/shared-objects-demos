(module
  ;; Shared types
  (type $mutex (shared (struct (field $state (mut i32)) (field $waitqueue (ref (shared waitqueue))))))
  (type $node (shared (struct (field $val (ref null (shared any))) (field $next (mut (ref null $node))))))
  (type $queue (shared (struct
    (field $lock (ref $mutex))
    (field $head (mut (ref null $node)))
    (field $tail (mut (ref null $node)))
    (field $size (mut i32))
    (field $waitqueue (ref (shared waitqueue)))
    (field $signal (mut i32))
  )))

  ;; Dependencies
  (import "common/mutex" "mutex_new" (func $mutex_new (result (ref $mutex))))
  (import "common/mutex" "mutex_lock" (func $mutex_lock (param (ref $mutex))))
  (import "common/mutex" "mutex_unlock" (func $mutex_unlock (param (ref $mutex))))
  (import "runtime" "thread_supports_wait" (func $thread_supports_wait (result i32)))

  ;; Allocates a new MPMC queue
  (func (export "queue_new") (result (ref $queue))
    (struct.new $queue
      (call $mutex_new)
      (ref.null (shared none))
      (ref.null (shared none))
      (i32.const 0)
      (waitqueue.new)
      (i32.const 0)
    )
  )

  ;; Enqueues a shared work item and wakes one waiting worker
  (func (export "queue_push") (param $q (ref $queue)) (param $val (ref null (shared any)))
    (local $node (ref $node))
    (local $lock (ref $mutex))
    (local $tail (ref null $node))

    (local.set $lock (struct.get $queue $lock (local.get $q)))
    (local.set $node (struct.new $node (local.get $val) (ref.null (shared none))))

    (call $mutex_lock (local.get $lock))

    (local.set $tail (struct.get $queue $tail (local.get $q)))
    (if (ref.is_null (local.get $tail))
      (then
        (struct.set $queue $head (local.get $q) (local.get $node))
        (struct.set $queue $tail (local.get $q) (local.get $node))
      )
      (else
        (struct.set $node $next (ref.as_non_null (local.get $tail)) (local.get $node))
        (struct.set $queue $tail (local.get $q) (local.get $node))
      )
    )
    (struct.set $queue $size (local.get $q) (i32.add (struct.get $queue $size (local.get $q)) (i32.const 1)))

    ;; Update signal counter and notify waiting consumer
    (struct.set $queue $signal (local.get $q) (i32.add (struct.get $queue $signal (local.get $q)) (i32.const 1)))
    (drop (waitqueue.notify (struct.get $queue $waitqueue (local.get $q)) (i32.const 1)))

    (call $mutex_unlock (local.get $lock))
  )

  ;; Dequeues a work item, blocking on the waitqueue if empty
  (func (export "queue_pop") (param $q (ref $queue)) (result (ref null (shared any)))
    (local $lock (ref $mutex))
    (local $head (ref null $node))
    (local $val (ref null (shared any)))
    (local $can_wait i32)
    (local $sig i32)

    (local.set $lock (struct.get $queue $lock (local.get $q)))
    (local.set $can_wait (call $thread_supports_wait))

    (loop $retry
      (call $mutex_lock (local.get $lock))
      (local.set $head (struct.get $queue $head (local.get $q)))
      (if (i32.eqz (ref.is_null (local.get $head)))
        (then
          ;; Extract head item
          (local.set $val (struct.get $node $val (ref.as_non_null (local.get $head))))
          (struct.set $queue $head (local.get $q) (struct.get $node $next (ref.as_non_null (local.get $head))))
          (if (ref.is_null (struct.get $queue $head (local.get $q)))
            (then
              (struct.set $queue $tail (local.get $q) (ref.null (shared none)))
            )
          )
          (struct.set $queue $size (local.get $q) (i32.sub (struct.get $queue $size (local.get $q)) (i32.const 1)))
          (call $mutex_unlock (local.get $lock))
          (return (local.get $val))
        )
      )

      ;; Queue is empty: capture signal counter and unlock before waiting
      (local.set $sig (struct.get $queue $signal (local.get $q)))
      (call $mutex_unlock (local.get $lock))

      (if (local.get $can_wait)
        (then
          (drop
            (struct.wait $queue $signal
              (local.get $q)
              (struct.get $queue $waitqueue (local.get $q))
              (local.get $sig)
              (i64.const -1)
            )
          )
        )
        (else
          (pause)
        )
      )
      (br $retry)
    )
    (unreachable)
  )

  ;; Queries the current queue length
  (func (export "queue_size") (param $q (ref $queue)) (result i32)
    (local $lock (ref $mutex))
    (local $sz i32)
    (local.set $lock (struct.get $queue $lock (local.get $q)))
    (call $mutex_lock (local.get $lock))
    (local.set $sz (struct.get $queue $size (local.get $q)))
    (call $mutex_unlock (local.get $lock))
    (local.get $sz)
  )
)
