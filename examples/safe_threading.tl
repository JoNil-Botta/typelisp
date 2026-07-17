(import stdlib.arena)
(import stdlib.str_cat as str-cat)
(import stdlib.string)
(import stdlib.thread)
(import (thread.handle i64) as thread-i64)

(define (safe-threading-box [base : i64]) : (Box i64)
  (box (+ base 22)))

(define (safe-threading-join-i64 [worker : thread-i64.Handle] [failure : i64]) : i64
  (match (thread-i64.join worker)
    [(thread-i64.I64JoinOk value) value]
    [(thread-i64.I64JoinErr _) failure]))

(define (safe-threading-join-box-value [worker : ThreadBoxI64] [failure : i64]) : i64
  (match (thread.join-box-i64 worker)
    [(ThreadBoxI64JoinOk cell) (box-get cell)]
    [(ThreadBoxI64JoinErr _) failure]))

(define (safe-threading-join-string-ok? [worker : ThreadString]) : bool
  (match (thread.join-string worker)
    [(ThreadStringJoinOk text) (string.eq text "safe-thread")]
    [(ThreadStringJoinErr _) false]))

(define (safe-threading-finish
  [number : thread-i64.Handle]
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
    [owner : arena.Arena (arena.make-atomic)]
    (match (thread-i64.spawn
      (lambda () : i64
        (+ base 1)))
      [(thread-i64.I64SpawnErr _) 4]
      [(thread-i64.I64SpawnOk number)
        (match (thread.spawn-box-i64
          (lambda () : (Box i64)
            (in-arena owner (safe-threading-box 20))))
          [(ThreadBoxI64SpawnErr _) 5]
          [(ThreadBoxI64SpawnOk cell)
            (match (thread.spawn-string
              (lambda () : String
                (in-arena owner (str-cat.str-cat "safe" "-" "thread"))))
              [(ThreadStringSpawnErr _) 6]
              [(ThreadStringSpawnOk text)
                (safe-threading-finish number cell text)])])])))