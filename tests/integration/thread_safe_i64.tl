(import "stdlib/thread.tl")
(import (thread-handle i64) as thread_i64)

(define (thread-safe-i64-join-value
  [thread : thread_i64.Handle]
  [fallback : i64]) : i64
  (match (thread_i64.join thread)
    [(thread_i64.I64JoinOk value) value]
    [(thread_i64.I64JoinErr _) fallback]))

(define (thread-safe-i64-join-four
  [a : thread_i64.Handle]
  [b : thread_i64.Handle]
  [c : thread_i64.Handle]
  [d : thread_i64.Handle]) : i64
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
    (match (thread_i64.spawn
      (lambda () : i64
        (+ base-a 4)))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk a)
        (match (thread_i64.spawn
          (lambda () : i64
            (+ base-b 4)))
          [(thread_i64.I64SpawnErr _) 2]
          [(thread_i64.I64SpawnOk b)
            (match (thread_i64.spawn
              (lambda () : i64
                (+ base-c 6)))
              [(thread_i64.I64SpawnErr _) 3]
              [(thread_i64.I64SpawnOk c)
                (match (thread_i64.spawn
                  (lambda () : i64
                    (+ base-d 10)))
                  [(thread_i64.I64SpawnErr _) 4]
                  [(thread_i64.I64SpawnOk d)
                    (thread-safe-i64-join-four a b c d)])])])])))

(define (main) : i64
  (thread-safe-i64-run-four))