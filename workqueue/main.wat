(module
  ;; Shared types
  (type $thread_fn (shared (func (param (ref null (shared any))))))
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
  (type $metrics (shared (struct
    (field $tasks_completed (mut i32))
    (field $worker_count (mut i32))
  )))
  (type $context (shared (struct
    (field $queue (ref $queue))
    (field $metrics (ref $metrics))
  )))

  ;; Imports from JS runtime environment ("env")
  (global $shared_heap_root (import "env" "_shared_heap_root") (mut (ref null (shared any))))

  ;; Dependencies from common/queue and runtime
  (import "common/queue" "queue_new" (func $queue_new (result (ref $queue))))
  (import "common/queue" "queue_push" (func $queue_push (param (ref $queue)) (param (ref null (shared any)))))
  (import "common/queue" "queue_pop" (func $queue_pop (param (ref $queue)) (result (ref null (shared any)))))
  (import "common/queue" "queue_size" (func $queue_size (param (ref $queue)) (result i32)))

  (import "runtime" "spawn_thread" (func $spawn_thread (param (ref $thread_fn)) (param (ref null (shared any))) (result i32)))

  ;; Helper to retrieve the shared context from the runtime shared heap root
  (func $get_context (result (ref null $context))
    (if (ref.is_null (global.get $shared_heap_root))
      (then (return (ref.null (shared none))))
    )
    (ref.cast (ref $context) (global.get $shared_heap_root))
  )

  ;; Startup function: allocates and assigns the shared context into _shared_heap_root on main thread
  (func $init
    (local $q (ref $queue))
    (local $m (ref $metrics))
    (local $ctx (ref $context))

    (if (ref.is_null (global.get $shared_heap_root))
      (then
        (local.set $q (call $queue_new))
        (local.set $m (struct.new $metrics (i32.const 0) (i32.const 0)))
        (local.set $ctx (struct.new $context (local.get $q) (local.get $m)))
        (global.set $shared_heap_root (local.get $ctx))
      )
    )
  )
  (start $init)

  ;; Recursive Fibonacci computation (work item payload)
  (func $fib (param $n i32) (result i32)
    (if (result i32) (i32.le_s (local.get $n) (i32.const 1))
      (then (local.get $n))
      (else
        (i32.add
          (call $fib (i32.sub (local.get $n) (i32.const 1)))
          (call $fib (i32.sub (local.get $n) (i32.const 2)))
        )
      )
    )
  )

  ;; Small throttle delay for producer when queue backlog is sufficient
  (func $producer_delay
    (local $i i32)
    (local.set $i (i32.const 5000))
    (loop $spin
      (pause)
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br_if $spin (i32.gt_s (local.get $i) (i32.const 0)))
    )
  )

  ;; Producer thread routine: continuously feeds fibonacci work items into the queue as shared i31 references
  (func $producer_fn (type $thread_fn) (param $arg (ref null (shared any)))
    (local $ctx (ref $context))
    (local $q (ref $queue))
    (local.set $ctx (ref.cast (ref $context) (local.get $arg)))
    (local.set $q (struct.get $context $queue (local.get $ctx)))

    (loop $prod_loop
      ;; If queue already has enough pending items, throttle before pushing more
      (if (i32.gt_s (call $queue_size (local.get $q)) (i32.const 30))
        (then
          (call $producer_delay)
        )
        (else
          (call $queue_push (local.get $q) (ref.i31_shared (i32.const 24)))
        )
      )
      (br $prod_loop)
    )
  )

  ;; Worker thread routine: dequeues shared i31 items, computes fibonacci, and increments atomic counter
  (func $worker_fn (type $thread_fn) (param $arg (ref null (shared any)))
    (local $ctx (ref $context))
    (local $q (ref $queue))
    (local $m (ref $metrics))
    (local $item (ref null (shared any)))
    (local $n i32)
    (local $res i32)

    (local.set $ctx (ref.cast (ref $context) (local.get $arg)))
    (local.set $q (struct.get $context $queue (local.get $ctx)))
    (local.set $m (struct.get $context $metrics (local.get $ctx)))

    (loop $work_loop
      (local.set $item (call $queue_pop (local.get $q)))
      (local.set $n (i31.get_u (ref.cast (ref (shared i31)) (local.get $item))))
      (local.set $res (call $fib (local.get $n)))
      (drop (struct.atomic.rmw.add $metrics $tasks_completed (local.get $m) (i32.const 1)))
      (br $work_loop)
    )
  )

  ;; Spawns an additional worker thread on demand (callable from JS / UI)
  (func $add_worker (export "add_worker") (result i32)
    (local $ctx (ref null $context))
    (local $m (ref $metrics))
    (local $count i32)
    (local.set $ctx (call $get_context))
    (if (ref.is_null (local.get $ctx))
      (then (return (i32.const 0)))
    )
    (local.set $m (struct.get $context $metrics (ref.as_non_null (local.get $ctx))))
    (drop (call $spawn_thread (ref.func $worker_fn) (local.get $ctx)))
    (local.set $count (i32.add (struct.atomic.rmw.add $metrics $worker_count (local.get $m) (i32.const 1)) (i32.const 1)))
    (local.get $count)
  )

  ;; Queries the total number of tasks completed so far (callable from JS / UI)
  (func (export "get_tasks_completed") (result i32)
    (local $ctx (ref null $context))
    (local.set $ctx (call $get_context))
    (if (ref.is_null (local.get $ctx))
      (then (return (i32.const 0)))
    )
    (struct.atomic.get $metrics $tasks_completed (struct.get $context $metrics (ref.as_non_null (local.get $ctx))))
  )

  ;; Queries the number of active worker threads (callable from JS / UI)
  (func (export "get_worker_count") (result i32)
    (local $ctx (ref null $context))
    (local.set $ctx (call $get_context))
    (if (ref.is_null (local.get $ctx))
      (then (return (i32.const 0)))
    )
    (struct.atomic.get $metrics $worker_count (struct.get $context $metrics (ref.as_non_null (local.get $ctx))))
  )

  ;; Queries the current queue length (callable from JS / UI)
  (func (export "get_queue_size") (result i32)
    (local $ctx (ref null $context))
    (local.set $ctx (call $get_context))
    (if (ref.is_null (local.get $ctx))
      (then (return (i32.const 0)))
    )
    (call $queue_size (struct.get $context $queue (ref.as_non_null (local.get $ctx))))
  )

  ;; Main entry point function exported for runtime.c main()
  (func (export "wasm_main")
    (local $ctx (ref null $context))
    (local.set $ctx (call $get_context))
    (if (ref.is_null (local.get $ctx))
      (then (return))
    )

    ;; Spawn producer thread
    (drop (call $spawn_thread (ref.func $producer_fn) (local.get $ctx)))

    ;; Spawn initial worker threads (2 workers)
    (drop (call $add_worker))
    (drop (call $add_worker))
  )
)
