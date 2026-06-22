(import stdlib.arena)
(import stdlib.thread)

(define (arena-atomic-worker-loop [i : i64] [sum : i64]) : i64
  (if (>= i 12)
    sum
    (let
      [items : (Array i64) (make-array i64 1048576)]
      (begin
        (array-set! items 0 i)
        (array-set! items 1 (+ i 1))
        (array-set! items 2 (+ i 2))
        (array-set! items 3 (+ i 3))
        (arena-atomic-worker-loop (+ i 1) (+ sum (array-ref items (% i 4))))))))

(define (arena-atomic-worker [owner : i64]) : i64
  (let
    [home : i64 (arena.arena-current)]
    (begin
      (unsafe
        (arena.arena-set! owner))
      (let
        [sum : i64 (arena-atomic-worker-loop 0 0)]
        (begin
          (unsafe
            (arena.arena-set! home))
          (if (> sum 0)
            42
            7))))))

(define (arena-atomic-join [worker : thread.Thread]) : i64
  (thread.thread-join-result-value-or (thread.thread-join worker) 8))

(define (arena-atomic-thread-or [spawn : thread.ThreadSpawnResult]) : thread.Thread
  (thread.Thread
    (thread.thread-spawn-result-handle-or spawn 0)
    (thread.thread-spawn-result-clear-tid-addr-or spawn 0)
    (thread.thread-spawn-result-result-addr-or spawn 0)))

(define (arena-atomic-spawn-second [owner : i64] [first : thread.Thread]) : i64
  (let
    [spawn : thread.ThreadSpawnResult
      (thread.thread-spawn arena-atomic-worker owner)]
    (if (not (thread.thread-spawn-result-ok? spawn))
      3
      (let
        [second : thread.Thread (arena-atomic-thread-or spawn)]
        [first-code : i64 (arena-atomic-join first)]
        [second-code : i64 (arena-atomic-join second)]
        (if (and (= first-code 42) (= second-code 42))
          42
          4)))))

(define (arena-atomic-run [owner : i64]) : i64
  (let
    [spawn : thread.ThreadSpawnResult
      (thread.thread-spawn arena-atomic-worker owner)]
    (if (not (thread.thread-spawn-result-ok? spawn))
      2
      (arena-atomic-spawn-second owner (arena-atomic-thread-or spawn)))))

(define (main) : i64
  (let
    [owner : i64 (arena.arena-make-atomic)]
    [result : i64 (arena-atomic-run owner)]
    (begin
      (unsafe
        (arena.arena-destroy owner))
      result)))