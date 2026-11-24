(import stdlib.thread)

(define release-worker : i64
  0)

(define (worker [_arg : i64]) : i64
  (while (=
    (unsafe
      (atomic-load (ptr-addr-of release-worker)))
    0)
    unit)
  42)

(define (main) : i64
  (let
    ;; `Thread` is a move-only OS handle and intentionally has no `gen-clone`
    ;; hook, so return its raw fields across `with-scratch` to keep testing
    ;; that the worker stack and control page outlive scratch arena destruction.
    [spawned : (Tuple bool i64 i64 i64)
      (with-scratch
        (match (unsafe
          (thread.spawn worker 0))
          [(thread.ThreadSpawnErr _) (tuple false 0 0 0)]
          [(thread.ThreadSpawnOk task)
            (tuple true task.handle task.clear-tid-addr task.result-addr)]))]
    (if (not (tuple-ref spawned 0))
      1
      (let
        [task : thread.Thread
          (thread.Thread
            (tuple-ref spawned 1)
            (tuple-ref spawned 2)
            (tuple-ref spawned 3)
            "")]
        [control : i64 task.clear-tid-addr]
        [base : i64
          (unsafe
            (thread.read-i64 (+ control 16)))]
        [resident : i64 0]
        [vector : i64
          (unsafe
            (cast (ptr->int (ptr-addr-of resident)) : i64))]
        [before : i64
          (unsafe
            (syscall 27 base 4096 vector))]
        [timed : thread.ThreadWaitResult
          (unsafe
            (thread.wait-for (& task) 0))]
        [still-live : i64
          (unsafe
            (syscall 27 base 4096 vector))]
        [_release : unit
          (unsafe
            (atomic-store! (ptr-addr-of release-worker) 1))]
        [ready : thread.ThreadWaitResult
          (unsafe
            (thread.wait-for (& task) 1000))]
        [after-ready : i64
          (unsafe
            (syscall 27 base 4096 vector))]
        [joined : thread.ThreadJoinResult
          (unsafe
            (thread.join task))]
        [after-join : i64
          (unsafe
            (syscall 27 base 4096 vector))]
        [control-after : i64
          (unsafe
            (syscall 27 control 4096 vector))]
        (if (and
          (= before 0)
          (= still-live 0)
          (= after-ready 0)
          (= after-join -12)
          (= control-after -12)
          (match timed
            [(thread.ThreadWaitTimedOut) true]
            [_ false])
          (match ready
            [(thread.ThreadWaitReady) true]
            [_ false])
          (match joined
            [(thread.ThreadJoinOk value) (= value 42)]
            [_ false]))
          42
          2)))))