(import "stdlib/arena.tl")
(import "stdlib/thread.tl")

(define (thread-safe-box-i64-join-code
  [thread : ThreadBoxI64]
  [expected : i64]
  [failure : i64]) : i64
  (match (thread-join-box-i64 thread)
    [(ThreadBoxI64JoinOk cell)
      (if (= (box-get cell) expected)
        42
        failure)]
    [(ThreadBoxI64JoinErr _) failure]))

(define (thread-safe-box-i64-worker-default-run) : i64
  (let
    [base : i64 40]
    (match (thread-spawn-box-i64
      (lambda () : (Box i64)
        (box (+ base 2))))
      [(ThreadBoxI64SpawnErr _) 1]
      [(ThreadBoxI64SpawnOk worker) (thread-safe-box-i64-join-code worker 42 2)])))

(define (thread-safe-box-i64-atomic-run) : i64
  (let
    [owner : i64 (arena-make-atomic)]
    [base : i64 50]
    (match (thread-spawn-box-i64
      (lambda () : (Box i64)
        (in-arena owner (box (+ base 7)))))
      [(ThreadBoxI64SpawnErr _) 3]
      [(ThreadBoxI64SpawnOk worker) (thread-safe-box-i64-join-code worker 57 4)])))

(define (main) : i64
  (let
    [first : i64 (thread-safe-box-i64-worker-default-run)]
    [second : i64 (thread-safe-box-i64-atomic-run)]
    (if (= first 42)
      second
      first)))