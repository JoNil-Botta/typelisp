(import "stdlib/arena.tl")
(import "stdlib/str_cat.tl")
(import "stdlib/string.tl")
(import "stdlib/thread.tl")

(define (safe-threading-array [base : i64]) : (Array i64)
  (let
    [items : (Array i64) (make-array i64 4)]
    (begin
      (array-set! items 0 base)
      (array-set! items 1 (+ base 1))
      (array-set! items 2 (+ base 2))
      (array-set! items 3 (+ base 3))
      items)))

(define (safe-threading-sum [items : (Array i64)]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i (array-length items))
        (begin
          (set! sum (+ sum (array-ref items i)))
          (set! i (+ i 1))))
      sum)))

(define (safe-threading-join-i64 [thread : ThreadI64] [failure : i64]) : i64
  (match (thread-join-i64 thread)
    [(ThreadI64JoinOk value) value]
    [(ThreadI64JoinErr _) failure]))

(define (safe-threading-join-array-sum
  [thread : ThreadArrayI64]
  [failure : i64]) : i64
  (match (thread-join-array-i64 thread)
    [(ThreadArrayI64JoinOk items) (safe-threading-sum items)]
    [(ThreadArrayI64JoinErr _) failure]))

(define (safe-threading-join-string-ok? [thread : ThreadString]) : bool
  (match (thread-join-string thread)
    [(ThreadStringJoinOk text) (string-eq text "safe-thread")]
    [(ThreadStringJoinErr _) false]))

(define (safe-threading-finish
  [number : ThreadI64]
  [items : ThreadArrayI64]
  [text : ThreadString]) : i64
  (let
    [number-value : i64 (safe-threading-join-i64 number -1)]
    [items-sum : i64 (safe-threading-join-array-sum items -2)]
    [text-ok : bool (safe-threading-join-string-ok? text)]
    (cond
      [(not (= number-value 21)) 1]
      [(not (= items-sum 42)) 2]
      [(not text-ok) 3]
      [else 42])))

(define (main) : i64
  (let
    [base : i64 20]
    [owner : i64 (arena-make-atomic)]
    (match (thread-spawn-i64
      (lambda () : i64
        (+ base 1)))
      [(ThreadI64SpawnErr _) 4]
      [(ThreadI64SpawnOk number)
        (match (thread-spawn-array-i64
          (lambda () : (Array i64)
            (in-arena owner (safe-threading-array 9))))
          [(ThreadArrayI64SpawnErr _) 5]
          [(ThreadArrayI64SpawnOk items)
            (match (thread-spawn-string
              (lambda () : String
                (in-arena owner (str-cat "safe" "-" "thread"))))
              [(ThreadStringSpawnErr _) 6]
              [(ThreadStringSpawnOk text)
                (safe-threading-finish number items text)])])])))