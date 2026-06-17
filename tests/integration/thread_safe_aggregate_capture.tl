(import "stdlib/thread.tl")

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
    (match (thread-spawn-i64
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
      [(ThreadI64SpawnErr _) 1]
      [(ThreadI64SpawnOk worker)
        (match (thread-join-i64 worker)
          [(ThreadI64JoinOk value) value]
          [(ThreadI64JoinErr _) 2])])))

(define (main) : i64
  (thread-transfer-aggregate-score))