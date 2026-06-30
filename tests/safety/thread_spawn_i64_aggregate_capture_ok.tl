(import stdlib.array)
(import "stdlib/thread.tl")
(import (thread-handle i64) as thread_i64)

(defstruct SafeThreadPair
  (left i64)
  (right i64))

(defenum SafeThreadChoice
  (SafeThreadSome SafeThreadPair)
  (SafeThreadNone))

(define (choice-score [choice : SafeThreadChoice]) : i64
  (match choice
    [(SafeThreadSome pair) (struct-get pair right)]
    [(SafeThreadNone) 0]))

(define (main) : i64
  (let
    [pair : SafeThreadPair (SafeThreadPair 10 20)]
    [items : (Array i64 2) (array 1 2)]
    [choice : SafeThreadChoice (SafeThreadSome (SafeThreadPair 3 4))]
    [coords : (Tuple i64 i64) (tuple 5 6)]
    (match (thread_i64.spawn
      (lambda () : i64
        (+
          (struct-get pair left)
          (+
            (array-ref items 0)
            (+
              (choice-score choice)
              (+ (tuple-ref coords 0) (tuple-ref coords 1)))))))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk thread)
        (match (thread_i64.join thread)
          [(thread_i64.I64JoinOk value) value]
          [(thread_i64.I64JoinErr _) 2])])))