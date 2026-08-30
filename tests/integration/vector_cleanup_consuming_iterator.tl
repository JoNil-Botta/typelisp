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

(define (append-token [items : tokens.Vec] [value : i64]) : tokens.Vec
  (tokens.push-owned items (CleanupToken value)))

(define (cleanup-step-value
  [iter : (&mut iter tokens.IntoIter)]
  [fallback : i64]) : i64
  (with
    ([step (tokens.into-next iter) tokens.cleanup-into-next])
    (match (& step)
      [(tokens.IntoNext.Done) fallback]
      [(tokens.IntoNext.Item token) (__tl-project-field token value)])))

(define (empty-and-repeated-exhaustion) : unit
  (with
    ([iter (tokens.into-iterator (tokens.new)) tokens.cleanup-into-iter])
    (begin
      (test.assert-i64-eq
        (tokens.into-remaining-len (& iter))
        0
        "empty remaining length")
      (test.assert-i64-eq
        (cleanup-step-value (&mut iter) -1)
        -1
        "empty first exhaustion")
      (test.assert-i64-eq
        (cleanup-step-value (&mut iter) -1)
        -1
        "empty repeated exhaustion"))))

(define (singleton-and-repeated-exhaustion) : unit
  (with
    ([iter
        (tokens.into-iterator (append-token (tokens.new) 1))
        tokens.cleanup-into-iter])
    (begin
      (test.assert-i64-eq
        (tokens.into-remaining-len (& iter))
        1
        "singleton initial remaining length")
      (test.assert-i64-eq
        (cleanup-step-value (&mut iter) -1)
        1
        "singleton owned item")
      (test.assert-i64-eq
        (tokens.into-remaining-len (& iter))
        0
        "singleton exhausted remaining length")
      (test.assert-i64-eq
        (cleanup-step-value (&mut iter) -1)
        -1
        "singleton exhaustion")
      (test.assert-i64-eq
        (cleanup-step-value (&mut iter) -1)
        -1
        "singleton repeated exhaustion"))))

(define (full-exhaustion) : unit
  (with
    ([iter
        (tokens.into-iterator (append-token (append-token (tokens.new) 10) 100))
        tokens.cleanup-into-iter])
    (begin
      (test.assert-i64-eq
        (tokens.into-remaining-len (& iter))
        2
        "full initial remaining length")
      (test.assert-i64-eq
        (cleanup-step-value (&mut iter) -1)
        10
        "full first owned item")
      (test.assert-i64-eq
        (tokens.into-remaining-len (& iter))
        1
        "full paused remaining length")
      (test.assert-i64-eq
        (cleanup-step-value (&mut iter) -1)
        100
        "full resumed owned item")
      (test.assert-i64-eq
        (tokens.into-remaining-len (& iter))
        0
        "full exhausted remaining length"))))

(define (early-abandonment) : unit
  (with
    ([iter
        (tokens.into-iterator
          (append-token
            (append-token (append-token (tokens.new) 1000) 10000)
            100000))
        tokens.cleanup-into-iter])
    (begin
      (test.assert-i64-eq
        (cleanup-step-value (&mut iter) -1)
        1000
        "early abandonment first owned item")
      (test.assert-i64-eq
        (tokens.into-remaining-len (& iter))
        2
        "early abandonment remaining length"))))

(define (null-state-is-empty) : unit
  (with
    ([iter
        (tokens.IntoIter (ptr-null : (MutPtr tokens.IntoIterState)))
        tokens.cleanup-into-iter])
    (begin
      (test.assert-i64-eq
        (tokens.into-remaining-len (& iter))
        0
        "null iterator remaining length")
      (test.assert-i64-eq
        (cleanup-step-value (&mut iter) -1)
        -1
        "null iterator exhaustion"))))

(define (replacement-cleans-old-and-new) : unit
  (with
    ([items (append-token (tokens.new) 1000000) tokens.cleanup-vec])
    (tokens.set! items 0 (CleanupToken 2000000))))

(define (out-of-range-set-cleans-rejected-owner) : unit
  (with
    ([items (tokens.new) tokens.cleanup-vec])
    (tokens.set! items 4 (CleanupToken 8000000))))

(define (native-views-preserve-cleanup-ownership) : unit
  (with
    ([items (append-token (append-token (tokens.new) 3) 30) tokens.cleanup-vec])
    (begin
      (let
        [shared : (& items (Slice CleanupToken)) (tokens.view (& items))]
        (begin
          (test.assert-i64-eq (array-length shared) 2 "cleanup view length")
          (test.assert-i64-eq
            (__tl-project-field (array-ref shared 1) value)
            30
            "cleanup view value")))
      (let
        [exclusive : (&mut items (Slice CleanupToken))
          (tokens.view-mut (&mut items))]
        (test.assert-i64-eq
          (__tl-project-field (array-ref exclusive 0) value)
          3
          "cleanup mutable view value")))))

(define (enum-payload-cleanup) : unit
  (with ([pair (CleanupPair.Both 4000000 5000000) cleanup-pair]) unit))

(define (main) : i64
  (begin
    (empty-and-repeated-exhaustion)
    (singleton-and-repeated-exhaustion)
    (full-exhaustion)
    (early-abandonment)
    (null-state-is-empty)
    (replacement-cleans-old-and-new)
    (out-of-range-set-cleans-rejected-owner)
    (native-views-preserve-cleanup-ownership)
    (enum-payload-cleanup)
    (test.assert-i64-eq
      cleanup-total
      20111144
      "cleanup vector must clean every constructed token exactly once")
    42))