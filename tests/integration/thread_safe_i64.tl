(import "stdlib/thread.tl")

(define (thread-safe-i64-join-value [thread : ThreadI64] [fallback : i64]) : i64
  (match (thread-join-i64 thread)
    [(ThreadI64JoinOk value) value]
    [(ThreadI64JoinErr _) fallback]))

(define (thread-safe-i64-join-four
  [a : ThreadI64]
  [b : ThreadI64]
  [c : ThreadI64]
  [d : ThreadI64]) : i64
  (let
    [av : i64 (thread-safe-i64-join-value a -1)]
    [bv : i64 (thread-safe-i64-join-value b -2)]
    [cv : i64 (thread-safe-i64-join-value c -3)]
    [dv : i64 (thread-safe-i64-join-value d -4)]
    (if (and (= av 11) (= bv 23) (= cv 37) (= dv 53))
      42
      5)))

(define (thread-safe-i64-run-four) : i64
  (let
    [base-a : i64 7]
    [base-b : i64 19]
    [base-c : i64 31]
    [base-d : i64 43]
    (match (thread-spawn-i64
      (lambda () : i64
        (+ base-a 4)))
      [(ThreadI64SpawnErr _) 1]
      [(ThreadI64SpawnOk a)
        (match (thread-spawn-i64
          (lambda () : i64
            (+ base-b 4)))
          [(ThreadI64SpawnErr _) 2]
          [(ThreadI64SpawnOk b)
            (match (thread-spawn-i64
              (lambda () : i64
                (+ base-c 6)))
              [(ThreadI64SpawnErr _) 3]
              [(ThreadI64SpawnOk c)
                (match (thread-spawn-i64
                  (lambda () : i64
                    (+ base-d 10)))
                  [(ThreadI64SpawnErr _) 4]
                  [(ThreadI64SpawnOk d) (thread-safe-i64-join-four a b c d)])])])])))

(define (main) : i64
  (thread-safe-i64-run-four))