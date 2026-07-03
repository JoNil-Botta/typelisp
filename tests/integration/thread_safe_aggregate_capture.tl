(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(defstruct ThreadTransferPair
  (left i64)
  (right i64))

(defenum ThreadTransferChoice
  (ThreadTransferSome ThreadTransferPair)
  (ThreadTransferNone))

(define (thread-transfer-choice-score [choice : ThreadTransferChoice]) : i64
  (match choice
    [(ThreadTransferSome pair) (struct-get pair left)]
    [(ThreadTransferNone) 0]))

(define (thread-transfer-aggregate-score) : i64
  (let
    [pair : ThreadTransferPair (ThreadTransferPair 7 8)]
    [items : (Array i64 2) (array 5 6)]
    [choice : ThreadTransferChoice
      (ThreadTransferSome (ThreadTransferPair 9 0))]
    [coords : (Tuple i64 i64) (tuple 3 4)]
    (match (thread_i64.spawn
      (lambda () : i64
        (+
          (struct-get pair left)
          (+
            (struct-get pair right)
            (+
              (array-ref items 0)
              (+
                (array-ref items 1)
                (+
                  (thread-transfer-choice-score choice)
                  (+ (tuple-ref coords 0) (tuple-ref coords 1)))))))))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk worker)
        (match (thread_i64.join worker)
          [(thread_i64.I64JoinOk value) value]
          [(thread_i64.I64JoinErr _) 2])])))

(define (main) : i64
  (thread-transfer-aggregate-score))