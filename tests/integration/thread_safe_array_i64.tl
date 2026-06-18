(import "stdlib/arena.tl")
(import "stdlib/thread.tl")

(define (thread-safe-array-i64-build [base : i64]) : (Array i64)
  (let
    [items : (Array i64) (make-array i64 5)]
    (begin
      (array-set! items 0 base)
      (array-set! items 1 (+ base 1))
      (array-set! items 2 (+ base 2))
      (array-set! items 3 (+ base 3))
      (array-set! items 4 (+ base 4))
      items)))

(define (thread-safe-array-i64-sum [items : (Array i64)]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i (array-length items))
        (begin
          (set! sum (+ sum (array-ref items i)))
          (set! i (+ i 1))))
      sum)))

(define (thread-safe-array-i64-join-code
  [thread : ThreadArrayI64]
  [expected : i64]
  [failure : i64]) : i64
  (match (thread-join-array-i64 thread)
    [(ThreadArrayI64JoinOk items)
      (if (and
        (= (array-length items) 5)
        (= (thread-safe-array-i64-sum items) expected))
        42
        failure)]
    [(ThreadArrayI64JoinErr _) failure]))

(define (thread-safe-array-i64-worker-default-run) : i64
  (let
    [base : i64 8]
    (match (thread-spawn-array-i64
      (lambda () : (Array i64)
        (thread-safe-array-i64-build base)))
      [(ThreadArrayI64SpawnErr _) 1]
      [(ThreadArrayI64SpawnOk worker)
        (thread-safe-array-i64-join-code worker 50 2)])))

(define (thread-safe-array-i64-atomic-run) : i64
  (let
    [owner : i64 (arena-make-atomic)]
    [base : i64 18]
    (match (thread-spawn-array-i64
      (lambda () : (Array i64)
        (in-arena owner (thread-safe-array-i64-build base))))
      [(ThreadArrayI64SpawnErr _) 3]
      [(ThreadArrayI64SpawnOk worker)
        (thread-safe-array-i64-join-code worker 100 4)])))

(define (main) : i64
  (let
    [first : i64 (thread-safe-array-i64-worker-default-run)]
    [second : i64 (thread-safe-array-i64-atomic-run)]
    (if (= first 42)
      second
      first)))