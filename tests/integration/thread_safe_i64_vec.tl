(import stdlib.arena)
(import stdlib.thread)
(import stdlib.vector)
(import (vector.vector i64) as i64-vec)

(define (thread-safe-i64-vec-build [base : i64]) : i64-vec.Vec
  (let
    [items : i64-vec.Vec (i64-vec.with-capacity 5)]
    (begin
      (i64-vec.push (&mut items) base)
      (i64-vec.push (&mut items) (+ base 1))
      (i64-vec.push (&mut items) (+ base 2))
      (i64-vec.push (&mut items) (+ base 3))
      (i64-vec.push (&mut items) (+ base 4))
      items)))

(define (thread-safe-i64-vec-sum [items : (& items i64-vec.Vec)]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i (i64-vec.len items))
        (begin
          (set! sum (+ sum (i64-vec.get items i 0)))
          (set! i (+ i 1))))
      sum)))

(define (thread-safe-i64-vec-join-code
  [worker : ThreadI64Vec]
  [expected : i64]
  [failure : i64]) : i64
  (match (thread.join-i64-vec worker)
    [(ThreadI64VecJoinOk items)
      (if (and
        (= (i64-vec.len (& items)) 5)
        (= (thread-safe-i64-vec-sum (& items)) expected))
        42
        failure)]
    [(ThreadI64VecJoinErr _) failure]))

(define (thread-safe-i64-vec-worker-default-run) : i64
  (let
    [base : i64 8]
    (match (thread.spawn-i64-vec
      (lambda () : i64-vec.Vec
        (thread-safe-i64-vec-build base)))
      [(ThreadI64VecSpawnErr _) 1]
      [(ThreadI64VecSpawnOk worker) (thread-safe-i64-vec-join-code worker 50 2)])))

(define (thread-safe-i64-vec-atomic-run) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [base : i64 18]
    (match (thread.spawn-i64-vec
      (lambda () : i64-vec.Vec
        (in-arena owner (thread-safe-i64-vec-build base))))
      [(ThreadI64VecSpawnErr _) 3]
      [(ThreadI64VecSpawnOk worker)
        (thread-safe-i64-vec-join-code worker 100 4)])))

(define (main) : i64
  (let
    [first : i64 (thread-safe-i64-vec-worker-default-run)]
    [second : i64 (thread-safe-i64-vec-atomic-run)]
    (if (= first 42)
      second
      first)))