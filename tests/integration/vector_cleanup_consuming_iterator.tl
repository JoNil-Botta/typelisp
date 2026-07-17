;; Cleanup-owning generated vectors never fabricate owners for spare capacity.
;; Consuming results own visited items; iterator cleanup drains only unvisited
;; live slots, and repeated exhaustion stays a no-op.
(import stdlib.test)
(import stdlib.vector)

(define cleanup-total : i64
  0)

(define (record-cleanup [value : i64]) : unit
  (set! cleanup-total (+ cleanup-total value)))

(defstruct CleanupToken
  (:cleanup cleanup-token)
  (value i64 (:cleanup record-cleanup)))

(defenum CleanupPair
  (:cleanup cleanup-pair)
  (None)
  (Both i64 (:cleanup record-cleanup) i64 (:cleanup record-cleanup)))

(import (vector.vector CleanupToken) as tokens)

(define (append-token [items : tokens.Vec (:consume)] [value : i64]) : tokens.Vec
  (tokens.push-owned items (CleanupToken value)))

(define (cleanup-step [iter : (&mut iter tokens.IntoIter)]) : unit
  (with ([step (tokens.into-next iter) tokens.cleanup-into-next]) unit))

(define (empty-and-repeated-exhaustion) : unit
  (with
    ([iter (tokens.into-iterator (tokens.new)) tokens.cleanup-into-iter])
    (begin
      (cleanup-step (&mut iter))
      (cleanup-step (&mut iter)))))

(define (singleton-and-repeated-exhaustion) : unit
  (with
    ([iter
        (tokens.into-iterator (append-token (tokens.new) 1))
        tokens.cleanup-into-iter])
    (begin
      (cleanup-step (&mut iter))
      (cleanup-step (&mut iter))
      (cleanup-step (&mut iter)))))

(define (full-exhaustion) : unit
  (with
    ([iter
        (tokens.into-iterator (append-token (append-token (tokens.new) 10) 100))
        tokens.cleanup-into-iter])
    (begin
      (cleanup-step (&mut iter))
      (cleanup-step (&mut iter)))))

(define (early-abandonment) : unit
  (with
    ([iter
        (tokens.into-iterator
          (append-token
            (append-token (append-token (tokens.new) 1000) 10000)
            100000))
        tokens.cleanup-into-iter])
    (cleanup-step (&mut iter))))

(define (replacement-cleans-old-and-new) : unit
  (with
    ([items (append-token (tokens.new) 1000000) tokens.cleanup-vec])
    (tokens.set! items 0 (CleanupToken 2000000))))

(define (out-of-range-set-cleans-rejected-owner) : unit
  (with
    ([items (tokens.new) tokens.cleanup-vec])
    (tokens.set! items 4 (CleanupToken 8000000))))

(define (enum-payload-cleanup) : unit
  (with ([pair (CleanupPair.Both 4000000 5000000) cleanup-pair]) unit))

(define (main) : i64
  (begin
    (empty-and-repeated-exhaustion)
    (singleton-and-repeated-exhaustion)
    (full-exhaustion)
    (early-abandonment)
    (replacement-cleans-old-and-new)
    (out-of-range-set-cleans-rejected-owner)
    (enum-payload-cleanup)
    (test.assert-i64-eq
      cleanup-total
      20111111
      "cleanup vector must clean every constructed token exactly once")
    42))