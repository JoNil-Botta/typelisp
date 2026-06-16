(import "stdlib/arena.tl")

(import "stdlib/thread.tl")

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

(define (arena-atomic-worker [arena : i64]) : i64
  (let
    [home : i64 (arena-current)]
    (begin
      (unsafe
        (arena-set! arena))
      (let
        [sum : i64 (arena-atomic-worker-loop 0 0)]
        (begin
          (unsafe
            (arena-set! home))
          (if (> sum 0)
            42
            7))))))

(define (arena-atomic-join [thread : Thread]) : i64
  (match (thread-join thread)
    [(ThreadJoinOk code) code]
    [(ThreadJoinErr _) 8]))

(define (arena-atomic-spawn-second [arena : i64] [first : Thread]) : i64
  (match (thread-spawn arena-atomic-worker arena)
    [(ThreadSpawnErr _) 3]
    [(ThreadSpawnOk second)
      (let
        [first-code : i64 (arena-atomic-join first)]
        [second-code : i64 (arena-atomic-join second)]
        (if (and (= first-code 42) (= second-code 42))
          42
          4))]))

(define (arena-atomic-run [arena : i64]) : i64
  (match (thread-spawn arena-atomic-worker arena)
    [(ThreadSpawnErr _) 2]
    [(ThreadSpawnOk first) (arena-atomic-spawn-second arena first)]))

(define (main) : i64
  (let
    [arena : i64 (arena-make-atomic)]
    [result : i64 (arena-atomic-run arena)]
    (begin
      (unsafe
        (arena-destroy arena))
      result)))