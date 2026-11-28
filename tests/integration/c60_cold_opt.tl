(defenum ColdTag
  (T0)
  (T1)
  (T2)
  (T3)
  (T4)
  (T5))

(define (cold-report [x : i64])
  (:cold) : i64
  (+ x 10))

(define (cold-alloc-box [x : i64])
  (:cold) : i64
  (let
    [b : (Box i64) (box (+ x 1))]
    (deref b)))

(define (cold-switch [tag : ColdTag] [base : i64])
  (:cold) : i64
  (match tag
    [(T0) (+ base 1)]
    [(T1) (+ base 2)]
    [(T2) (+ base 3)]
    [(T3) (+ base 4)]
    [(T4) (+ base 5)]
    [(T5) (+ base 6)]))

(define (cold-loop [n : i64])
  (:cold) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (while (< i n)
      (set! acc (+ acc (+ i 1)))
      (set! i (+ i 1)))
    acc))

(define (cold-sink-helper [a : i64] [b : i64])
  (:cold) : i64
  (let
    [v0 : i64 (+ (* a 3) b)]
    [v1 : i64 (bit-xor v0 65537)]
    [v2 : i64 (+ (* v1 5) a)]
    [v3 : i64 (+ (* v2 7) b)]
    (+ v3 11)))

(define (cold-shared-a [x : i64] [y : i64])
  (:cold) : i64
  (let
    [t0 : i64 (+ (* x 31) 17)]
    [t1 : i64 (+ (* t0 13) y)]
    [t2 : i64 (bit-xor t1 1311768467463790320)]
    [t3 : i64 (cold-sink-helper t2 x)]
    (+ (* (+ t3 19) 7) 11)))

(define (cold-shared-b [x : i64] [y : i64])
  (:cold) : i64
  (let
    [t0 : i64 (+ (* x 31) 17)]
    [t1 : i64 (+ (* t0 13) y)]
    [t2 : i64 (bit-xor t1 1311768467463790320)]
    [t3 : i64 (cold-sink-helper t2 y)]
    (+ (* (+ t3 19) 7) 11)))

(define (cold-shared-c [x : i64] [y : i64])
  (:cold) : i64
  (let
    [t0 : i64 (+ (* x 31) 17)]
    [t1 : i64 (+ (* t0 13) y)]
    [t2 : i64 (bit-xor t1 1311768467463790320)]
    [t3 : i64 (cold-sink-helper t2 (+ x y))]
    (+ (* (+ t3 19) 7) 11)))

(define (warm-not-outlined [x : i64] [y : i64]) : i64
  (let
    [t0 : i64 (+ (* x 31) 17)]
    [t1 : i64 (+ (* t0 13) y)]
    [t2 : i64 (bit-xor t1 1311768467463790320)]
    [t3 : i64 (+ t2 x)]
    (+ (+ t3 t1) 7)))

(define (warm-dispatch [flag : i64] [x : i64]) : i64
  (let
    [v : i64
      (if (= flag 0)
        (cold-report x)
        (+ x 5))]
    (+ v 1)))

(define (main) : i64
  (let
    [a : i64 (warm-dispatch 1 10)]
    [b : i64 (warm-dispatch 0 2)]
    [c : i64 (cold-alloc-box 3)]
    [d : i64 (cold-switch (T2) 1)]
    [e : i64 (cold-loop 4)]
    [f : i64 (- (cold-shared-a 2 3) (cold-shared-a 2 3))]
    [g : i64 (- (cold-shared-b 2 3) (cold-shared-b 2 3))]
    [h : i64 (- (cold-shared-c 2 3) (cold-shared-c 2 3))]
    [w : i64 (- (warm-not-outlined 2 3) (warm-not-outlined 2 3))]
    (+ (+ (+ (+ (+ a b) c) d) e) (+ (+ (+ f g) h) w))))