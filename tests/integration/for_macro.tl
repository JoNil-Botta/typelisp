;; Scalar `for` selects the iterator protocol from source ownership, evaluates
;; every source once, and stops at the shortest source when clauses are zipped.
(import stdlib.iterator)
(import stdlib.vector)

(defstruct ForCounter
  (value i64))

(import (vector.vector ForCounter) as counters)

(define for-cleanup-total : i64
  0)

(define (record-for-cleanup [value : i64]) : unit
  (set! for-cleanup-total (+ for-cleanup-total value)))

(defstruct ForCleanupToken
  (:cleanup cleanup-for-cleanup-token)
  (value i64 (:cleanup record-for-cleanup)))

(import (vector.vector ForCleanupToken) as cleanup_tokens)

(define for-source-evaluations : i64
  0)

(define (counted-range [start : i64] [end : i64]) : iterator.I64Range
  (begin
    (set! for-source-evaluations (+ for-source-evaluations 1))
    (iterator.range start end)))

(define (counter-vec [first : i64] [second : i64]) : counters.Vec
  (let
    [items : counters.Vec (counters.new)]
    (begin
      (counters.push (&mut items) (ForCounter first))
      (counters.push (&mut items) (ForCounter second))
      items)))

(define (cleanup-token-vec) : cleanup_tokens.Vec
  (cleanup_tokens.push-owned
    (cleanup_tokens.push-owned
      (cleanup_tokens.push-owned (cleanup_tokens.new) (ForCleanupToken 1))
      (ForCleanupToken 10))
    (ForCleanupToken 100)))

(define (main) : i64
  (let
    [borrowed : counters.Vec (counter-vec 4 5)]
    [owned : counters.Vec (counter-vec 7 8)]
    [total : i64 0]
    [empty-visits : i64 0]
    [cleanup-visits : i64 0]
    ;; These names deliberately resemble the macro's private temporaries.
    [__for_source_0 : i64 1]
    [__for_iterator_0 : i64 2]
    [__for_done_0 : i64 4]
    (begin
      (for [item : i64 (counted-range 1 4)] (set! total (+ total item)))
      (for [item (& borrowed)] (set! total (+ total item.value)))
      (for [item (&mut borrowed)] (set! item.value (+ item.value 10)))
      (for [item (& borrowed)] (set! total (+ total item.value)))
      (for [item : ForCounter owned] (set! total (+ total item.value)))
      (for
        [left (iterator.range 0 3)]
        [right : i64 (iterator.range 10 11)]
        (set! total (+ total (+ left right))))
      (for
        [item (iterator.range 2 2)]
        (set! empty-visits (+ empty-visits (+ item 1))))
      (for
        [item (iterator.range 0 1)]
        (set!
          total
          (+
            total
            (+ item (+ __for_source_0 (+ __for_iterator_0 __for_done_0))))))
      (for
        [token : ForCleanupToken (cleanup-token-vec)]
        (set! cleanup-visits (+ cleanup-visits 1))
        (cleanup-for-cleanup-token token)
        (break))
      (cond
        [(not (= total 76)) total]
        [(not (= empty-visits 0)) 2]
        [(not (= cleanup-visits 1)) 3]
        [(not (= for-source-evaluations 1)) 4]
        [(not (= for-cleanup-total 111)) for-cleanup-total]
        [else 42]))))