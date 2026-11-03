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
    [spawned : thread.ThreadSpawnResult
      (with-scratch
        (unsafe
          (thread.spawn worker 0)))]
    (match spawned
      [(thread.ThreadSpawnErr _) 1]
      [(thread.ThreadSpawnOk task)
        (let
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
            2))])))