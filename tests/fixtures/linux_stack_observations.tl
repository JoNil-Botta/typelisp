;; Observation workload: identical source against base/head stdlib roots.
;; It measures the public raw-spawn lifecycle, not a replacement stack helper.
(import stdlib.thread)
(import stdlib.io)
(import stdlib.iterator)

(define release-worker : i64
  0)

(define (now-ns) : i64
  (let
    [stamp : (Array i64 2) (array 0 0)]
    (unsafe
      (when
        (< (syscall 228 1 (cast (ptr->int (ptr-addr-of stamp)) : i64)) 0)
        (return -1)))
    (+ (* (array-ref stamp 0) 1000000000) (array-ref stamp 1))))

(define (vmas) : i64
  (let
    [path : String "/proc/self/maps"]
    [name : (__tl_dyn-array u8) (io.c-string (& path))]
    [data : (__tl_dyn-array u8) (__tl_make-array u8 4096)]
    [fd : i64
      (unsafe
        (syscall 2 (thread.array-u8-addr (& name)) 0 0))]
    [count : i64 0]
    (when (< fd 0) (return -1))
    ;; procfs is a stream, not a seekable regular file. Keep both the buffer
    ;; and total work bounded; a truncated/error observation is a failure.
    (for [_attempt (iterator.range 0 16)]
      (let
        [n : i64
          (unsafe
            (syscall 0 fd (thread.array-u8-addr (& data)) 4096))]
        (when
          (<= n 0)
          (let
            [_closed : i64
              (unsafe
                (syscall 3 fd))]
            (return
              (if (= n 0)
                count
                -1))))
        (for [i (iterator.range 0 n)]
          (when (= (array-ref data i) (cast 10 : u8)) (+= count 1)))))
    (let
      [_closed : i64
        (unsafe
          (syscall 3 fd))]
      -1)))

(define (held-worker [_arg : i64]) : i64
  (while (=
    (unsafe
      (atomic-load (ptr-addr-of release-worker)))
    0)
    unit)
  42)

(define (quick-worker [arg : i64]) : i64
  (+ arg 1))

(define (main) : i64
  (let
    [before : i64 (vmas)]
    [start : i64 (now-ns)]
    [spawned : thread.ThreadSpawnResult
      (unsafe
        (thread.spawn held-worker 0))]
    [ready : i64 (now-ns)]
    (match spawned
      [(thread.ThreadSpawnErr _) 1]
      [(thread.ThreadSpawnOk task)
        (let
          [live : i64 (vmas)]
          [_release : unit
            (unsafe
              (atomic-store! (ptr-addr-of release-worker) 1))]
          [join-start : i64 (now-ns)]
          [result : thread.ThreadJoinResult
            (unsafe
              (thread.join task))]
          [join-end : i64 (now-ns)]
          [after : i64 (vmas)]
          [loop-start : i64 (now-ns)]
          [sum : i64 0]
          (for [i (iterator.range 0 64)]
            (match (unsafe
              (thread.spawn quick-worker i))
              [(thread.ThreadSpawnErr _) (return 2)]
              [(thread.ThreadSpawnOk next)
                (match (unsafe
                  (thread.join next))
                  [(thread.ThreadJoinOk value) (+= sum value)]
                  [_ (return 3)])]))
          (io.println
            "worker-observation spawn-ns={} join-ns={} repeat64-ns={} vma-before={} vma-live={} vma-after={} sum={}"
            (- ready start)
            (- join-end join-start)
            (- (now-ns) loop-start)
            before
            live
            after
            sum)
          (if (and
            (>= before 0)
            (>= live 0)
            (>= after 0)
            (= sum 2080)
            (match result
              [(thread.ThreadJoinOk value) (= value 42)]
              [_ false]))
            42
            4))])))