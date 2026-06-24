(import "stdlib/arena.tl")
(import "stdlib/str_cat.tl")
(import "stdlib/string.tl")
(import "stdlib/thread.tl")
(import (thread-handle i64) as thread_i64)

(define (safe-threading-box [base : i64]) : (Box i64)
  (box (+ base 22)))

(define (safe-threading-join-i64 [thread : thread_i64.Handle] [failure : i64]) : i64
  (match (thread_i64.join thread)
    [(thread_i64.I64JoinOk value) value]
    [(thread_i64.I64JoinErr _) failure]))

(define (safe-threading-join-box-value [thread : ThreadBoxI64] [failure : i64]) : i64
  (match (thread-join-box-i64 thread)
    [(ThreadBoxI64JoinOk cell) (box-get cell)]
    [(ThreadBoxI64JoinErr _) failure]))

(define (safe-threading-join-string-ok? [thread : ThreadString]) : bool
  (match (thread-join-string thread)
    [(ThreadStringJoinOk text) (string-eq text "safe-thread")]
    [(ThreadStringJoinErr _) false]))

(define (safe-threading-finish
  [number : thread_i64.Handle]
  [cell : ThreadBoxI64]
  [text : ThreadString]) : i64
  (let
    [number-value : i64 (safe-threading-join-i64 number -1)]
    [cell-value : i64 (safe-threading-join-box-value cell -2)]
    [text-ok : bool (safe-threading-join-string-ok? text)]
    (cond
      [(not (= number-value 21)) 1]
      [(not (= cell-value 42)) 2]
      [(not text-ok) 3]
      [else 42])))

(define (main) : i64
  (let
    [base : i64 20]
    [owner : Arena (arena-make-atomic)]
    (match (thread_i64.spawn
      (lambda () : i64
        (+ base 1)))
      [(thread_i64.I64SpawnErr _) 4]
      [(thread_i64.I64SpawnOk number)
        (match (thread-spawn-box-i64
          (lambda () : (Box i64)
            (in-arena owner (safe-threading-box 20))))
          [(ThreadBoxI64SpawnErr _) 5]
          [(ThreadBoxI64SpawnOk cell)
            (match (thread-spawn-string
              (lambda () : String
                (in-arena owner (str-cat "safe" "-" "thread"))))
              [(ThreadStringSpawnErr _) 6]
              [(ThreadStringSpawnOk text)
                (safe-threading-finish number cell text)])])])))