;; #2605 regression guard: references to register-resident aggregates are always
;; address-shaped. The callee must load resident values from that address before
;; struct-get or match extraction, regardless of whether the ref came from a
;; local, a global, or a lifetime-arg aggregate form.
(defstruct Pair
  (x i64)
  (y i64))

(defenum Maybe
  (None)
  (Some i64))

(defstruct TaggedPair
  (:lifetimes owner)
  (x i64)
  (y i64))

(define global-pair : Pair
  (Pair 10 20))
(define global-maybe : Maybe
  (Some 9))

(define (sum-pair-ref [p : (& p Pair)]) : i64
  (+ (struct-get p x) (struct-get p y)))

(define (score-maybe-ref [m : (& m Maybe)]) : i64
  (match m
    [(Some 9) 40]
    [(Some _) 2]
    [None 1]))

(define (make-tagged [owner : i64] [x : i64] [y : i64]) : (TaggedPair owner)
  (TaggedPair x y))

(define (sum-tagged [owner : i64]) : i64
  (let
    [p : (TaggedPair owner) (make-tagged owner 4 7)]
    (+ (struct-get p x) (struct-get p y))))

(define (local-pair-score [x : i64]) : i64
  (let
    [p : Pair (Pair x 7)]
    (sum-pair-ref (& p))))

(define (local-maybe-score [x : i64]) : i64
  (let
    [m : Maybe (Some x)]
    (score-maybe-ref (& m))))

(define (main) : i64
  (+
    (sum-pair-ref (& global-pair))
    (+
      (local-pair-score 5)
      (+
        (score-maybe-ref (& global-maybe))
        (+ (local-maybe-score 7) (sum-tagged 3))))))