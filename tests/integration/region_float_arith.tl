;; Region-tagged floats are ordinary floats in the IR (#9690). A value read
;; through `(in p T)` keeps its tag only for the checker: arithmetic, compares,
;; negation, literals and casts on it must use the SSE path of its inner f32 or
;; f64. Every row runs on the tagged value and on a plain control. Recursion
;; keeps the dispatchers out of line; the `shape-` functions are small enough
;; to inline, so opt2 also forwards their constants into the operator.
(define failures : i64
  0)

(define (assert [condition : bool]) : unit
  (unless condition (set! failures (+ failures 1))))

(define (f64-at [p : (& p (Array f64 2))] [i : i64]) : (in p f64)
  (array-ref p i))

(define (f64-plain [p : (& p (Array f64 2))] [i : i64]) : f64
  (deref (& (array-ref p i))))

(define (f32-at [p : (& p (Array f32 2))] [i : i64]) : (in p f32)
  (array-ref p i))

(define (f32-plain [p : (& p (Array f32 2))] [i : i64]) : f32
  (deref (& (array-ref p i))))

(define (f64-at-arith [p : (& p (Array f64 2))] [op : i64]) : i64
  (cond
    [(< op 0) (f64-at-arith p (+ op 1))]
    [(= op 0) (cast (* (+ (f64-at p 0) (f64-at p 1)) 4.0) : i64)]
    [(= op 1) (cast (* (- (f64-at p 0) (f64-at p 1)) 4.0) : i64)]
    [(= op 2) (cast (* (* (f64-at p 0) (f64-at p 1)) 4.0) : i64)]
    [(= op 3) (cast (* (/ (f64-at p 0) (f64-at p 1)) 4.0) : i64)]
    [(= op 4) (cast (* (neg (f64-at p 0)) 4.0) : i64)]
    [(= op 5) (cast (* (+ (f64-at p 0) 0.5) 4.0) : i64)]
    [(= op 6) (cast (* (* 2.0 (f64-at p 1)) 4.0) : i64)]
    [else (cast (* (- 1.0 (f64-at p 0)) 4.0) : i64)]))

(define (f64-at-compare [p : (& p (Array f64 2))] [op : i64]) : bool
  (cond
    [(< op 0) (f64-at-compare p (+ op 1))]
    [(= op 0) (< (f64-at p 0) (f64-at p 1))]
    [(= op 1) (<= (f64-at p 0) (f64-at p 1))]
    [(= op 2) (> (f64-at p 0) (f64-at p 1))]
    [(= op 3) (>= (f64-at p 0) (f64-at p 1))]
    [(= op 4) (= (f64-at p 0) (f64-at p 1))]
    [(= op 5) (!= (f64-at p 0) (f64-at p 1))]
    [(= op 6)
      (if (< (f64-at p 0) (f64-at p 1))
        true
        false)]
    [(= op 7)
      (if (<= (f64-at p 0) (f64-at p 1))
        true
        false)]
    [(= op 8)
      (if (> (f64-at p 0) (f64-at p 1))
        true
        false)]
    [(= op 9)
      (if (>= (f64-at p 0) (f64-at p 1))
        true
        false)]
    [(= op 10)
      (if (= (f64-at p 0) (f64-at p 1))
        true
        false)]
    [(= op 11)
      (if (!= (f64-at p 0) (f64-at p 1))
        true
        false)]
    [(= op 12) (< (f64-at p 0) 1.5)]
    [(= op 13) (<= (f64-at p 0) 1.5)]
    [(= op 14) (> (f64-at p 0) 1.5)]
    [(= op 15) (>= (f64-at p 0) 1.5)]
    [(= op 16) (= (f64-at p 0) 1.5)]
    [(= op 17) (!= (f64-at p 0) 1.5)]
    [else (> (neg (f64-at p 0)) 1.5)]))

(define (f64-at-cast-signed [p : (& p (Array f64 2))] [op : i64]) : i64
  (cond
    [(< op 0) (f64-at-cast-signed p (+ op 1))]
    [(= op 0) (cast (cast (+ (f64-at p 0) (f64-at p 1)) : i8) : i64)]
    [(= op 1) (cast (cast (+ (f64-at p 0) (f64-at p 1)) : i16) : i64)]
    [(= op 2) (cast (cast (+ (f64-at p 0) (f64-at p 1)) : i32) : i64)]
    [(= op 3) (cast (cast (+ (f64-at p 0) (f64-at p 1)) : i64) : i64)]
    [else (cast (cast (+ (f64-at p 0) (f64-at p 1)) : f32) : i64)]))

(define (f64-at-cast-unsigned [p : (& p (Array f64 2))] [op : i64]) : u64
  (cond
    [(< op 0) (f64-at-cast-unsigned p (+ op 1))]
    [(= op 0) (cast (cast (+ (f64-at p 0) (f64-at p 1)) : u8) : u64)]
    [(= op 1) (cast (cast (+ (f64-at p 0) (f64-at p 1)) : u16) : u64)]
    [(= op 2) (cast (cast (+ (f64-at p 0) (f64-at p 1)) : u32) : u64)]
    [else (cast (+ (f64-at p 0) (f64-at p 1)) : u64)]))

(define (f64-plain-arith [p : (& p (Array f64 2))] [op : i64]) : i64
  (cond
    [(< op 0) (f64-plain-arith p (+ op 1))]
    [(= op 0) (cast (* (+ (f64-plain p 0) (f64-plain p 1)) 4.0) : i64)]
    [(= op 1) (cast (* (- (f64-plain p 0) (f64-plain p 1)) 4.0) : i64)]
    [(= op 2) (cast (* (* (f64-plain p 0) (f64-plain p 1)) 4.0) : i64)]
    [(= op 3) (cast (* (/ (f64-plain p 0) (f64-plain p 1)) 4.0) : i64)]
    [(= op 4) (cast (* (neg (f64-plain p 0)) 4.0) : i64)]
    [(= op 5) (cast (* (+ (f64-plain p 0) 0.5) 4.0) : i64)]
    [(= op 6) (cast (* (* 2.0 (f64-plain p 1)) 4.0) : i64)]
    [else (cast (* (- 1.0 (f64-plain p 0)) 4.0) : i64)]))

(define (f64-plain-compare [p : (& p (Array f64 2))] [op : i64]) : bool
  (cond
    [(< op 0) (f64-plain-compare p (+ op 1))]
    [(= op 0) (< (f64-plain p 0) (f64-plain p 1))]
    [(= op 1) (<= (f64-plain p 0) (f64-plain p 1))]
    [(= op 2) (> (f64-plain p 0) (f64-plain p 1))]
    [(= op 3) (>= (f64-plain p 0) (f64-plain p 1))]
    [(= op 4) (= (f64-plain p 0) (f64-plain p 1))]
    [(= op 5) (!= (f64-plain p 0) (f64-plain p 1))]
    [(= op 6)
      (if (< (f64-plain p 0) (f64-plain p 1))
        true
        false)]
    [(= op 7)
      (if (<= (f64-plain p 0) (f64-plain p 1))
        true
        false)]
    [(= op 8)
      (if (> (f64-plain p 0) (f64-plain p 1))
        true
        false)]
    [(= op 9)
      (if (>= (f64-plain p 0) (f64-plain p 1))
        true
        false)]
    [(= op 10)
      (if (= (f64-plain p 0) (f64-plain p 1))
        true
        false)]
    [(= op 11)
      (if (!= (f64-plain p 0) (f64-plain p 1))
        true
        false)]
    [(= op 12) (< (f64-plain p 0) 1.5)]
    [(= op 13) (<= (f64-plain p 0) 1.5)]
    [(= op 14) (> (f64-plain p 0) 1.5)]
    [(= op 15) (>= (f64-plain p 0) 1.5)]
    [(= op 16) (= (f64-plain p 0) 1.5)]
    [(= op 17) (!= (f64-plain p 0) 1.5)]
    [else (> (neg (f64-plain p 0)) 1.5)]))

(define (f64-plain-cast-signed [p : (& p (Array f64 2))] [op : i64]) : i64
  (cond
    [(< op 0) (f64-plain-cast-signed p (+ op 1))]
    [(= op 0) (cast (cast (+ (f64-plain p 0) (f64-plain p 1)) : i8) : i64)]
    [(= op 1) (cast (cast (+ (f64-plain p 0) (f64-plain p 1)) : i16) : i64)]
    [(= op 2) (cast (cast (+ (f64-plain p 0) (f64-plain p 1)) : i32) : i64)]
    [(= op 3) (cast (cast (+ (f64-plain p 0) (f64-plain p 1)) : i64) : i64)]
    [else (cast (cast (+ (f64-plain p 0) (f64-plain p 1)) : f32) : i64)]))

(define (f64-plain-cast-unsigned [p : (& p (Array f64 2))] [op : i64]) : u64
  (cond
    [(< op 0) (f64-plain-cast-unsigned p (+ op 1))]
    [(= op 0) (cast (cast (+ (f64-plain p 0) (f64-plain p 1)) : u8) : u64)]
    [(= op 1) (cast (cast (+ (f64-plain p 0) (f64-plain p 1)) : u16) : u64)]
    [(= op 2) (cast (cast (+ (f64-plain p 0) (f64-plain p 1)) : u32) : u64)]
    [else (cast (+ (f64-plain p 0) (f64-plain p 1)) : u64)]))

(define (f32-at-arith [p : (& p (Array f32 2))] [op : i64]) : i64
  (cond
    [(< op 0) (f32-at-arith p (+ op 1))]
    [(= op 0) (cast (* (+ (f32-at p 0) (f32-at p 1)) (cast 4.0 : f32)) : i64)]
    [(= op 1) (cast (* (- (f32-at p 0) (f32-at p 1)) (cast 4.0 : f32)) : i64)]
    [(= op 2) (cast (* (* (f32-at p 0) (f32-at p 1)) (cast 4.0 : f32)) : i64)]
    [(= op 3) (cast (* (/ (f32-at p 0) (f32-at p 1)) (cast 4.0 : f32)) : i64)]
    [(= op 4) (cast (* (neg (f32-at p 0)) (cast 4.0 : f32)) : i64)]
    [(= op 5)
      (cast (* (+ (f32-at p 0) (cast 0.5 : f32)) (cast 4.0 : f32)) : i64)]
    [(= op 6)
      (cast (* (* (cast 2.0 : f32) (f32-at p 1)) (cast 4.0 : f32)) : i64)]
    [else (cast (* (- (cast 1.0 : f32) (f32-at p 0)) (cast 4.0 : f32)) : i64)]))

(define (f32-at-compare [p : (& p (Array f32 2))] [op : i64]) : bool
  (cond
    [(< op 0) (f32-at-compare p (+ op 1))]
    [(= op 0) (< (f32-at p 0) (f32-at p 1))]
    [(= op 1) (<= (f32-at p 0) (f32-at p 1))]
    [(= op 2) (> (f32-at p 0) (f32-at p 1))]
    [(= op 3) (>= (f32-at p 0) (f32-at p 1))]
    [(= op 4) (= (f32-at p 0) (f32-at p 1))]
    [(= op 5) (!= (f32-at p 0) (f32-at p 1))]
    [(= op 6)
      (if (< (f32-at p 0) (f32-at p 1))
        true
        false)]
    [(= op 7)
      (if (<= (f32-at p 0) (f32-at p 1))
        true
        false)]
    [(= op 8)
      (if (> (f32-at p 0) (f32-at p 1))
        true
        false)]
    [(= op 9)
      (if (>= (f32-at p 0) (f32-at p 1))
        true
        false)]
    [(= op 10)
      (if (= (f32-at p 0) (f32-at p 1))
        true
        false)]
    [(= op 11)
      (if (!= (f32-at p 0) (f32-at p 1))
        true
        false)]
    [(= op 12) (< (f32-at p 0) (cast 1.5 : f32))]
    [(= op 13) (<= (f32-at p 0) (cast 1.5 : f32))]
    [(= op 14) (> (f32-at p 0) (cast 1.5 : f32))]
    [(= op 15) (>= (f32-at p 0) (cast 1.5 : f32))]
    [(= op 16) (= (f32-at p 0) (cast 1.5 : f32))]
    [(= op 17) (!= (f32-at p 0) (cast 1.5 : f32))]
    [else (> (neg (f32-at p 0)) (cast 1.5 : f32))]))

(define (f32-at-cast-signed [p : (& p (Array f32 2))] [op : i64]) : i64
  (cond
    [(< op 0) (f32-at-cast-signed p (+ op 1))]
    [(= op 0) (cast (cast (+ (f32-at p 0) (f32-at p 1)) : i8) : i64)]
    [(= op 1) (cast (cast (+ (f32-at p 0) (f32-at p 1)) : i16) : i64)]
    [(= op 2) (cast (cast (+ (f32-at p 0) (f32-at p 1)) : i32) : i64)]
    [(= op 3) (cast (cast (+ (f32-at p 0) (f32-at p 1)) : i64) : i64)]
    [else (cast (cast (+ (f32-at p 0) (f32-at p 1)) : f64) : i64)]))

(define (f32-at-cast-unsigned [p : (& p (Array f32 2))] [op : i64]) : u64
  (cond
    [(< op 0) (f32-at-cast-unsigned p (+ op 1))]
    [(= op 0) (cast (cast (+ (f32-at p 0) (f32-at p 1)) : u8) : u64)]
    [(= op 1) (cast (cast (+ (f32-at p 0) (f32-at p 1)) : u16) : u64)]
    [(= op 2) (cast (cast (+ (f32-at p 0) (f32-at p 1)) : u32) : u64)]
    [else (cast (+ (f32-at p 0) (f32-at p 1)) : u64)]))

(define (f32-plain-arith [p : (& p (Array f32 2))] [op : i64]) : i64
  (cond
    [(< op 0) (f32-plain-arith p (+ op 1))]
    [(= op 0)
      (cast (* (+ (f32-plain p 0) (f32-plain p 1)) (cast 4.0 : f32)) : i64)]
    [(= op 1)
      (cast (* (- (f32-plain p 0) (f32-plain p 1)) (cast 4.0 : f32)) : i64)]
    [(= op 2)
      (cast (* (* (f32-plain p 0) (f32-plain p 1)) (cast 4.0 : f32)) : i64)]
    [(= op 3)
      (cast (* (/ (f32-plain p 0) (f32-plain p 1)) (cast 4.0 : f32)) : i64)]
    [(= op 4) (cast (* (neg (f32-plain p 0)) (cast 4.0 : f32)) : i64)]
    [(= op 5)
      (cast (* (+ (f32-plain p 0) (cast 0.5 : f32)) (cast 4.0 : f32)) : i64)]
    [(= op 6)
      (cast (* (* (cast 2.0 : f32) (f32-plain p 1)) (cast 4.0 : f32)) : i64)]
    [else
      (cast (* (- (cast 1.0 : f32) (f32-plain p 0)) (cast 4.0 : f32)) : i64)]))

(define (f32-plain-compare [p : (& p (Array f32 2))] [op : i64]) : bool
  (cond
    [(< op 0) (f32-plain-compare p (+ op 1))]
    [(= op 0) (< (f32-plain p 0) (f32-plain p 1))]
    [(= op 1) (<= (f32-plain p 0) (f32-plain p 1))]
    [(= op 2) (> (f32-plain p 0) (f32-plain p 1))]
    [(= op 3) (>= (f32-plain p 0) (f32-plain p 1))]
    [(= op 4) (= (f32-plain p 0) (f32-plain p 1))]
    [(= op 5) (!= (f32-plain p 0) (f32-plain p 1))]
    [(= op 6)
      (if (< (f32-plain p 0) (f32-plain p 1))
        true
        false)]
    [(= op 7)
      (if (<= (f32-plain p 0) (f32-plain p 1))
        true
        false)]
    [(= op 8)
      (if (> (f32-plain p 0) (f32-plain p 1))
        true
        false)]
    [(= op 9)
      (if (>= (f32-plain p 0) (f32-plain p 1))
        true
        false)]
    [(= op 10)
      (if (= (f32-plain p 0) (f32-plain p 1))
        true
        false)]
    [(= op 11)
      (if (!= (f32-plain p 0) (f32-plain p 1))
        true
        false)]
    [(= op 12) (< (f32-plain p 0) (cast 1.5 : f32))]
    [(= op 13) (<= (f32-plain p 0) (cast 1.5 : f32))]
    [(= op 14) (> (f32-plain p 0) (cast 1.5 : f32))]
    [(= op 15) (>= (f32-plain p 0) (cast 1.5 : f32))]
    [(= op 16) (= (f32-plain p 0) (cast 1.5 : f32))]
    [(= op 17) (!= (f32-plain p 0) (cast 1.5 : f32))]
    [else (> (neg (f32-plain p 0)) (cast 1.5 : f32))]))

(define (f32-plain-cast-signed [p : (& p (Array f32 2))] [op : i64]) : i64
  (cond
    [(< op 0) (f32-plain-cast-signed p (+ op 1))]
    [(= op 0) (cast (cast (+ (f32-plain p 0) (f32-plain p 1)) : i8) : i64)]
    [(= op 1) (cast (cast (+ (f32-plain p 0) (f32-plain p 1)) : i16) : i64)]
    [(= op 2) (cast (cast (+ (f32-plain p 0) (f32-plain p 1)) : i32) : i64)]
    [(= op 3) (cast (cast (+ (f32-plain p 0) (f32-plain p 1)) : i64) : i64)]
    [else (cast (cast (+ (f32-plain p 0) (f32-plain p 1)) : f64) : i64)]))

(define (f32-plain-cast-unsigned [p : (& p (Array f32 2))] [op : i64]) : u64
  (cond
    [(< op 0) (f32-plain-cast-unsigned p (+ op 1))]
    [(= op 0) (cast (cast (+ (f32-plain p 0) (f32-plain p 1)) : u8) : u64)]
    [(= op 1) (cast (cast (+ (f32-plain p 0) (f32-plain p 1)) : u16) : u64)]
    [(= op 2) (cast (cast (+ (f32-plain p 0) (f32-plain p 1)) : u32) : u64)]
    [else (cast (+ (f32-plain p 0) (f32-plain p 1)) : u64)]))

(define (first [p : (& p (Array f64 2))]) : (in p f64)
  (array-ref p 0))

(define (second [p : (& p (Array f64 2))]) : (in p f64)
  (array-ref p 1))

(define (first32 [p : (& p (Array f32 2))]) : (in p f32)
  (array-ref p 0))

(define (second32 [p : (& p (Array f32 2))]) : (in p f32)
  (array-ref p 1))

(define (shape-gt [p : (& p (Array f64 2))]) : i64
  (if (> (first p) (second p))
    42
    7))

(define (shape-castsum [p : (& p (Array f64 2))]) : i64
  (cast (+ (first p) (second p)) : i64))

(define (shape-pick [p : (& p (Array f64 2))] [c : bool]) : (in p f64)
  (if c
    (first p)
    (second p)))

(define (shape-phi [p : (& p (Array f64 2))]) : i64
  (cast (+ (shape-pick p true) (shape-pick p false)) : i64))

(define (shape-sum32 [p : (& p (Array f32 2))]) : i64
  (cast (+ (first32 p) (second32 p)) : i64))

;; 3.0 has zero low bits: its 32-bit-masked key names the label of f64 0.0.
(define (keep-zero [x : f64]) : f64
  (+ x 0.0))

(define (shape-collide [p : (& p (Array f64 2))]) : i64
  (if (> (+ (first p) 0.0) 1.0)
    42
    7))

(define (shape-literal [p : (& p (Array f64 2))]) : i64
  (if (> (+ (first p) 0.5) 1.0)
    42
    7))

(define (shape-nested [p : (& p f64)]) : (in p (in p f64))
  (deref p))

(define (shape-accumulate [p : (& p (Array f64 2))]) : i64
  (let
    [total : f64 0.0]
    (+= total (first p))
    (set! total (+ total (second p)))
    (cast total : i64)))

(define (main) : i64
  (let
    [zero64 : f64 0.0]
    [nan64 : f64 (/ zero64 zero64)]
    [nan32 : f32 (cast nan64 : f32)]
    [f64-arith-0 : (Array f64 2) (array 10000000000.25 3.0)]
    [f64-arith-1 : (Array f64 2) (array 1.5 0.25)]
    [f64-arith-2 : (Array f64 2) (array -2.5 4.0)]
    [f32-arith-0 : (Array f32 2) (array (cast 1.5 : f32) (cast 0.25 : f32))]
    [f32-arith-1 : (Array f32 2) (array (cast -2.5 : f32) (cast 4.0 : f32))]
    [f32-arith-2 : (Array f32 2) (array (cast 1024.5 : f32) (cast 8.0 : f32))]
    [f64-cmp-0 : (Array f64 2) (array 1.5 2.5)]
    [f64-cmp-1 : (Array f64 2) (array 2.5 1.5)]
    [f64-cmp-2 : (Array f64 2) (array 3.0 3.0)]
    [f64-cmp-3 : (Array f64 2) (array -2.0 -1.0)]
    [f64-cmp-4 : (Array f64 2) (array 0.0 -0.0)]
    [f64-cmp-5 : (Array f64 2) (array nan64 1.0)]
    [f64-cast-pos : (Array f64 2) (array 40.0 2.0)]
    [f64-cast-neg : (Array f64 2) (array -40.0 -2.0)]
    [f64-cast-big : (Array f64 2) (array 9.223372036854776e+18 1099511627776.0)]
    [f32-cmp-0 : (Array f32 2) (array (cast 1.5 : f32) (cast 2.5 : f32))]
    [f32-cmp-1 : (Array f32 2) (array (cast 2.5 : f32) (cast 1.5 : f32))]
    [f32-cmp-2 : (Array f32 2) (array (cast 3.0 : f32) (cast 3.0 : f32))]
    [f32-cmp-3 : (Array f32 2) (array (cast -2.0 : f32) (cast -1.0 : f32))]
    [f32-cmp-4 : (Array f32 2) (array (cast 0.0 : f32) (cast -0.0 : f32))]
    [f32-cmp-5 : (Array f32 2) (array nan32 (cast 1.0 : f32))]
    [f32-cast-pos : (Array f32 2) (array (cast 40.0 : f32) (cast 2.0 : f32))]
    [f32-cast-neg : (Array f32 2) (array (cast -40.0 : f32) (cast -2.0 : f32))]
    [f32-cast-big : (Array f32 2)
      (array (cast 9.223372036854776e+18 : f32) (cast 1099511627776.0 : f32))]
    [row-gt : (Array f64 2) (array 3.0 2.0)]
    [row-sum : (Array f64 2) (array 40.0 2.0)]
    [row-sum32 : (Array f32 2) (array (cast 40.0 : f32) (cast 2.0 : f32))]
    [row-collide : (Array f64 2) (array 3.0 2.0)]
    [row-literal : (Array f64 2) (array 1.5 5.0)]
    [nested-value : f64 3.0]
    (begin
      (assert (= (f64-at-arith (& f64-arith-0) 0) 40000000013))
      (assert (= (f64-at-arith (& f64-arith-0) 1) 39999999989))
      (assert (= (f64-at-arith (& f64-arith-0) 2) 120000000003))
      (assert (= (f64-at-arith (& f64-arith-0) 3) 13333333333))
      (assert (= (f64-at-arith (& f64-arith-0) 4) -40000000001))
      (assert (= (f64-at-arith (& f64-arith-0) 5) 40000000003))
      (assert (= (f64-at-arith (& f64-arith-0) 6) 24))
      (assert (= (f64-at-arith (& f64-arith-0) 7) -39999999997))
      (assert (= (f64-at-arith (& f64-arith-1) 0) 7))
      (assert (= (f64-at-arith (& f64-arith-1) 1) 5))
      (assert (= (f64-at-arith (& f64-arith-1) 2) 1))
      (assert (= (f64-at-arith (& f64-arith-1) 3) 24))
      (assert (= (f64-at-arith (& f64-arith-1) 4) -6))
      (assert (= (f64-at-arith (& f64-arith-1) 5) 8))
      (assert (= (f64-at-arith (& f64-arith-1) 6) 2))
      (assert (= (f64-at-arith (& f64-arith-1) 7) -2))
      (assert (= (f64-at-arith (& f64-arith-2) 0) 6))
      (assert (= (f64-at-arith (& f64-arith-2) 1) -26))
      (assert (= (f64-at-arith (& f64-arith-2) 2) -40))
      (assert (= (f64-at-arith (& f64-arith-2) 3) -2))
      (assert (= (f64-at-arith (& f64-arith-2) 4) 10))
      (assert (= (f64-at-arith (& f64-arith-2) 5) -8))
      (assert (= (f64-at-arith (& f64-arith-2) 6) 32))
      (assert (= (f64-at-arith (& f64-arith-2) 7) 14))
      (assert (= (f64-plain-arith (& f64-arith-0) 0) 40000000013))
      (assert (= (f64-plain-arith (& f64-arith-0) 1) 39999999989))
      (assert (= (f64-plain-arith (& f64-arith-0) 2) 120000000003))
      (assert (= (f64-plain-arith (& f64-arith-0) 3) 13333333333))
      (assert (= (f64-plain-arith (& f64-arith-0) 4) -40000000001))
      (assert (= (f64-plain-arith (& f64-arith-0) 5) 40000000003))
      (assert (= (f64-plain-arith (& f64-arith-0) 6) 24))
      (assert (= (f64-plain-arith (& f64-arith-0) 7) -39999999997))
      (assert (= (f64-plain-arith (& f64-arith-1) 0) 7))
      (assert (= (f64-plain-arith (& f64-arith-1) 1) 5))
      (assert (= (f64-plain-arith (& f64-arith-1) 2) 1))
      (assert (= (f64-plain-arith (& f64-arith-1) 3) 24))
      (assert (= (f64-plain-arith (& f64-arith-1) 4) -6))
      (assert (= (f64-plain-arith (& f64-arith-1) 5) 8))
      (assert (= (f64-plain-arith (& f64-arith-1) 6) 2))
      (assert (= (f64-plain-arith (& f64-arith-1) 7) -2))
      (assert (= (f64-plain-arith (& f64-arith-2) 0) 6))
      (assert (= (f64-plain-arith (& f64-arith-2) 1) -26))
      (assert (= (f64-plain-arith (& f64-arith-2) 2) -40))
      (assert (= (f64-plain-arith (& f64-arith-2) 3) -2))
      (assert (= (f64-plain-arith (& f64-arith-2) 4) 10))
      (assert (= (f64-plain-arith (& f64-arith-2) 5) -8))
      (assert (= (f64-plain-arith (& f64-arith-2) 6) 32))
      (assert (= (f64-plain-arith (& f64-arith-2) 7) 14))
      (assert (= (f32-at-arith (& f32-arith-0) 0) 7))
      (assert (= (f32-at-arith (& f32-arith-0) 1) 5))
      (assert (= (f32-at-arith (& f32-arith-0) 2) 1))
      (assert (= (f32-at-arith (& f32-arith-0) 3) 24))
      (assert (= (f32-at-arith (& f32-arith-0) 4) -6))
      (assert (= (f32-at-arith (& f32-arith-0) 5) 8))
      (assert (= (f32-at-arith (& f32-arith-0) 6) 2))
      (assert (= (f32-at-arith (& f32-arith-0) 7) -2))
      (assert (= (f32-at-arith (& f32-arith-1) 0) 6))
      (assert (= (f32-at-arith (& f32-arith-1) 1) -26))
      (assert (= (f32-at-arith (& f32-arith-1) 2) -40))
      (assert (= (f32-at-arith (& f32-arith-1) 3) -2))
      (assert (= (f32-at-arith (& f32-arith-1) 4) 10))
      (assert (= (f32-at-arith (& f32-arith-1) 5) -8))
      (assert (= (f32-at-arith (& f32-arith-1) 6) 32))
      (assert (= (f32-at-arith (& f32-arith-1) 7) 14))
      (assert (= (f32-at-arith (& f32-arith-2) 0) 4130))
      (assert (= (f32-at-arith (& f32-arith-2) 1) 4066))
      (assert (= (f32-at-arith (& f32-arith-2) 2) 32784))
      (assert (= (f32-at-arith (& f32-arith-2) 3) 512))
      (assert (= (f32-at-arith (& f32-arith-2) 4) -4098))
      (assert (= (f32-at-arith (& f32-arith-2) 5) 4100))
      (assert (= (f32-at-arith (& f32-arith-2) 6) 64))
      (assert (= (f32-at-arith (& f32-arith-2) 7) -4094))
      (assert (= (f32-plain-arith (& f32-arith-0) 0) 7))
      (assert (= (f32-plain-arith (& f32-arith-0) 1) 5))
      (assert (= (f32-plain-arith (& f32-arith-0) 2) 1))
      (assert (= (f32-plain-arith (& f32-arith-0) 3) 24))
      (assert (= (f32-plain-arith (& f32-arith-0) 4) -6))
      (assert (= (f32-plain-arith (& f32-arith-0) 5) 8))
      (assert (= (f32-plain-arith (& f32-arith-0) 6) 2))
      (assert (= (f32-plain-arith (& f32-arith-0) 7) -2))
      (assert (= (f32-plain-arith (& f32-arith-1) 0) 6))
      (assert (= (f32-plain-arith (& f32-arith-1) 1) -26))
      (assert (= (f32-plain-arith (& f32-arith-1) 2) -40))
      (assert (= (f32-plain-arith (& f32-arith-1) 3) -2))
      (assert (= (f32-plain-arith (& f32-arith-1) 4) 10))
      (assert (= (f32-plain-arith (& f32-arith-1) 5) -8))
      (assert (= (f32-plain-arith (& f32-arith-1) 6) 32))
      (assert (= (f32-plain-arith (& f32-arith-1) 7) 14))
      (assert (= (f32-plain-arith (& f32-arith-2) 0) 4130))
      (assert (= (f32-plain-arith (& f32-arith-2) 1) 4066))
      (assert (= (f32-plain-arith (& f32-arith-2) 2) 32784))
      (assert (= (f32-plain-arith (& f32-arith-2) 3) 512))
      (assert (= (f32-plain-arith (& f32-arith-2) 4) -4098))
      (assert (= (f32-plain-arith (& f32-arith-2) 5) 4100))
      (assert (= (f32-plain-arith (& f32-arith-2) 6) 64))
      (assert (= (f32-plain-arith (& f32-arith-2) 7) -4094))
      (assert (f64-at-compare (& f64-cmp-0) 0))
      (assert (f64-at-compare (& f64-cmp-0) 6))
      (assert (not (f64-at-compare (& f64-cmp-0) 12)))
      (assert (f64-at-compare (& f64-cmp-0) 1))
      (assert (f64-at-compare (& f64-cmp-0) 7))
      (assert (f64-at-compare (& f64-cmp-0) 13))
      (assert (not (f64-at-compare (& f64-cmp-0) 2)))
      (assert (not (f64-at-compare (& f64-cmp-0) 8)))
      (assert (not (f64-at-compare (& f64-cmp-0) 14)))
      (assert (not (f64-at-compare (& f64-cmp-0) 3)))
      (assert (not (f64-at-compare (& f64-cmp-0) 9)))
      (assert (f64-at-compare (& f64-cmp-0) 15))
      (assert (not (f64-at-compare (& f64-cmp-0) 4)))
      (assert (not (f64-at-compare (& f64-cmp-0) 10)))
      (assert (f64-at-compare (& f64-cmp-0) 16))
      (assert (f64-at-compare (& f64-cmp-0) 5))
      (assert (f64-at-compare (& f64-cmp-0) 11))
      (assert (not (f64-at-compare (& f64-cmp-0) 17)))
      (assert (not (f64-at-compare (& f64-cmp-0) 18)))
      (assert (not (f64-at-compare (& f64-cmp-1) 0)))
      (assert (not (f64-at-compare (& f64-cmp-1) 6)))
      (assert (not (f64-at-compare (& f64-cmp-1) 12)))
      (assert (not (f64-at-compare (& f64-cmp-1) 1)))
      (assert (not (f64-at-compare (& f64-cmp-1) 7)))
      (assert (not (f64-at-compare (& f64-cmp-1) 13)))
      (assert (f64-at-compare (& f64-cmp-1) 2))
      (assert (f64-at-compare (& f64-cmp-1) 8))
      (assert (f64-at-compare (& f64-cmp-1) 14))
      (assert (f64-at-compare (& f64-cmp-1) 3))
      (assert (f64-at-compare (& f64-cmp-1) 9))
      (assert (f64-at-compare (& f64-cmp-1) 15))
      (assert (not (f64-at-compare (& f64-cmp-1) 4)))
      (assert (not (f64-at-compare (& f64-cmp-1) 10)))
      (assert (not (f64-at-compare (& f64-cmp-1) 16)))
      (assert (f64-at-compare (& f64-cmp-1) 5))
      (assert (f64-at-compare (& f64-cmp-1) 11))
      (assert (f64-at-compare (& f64-cmp-1) 17))
      (assert (not (f64-at-compare (& f64-cmp-1) 18)))
      (assert (not (f64-at-compare (& f64-cmp-2) 0)))
      (assert (not (f64-at-compare (& f64-cmp-2) 6)))
      (assert (not (f64-at-compare (& f64-cmp-2) 12)))
      (assert (f64-at-compare (& f64-cmp-2) 1))
      (assert (f64-at-compare (& f64-cmp-2) 7))
      (assert (not (f64-at-compare (& f64-cmp-2) 13)))
      (assert (not (f64-at-compare (& f64-cmp-2) 2)))
      (assert (not (f64-at-compare (& f64-cmp-2) 8)))
      (assert (f64-at-compare (& f64-cmp-2) 14))
      (assert (f64-at-compare (& f64-cmp-2) 3))
      (assert (f64-at-compare (& f64-cmp-2) 9))
      (assert (f64-at-compare (& f64-cmp-2) 15))
      (assert (f64-at-compare (& f64-cmp-2) 4))
      (assert (f64-at-compare (& f64-cmp-2) 10))
      (assert (not (f64-at-compare (& f64-cmp-2) 16)))
      (assert (not (f64-at-compare (& f64-cmp-2) 5)))
      (assert (not (f64-at-compare (& f64-cmp-2) 11)))
      (assert (f64-at-compare (& f64-cmp-2) 17))
      (assert (not (f64-at-compare (& f64-cmp-2) 18)))
      (assert (f64-at-compare (& f64-cmp-3) 0))
      (assert (f64-at-compare (& f64-cmp-3) 6))
      (assert (f64-at-compare (& f64-cmp-3) 12))
      (assert (f64-at-compare (& f64-cmp-3) 1))
      (assert (f64-at-compare (& f64-cmp-3) 7))
      (assert (f64-at-compare (& f64-cmp-3) 13))
      (assert (not (f64-at-compare (& f64-cmp-3) 2)))
      (assert (not (f64-at-compare (& f64-cmp-3) 8)))
      (assert (not (f64-at-compare (& f64-cmp-3) 14)))
      (assert (not (f64-at-compare (& f64-cmp-3) 3)))
      (assert (not (f64-at-compare (& f64-cmp-3) 9)))
      (assert (not (f64-at-compare (& f64-cmp-3) 15)))
      (assert (not (f64-at-compare (& f64-cmp-3) 4)))
      (assert (not (f64-at-compare (& f64-cmp-3) 10)))
      (assert (not (f64-at-compare (& f64-cmp-3) 16)))
      (assert (f64-at-compare (& f64-cmp-3) 5))
      (assert (f64-at-compare (& f64-cmp-3) 11))
      (assert (f64-at-compare (& f64-cmp-3) 17))
      (assert (f64-at-compare (& f64-cmp-3) 18))
      (assert (not (f64-at-compare (& f64-cmp-4) 0)))
      (assert (not (f64-at-compare (& f64-cmp-4) 6)))
      (assert (f64-at-compare (& f64-cmp-4) 12))
      (assert (f64-at-compare (& f64-cmp-4) 1))
      (assert (f64-at-compare (& f64-cmp-4) 7))
      (assert (f64-at-compare (& f64-cmp-4) 13))
      (assert (not (f64-at-compare (& f64-cmp-4) 2)))
      (assert (not (f64-at-compare (& f64-cmp-4) 8)))
      (assert (not (f64-at-compare (& f64-cmp-4) 14)))
      (assert (f64-at-compare (& f64-cmp-4) 3))
      (assert (f64-at-compare (& f64-cmp-4) 9))
      (assert (not (f64-at-compare (& f64-cmp-4) 15)))
      (assert (f64-at-compare (& f64-cmp-4) 4))
      (assert (f64-at-compare (& f64-cmp-4) 10))
      (assert (not (f64-at-compare (& f64-cmp-4) 16)))
      (assert (not (f64-at-compare (& f64-cmp-4) 5)))
      (assert (not (f64-at-compare (& f64-cmp-4) 11)))
      (assert (f64-at-compare (& f64-cmp-4) 17))
      (assert (not (f64-at-compare (& f64-cmp-4) 18)))
      (assert (not (f64-at-compare (& f64-cmp-5) 0)))
      (assert (not (f64-at-compare (& f64-cmp-5) 6)))
      (assert (not (f64-at-compare (& f64-cmp-5) 12)))
      (assert (not (f64-at-compare (& f64-cmp-5) 1)))
      (assert (not (f64-at-compare (& f64-cmp-5) 7)))
      (assert (not (f64-at-compare (& f64-cmp-5) 13)))
      (assert (not (f64-at-compare (& f64-cmp-5) 2)))
      (assert (not (f64-at-compare (& f64-cmp-5) 8)))
      (assert (not (f64-at-compare (& f64-cmp-5) 14)))
      (assert (not (f64-at-compare (& f64-cmp-5) 3)))
      (assert (not (f64-at-compare (& f64-cmp-5) 9)))
      (assert (not (f64-at-compare (& f64-cmp-5) 15)))
      (assert (not (f64-at-compare (& f64-cmp-5) 4)))
      (assert (not (f64-at-compare (& f64-cmp-5) 10)))
      (assert (not (f64-at-compare (& f64-cmp-5) 16)))
      (assert (f64-at-compare (& f64-cmp-5) 5))
      (assert (f64-at-compare (& f64-cmp-5) 11))
      (assert (f64-at-compare (& f64-cmp-5) 17))
      (assert (not (f64-at-compare (& f64-cmp-5) 18)))
      (assert (f64-plain-compare (& f64-cmp-0) 0))
      (assert (f64-plain-compare (& f64-cmp-0) 6))
      (assert (not (f64-plain-compare (& f64-cmp-0) 12)))
      (assert (f64-plain-compare (& f64-cmp-0) 1))
      (assert (f64-plain-compare (& f64-cmp-0) 7))
      (assert (f64-plain-compare (& f64-cmp-0) 13))
      (assert (not (f64-plain-compare (& f64-cmp-0) 2)))
      (assert (not (f64-plain-compare (& f64-cmp-0) 8)))
      (assert (not (f64-plain-compare (& f64-cmp-0) 14)))
      (assert (not (f64-plain-compare (& f64-cmp-0) 3)))
      (assert (not (f64-plain-compare (& f64-cmp-0) 9)))
      (assert (f64-plain-compare (& f64-cmp-0) 15))
      (assert (not (f64-plain-compare (& f64-cmp-0) 4)))
      (assert (not (f64-plain-compare (& f64-cmp-0) 10)))
      (assert (f64-plain-compare (& f64-cmp-0) 16))
      (assert (f64-plain-compare (& f64-cmp-0) 5))
      (assert (f64-plain-compare (& f64-cmp-0) 11))
      (assert (not (f64-plain-compare (& f64-cmp-0) 17)))
      (assert (not (f64-plain-compare (& f64-cmp-0) 18)))
      (assert (not (f64-plain-compare (& f64-cmp-1) 0)))
      (assert (not (f64-plain-compare (& f64-cmp-1) 6)))
      (assert (not (f64-plain-compare (& f64-cmp-1) 12)))
      (assert (not (f64-plain-compare (& f64-cmp-1) 1)))
      (assert (not (f64-plain-compare (& f64-cmp-1) 7)))
      (assert (not (f64-plain-compare (& f64-cmp-1) 13)))
      (assert (f64-plain-compare (& f64-cmp-1) 2))
      (assert (f64-plain-compare (& f64-cmp-1) 8))
      (assert (f64-plain-compare (& f64-cmp-1) 14))
      (assert (f64-plain-compare (& f64-cmp-1) 3))
      (assert (f64-plain-compare (& f64-cmp-1) 9))
      (assert (f64-plain-compare (& f64-cmp-1) 15))
      (assert (not (f64-plain-compare (& f64-cmp-1) 4)))
      (assert (not (f64-plain-compare (& f64-cmp-1) 10)))
      (assert (not (f64-plain-compare (& f64-cmp-1) 16)))
      (assert (f64-plain-compare (& f64-cmp-1) 5))
      (assert (f64-plain-compare (& f64-cmp-1) 11))
      (assert (f64-plain-compare (& f64-cmp-1) 17))
      (assert (not (f64-plain-compare (& f64-cmp-1) 18)))
      (assert (not (f64-plain-compare (& f64-cmp-2) 0)))
      (assert (not (f64-plain-compare (& f64-cmp-2) 6)))
      (assert (not (f64-plain-compare (& f64-cmp-2) 12)))
      (assert (f64-plain-compare (& f64-cmp-2) 1))
      (assert (f64-plain-compare (& f64-cmp-2) 7))
      (assert (not (f64-plain-compare (& f64-cmp-2) 13)))
      (assert (not (f64-plain-compare (& f64-cmp-2) 2)))
      (assert (not (f64-plain-compare (& f64-cmp-2) 8)))
      (assert (f64-plain-compare (& f64-cmp-2) 14))
      (assert (f64-plain-compare (& f64-cmp-2) 3))
      (assert (f64-plain-compare (& f64-cmp-2) 9))
      (assert (f64-plain-compare (& f64-cmp-2) 15))
      (assert (f64-plain-compare (& f64-cmp-2) 4))
      (assert (f64-plain-compare (& f64-cmp-2) 10))
      (assert (not (f64-plain-compare (& f64-cmp-2) 16)))
      (assert (not (f64-plain-compare (& f64-cmp-2) 5)))
      (assert (not (f64-plain-compare (& f64-cmp-2) 11)))
      (assert (f64-plain-compare (& f64-cmp-2) 17))
      (assert (not (f64-plain-compare (& f64-cmp-2) 18)))
      (assert (f64-plain-compare (& f64-cmp-3) 0))
      (assert (f64-plain-compare (& f64-cmp-3) 6))
      (assert (f64-plain-compare (& f64-cmp-3) 12))
      (assert (f64-plain-compare (& f64-cmp-3) 1))
      (assert (f64-plain-compare (& f64-cmp-3) 7))
      (assert (f64-plain-compare (& f64-cmp-3) 13))
      (assert (not (f64-plain-compare (& f64-cmp-3) 2)))
      (assert (not (f64-plain-compare (& f64-cmp-3) 8)))
      (assert (not (f64-plain-compare (& f64-cmp-3) 14)))
      (assert (not (f64-plain-compare (& f64-cmp-3) 3)))
      (assert (not (f64-plain-compare (& f64-cmp-3) 9)))
      (assert (not (f64-plain-compare (& f64-cmp-3) 15)))
      (assert (not (f64-plain-compare (& f64-cmp-3) 4)))
      (assert (not (f64-plain-compare (& f64-cmp-3) 10)))
      (assert (not (f64-plain-compare (& f64-cmp-3) 16)))
      (assert (f64-plain-compare (& f64-cmp-3) 5))
      (assert (f64-plain-compare (& f64-cmp-3) 11))
      (assert (f64-plain-compare (& f64-cmp-3) 17))
      (assert (f64-plain-compare (& f64-cmp-3) 18))
      (assert (not (f64-plain-compare (& f64-cmp-4) 0)))
      (assert (not (f64-plain-compare (& f64-cmp-4) 6)))
      (assert (f64-plain-compare (& f64-cmp-4) 12))
      (assert (f64-plain-compare (& f64-cmp-4) 1))
      (assert (f64-plain-compare (& f64-cmp-4) 7))
      (assert (f64-plain-compare (& f64-cmp-4) 13))
      (assert (not (f64-plain-compare (& f64-cmp-4) 2)))
      (assert (not (f64-plain-compare (& f64-cmp-4) 8)))
      (assert (not (f64-plain-compare (& f64-cmp-4) 14)))
      (assert (f64-plain-compare (& f64-cmp-4) 3))
      (assert (f64-plain-compare (& f64-cmp-4) 9))
      (assert (not (f64-plain-compare (& f64-cmp-4) 15)))
      (assert (f64-plain-compare (& f64-cmp-4) 4))
      (assert (f64-plain-compare (& f64-cmp-4) 10))
      (assert (not (f64-plain-compare (& f64-cmp-4) 16)))
      (assert (not (f64-plain-compare (& f64-cmp-4) 5)))
      (assert (not (f64-plain-compare (& f64-cmp-4) 11)))
      (assert (f64-plain-compare (& f64-cmp-4) 17))
      (assert (not (f64-plain-compare (& f64-cmp-4) 18)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 0)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 6)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 12)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 1)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 7)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 13)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 2)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 8)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 14)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 3)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 9)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 15)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 4)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 10)))
      (assert (not (f64-plain-compare (& f64-cmp-5) 16)))
      (assert (f64-plain-compare (& f64-cmp-5) 5))
      (assert (f64-plain-compare (& f64-cmp-5) 11))
      (assert (f64-plain-compare (& f64-cmp-5) 17))
      (assert (not (f64-plain-compare (& f64-cmp-5) 18)))
      (assert (f32-at-compare (& f32-cmp-0) 0))
      (assert (f32-at-compare (& f32-cmp-0) 6))
      (assert (not (f32-at-compare (& f32-cmp-0) 12)))
      (assert (f32-at-compare (& f32-cmp-0) 1))
      (assert (f32-at-compare (& f32-cmp-0) 7))
      (assert (f32-at-compare (& f32-cmp-0) 13))
      (assert (not (f32-at-compare (& f32-cmp-0) 2)))
      (assert (not (f32-at-compare (& f32-cmp-0) 8)))
      (assert (not (f32-at-compare (& f32-cmp-0) 14)))
      (assert (not (f32-at-compare (& f32-cmp-0) 3)))
      (assert (not (f32-at-compare (& f32-cmp-0) 9)))
      (assert (f32-at-compare (& f32-cmp-0) 15))
      (assert (not (f32-at-compare (& f32-cmp-0) 4)))
      (assert (not (f32-at-compare (& f32-cmp-0) 10)))
      (assert (f32-at-compare (& f32-cmp-0) 16))
      (assert (f32-at-compare (& f32-cmp-0) 5))
      (assert (f32-at-compare (& f32-cmp-0) 11))
      (assert (not (f32-at-compare (& f32-cmp-0) 17)))
      (assert (not (f32-at-compare (& f32-cmp-0) 18)))
      (assert (not (f32-at-compare (& f32-cmp-1) 0)))
      (assert (not (f32-at-compare (& f32-cmp-1) 6)))
      (assert (not (f32-at-compare (& f32-cmp-1) 12)))
      (assert (not (f32-at-compare (& f32-cmp-1) 1)))
      (assert (not (f32-at-compare (& f32-cmp-1) 7)))
      (assert (not (f32-at-compare (& f32-cmp-1) 13)))
      (assert (f32-at-compare (& f32-cmp-1) 2))
      (assert (f32-at-compare (& f32-cmp-1) 8))
      (assert (f32-at-compare (& f32-cmp-1) 14))
      (assert (f32-at-compare (& f32-cmp-1) 3))
      (assert (f32-at-compare (& f32-cmp-1) 9))
      (assert (f32-at-compare (& f32-cmp-1) 15))
      (assert (not (f32-at-compare (& f32-cmp-1) 4)))
      (assert (not (f32-at-compare (& f32-cmp-1) 10)))
      (assert (not (f32-at-compare (& f32-cmp-1) 16)))
      (assert (f32-at-compare (& f32-cmp-1) 5))
      (assert (f32-at-compare (& f32-cmp-1) 11))
      (assert (f32-at-compare (& f32-cmp-1) 17))
      (assert (not (f32-at-compare (& f32-cmp-1) 18)))
      (assert (not (f32-at-compare (& f32-cmp-2) 0)))
      (assert (not (f32-at-compare (& f32-cmp-2) 6)))
      (assert (not (f32-at-compare (& f32-cmp-2) 12)))
      (assert (f32-at-compare (& f32-cmp-2) 1))
      (assert (f32-at-compare (& f32-cmp-2) 7))
      (assert (not (f32-at-compare (& f32-cmp-2) 13)))
      (assert (not (f32-at-compare (& f32-cmp-2) 2)))
      (assert (not (f32-at-compare (& f32-cmp-2) 8)))
      (assert (f32-at-compare (& f32-cmp-2) 14))
      (assert (f32-at-compare (& f32-cmp-2) 3))
      (assert (f32-at-compare (& f32-cmp-2) 9))
      (assert (f32-at-compare (& f32-cmp-2) 15))
      (assert (f32-at-compare (& f32-cmp-2) 4))
      (assert (f32-at-compare (& f32-cmp-2) 10))
      (assert (not (f32-at-compare (& f32-cmp-2) 16)))
      (assert (not (f32-at-compare (& f32-cmp-2) 5)))
      (assert (not (f32-at-compare (& f32-cmp-2) 11)))
      (assert (f32-at-compare (& f32-cmp-2) 17))
      (assert (not (f32-at-compare (& f32-cmp-2) 18)))
      (assert (f32-at-compare (& f32-cmp-3) 0))
      (assert (f32-at-compare (& f32-cmp-3) 6))
      (assert (f32-at-compare (& f32-cmp-3) 12))
      (assert (f32-at-compare (& f32-cmp-3) 1))
      (assert (f32-at-compare (& f32-cmp-3) 7))
      (assert (f32-at-compare (& f32-cmp-3) 13))
      (assert (not (f32-at-compare (& f32-cmp-3) 2)))
      (assert (not (f32-at-compare (& f32-cmp-3) 8)))
      (assert (not (f32-at-compare (& f32-cmp-3) 14)))
      (assert (not (f32-at-compare (& f32-cmp-3) 3)))
      (assert (not (f32-at-compare (& f32-cmp-3) 9)))
      (assert (not (f32-at-compare (& f32-cmp-3) 15)))
      (assert (not (f32-at-compare (& f32-cmp-3) 4)))
      (assert (not (f32-at-compare (& f32-cmp-3) 10)))
      (assert (not (f32-at-compare (& f32-cmp-3) 16)))
      (assert (f32-at-compare (& f32-cmp-3) 5))
      (assert (f32-at-compare (& f32-cmp-3) 11))
      (assert (f32-at-compare (& f32-cmp-3) 17))
      (assert (f32-at-compare (& f32-cmp-3) 18))
      (assert (not (f32-at-compare (& f32-cmp-4) 0)))
      (assert (not (f32-at-compare (& f32-cmp-4) 6)))
      (assert (f32-at-compare (& f32-cmp-4) 12))
      (assert (f32-at-compare (& f32-cmp-4) 1))
      (assert (f32-at-compare (& f32-cmp-4) 7))
      (assert (f32-at-compare (& f32-cmp-4) 13))
      (assert (not (f32-at-compare (& f32-cmp-4) 2)))
      (assert (not (f32-at-compare (& f32-cmp-4) 8)))
      (assert (not (f32-at-compare (& f32-cmp-4) 14)))
      (assert (f32-at-compare (& f32-cmp-4) 3))
      (assert (f32-at-compare (& f32-cmp-4) 9))
      (assert (not (f32-at-compare (& f32-cmp-4) 15)))
      (assert (f32-at-compare (& f32-cmp-4) 4))
      (assert (f32-at-compare (& f32-cmp-4) 10))
      (assert (not (f32-at-compare (& f32-cmp-4) 16)))
      (assert (not (f32-at-compare (& f32-cmp-4) 5)))
      (assert (not (f32-at-compare (& f32-cmp-4) 11)))
      (assert (f32-at-compare (& f32-cmp-4) 17))
      (assert (not (f32-at-compare (& f32-cmp-4) 18)))
      (assert (not (f32-at-compare (& f32-cmp-5) 0)))
      (assert (not (f32-at-compare (& f32-cmp-5) 6)))
      (assert (not (f32-at-compare (& f32-cmp-5) 12)))
      (assert (not (f32-at-compare (& f32-cmp-5) 1)))
      (assert (not (f32-at-compare (& f32-cmp-5) 7)))
      (assert (not (f32-at-compare (& f32-cmp-5) 13)))
      (assert (not (f32-at-compare (& f32-cmp-5) 2)))
      (assert (not (f32-at-compare (& f32-cmp-5) 8)))
      (assert (not (f32-at-compare (& f32-cmp-5) 14)))
      (assert (not (f32-at-compare (& f32-cmp-5) 3)))
      (assert (not (f32-at-compare (& f32-cmp-5) 9)))
      (assert (not (f32-at-compare (& f32-cmp-5) 15)))
      (assert (not (f32-at-compare (& f32-cmp-5) 4)))
      (assert (not (f32-at-compare (& f32-cmp-5) 10)))
      (assert (not (f32-at-compare (& f32-cmp-5) 16)))
      (assert (f32-at-compare (& f32-cmp-5) 5))
      (assert (f32-at-compare (& f32-cmp-5) 11))
      (assert (f32-at-compare (& f32-cmp-5) 17))
      (assert (not (f32-at-compare (& f32-cmp-5) 18)))
      (assert (f32-plain-compare (& f32-cmp-0) 0))
      (assert (f32-plain-compare (& f32-cmp-0) 6))
      (assert (not (f32-plain-compare (& f32-cmp-0) 12)))
      (assert (f32-plain-compare (& f32-cmp-0) 1))
      (assert (f32-plain-compare (& f32-cmp-0) 7))
      (assert (f32-plain-compare (& f32-cmp-0) 13))
      (assert (not (f32-plain-compare (& f32-cmp-0) 2)))
      (assert (not (f32-plain-compare (& f32-cmp-0) 8)))
      (assert (not (f32-plain-compare (& f32-cmp-0) 14)))
      (assert (not (f32-plain-compare (& f32-cmp-0) 3)))
      (assert (not (f32-plain-compare (& f32-cmp-0) 9)))
      (assert (f32-plain-compare (& f32-cmp-0) 15))
      (assert (not (f32-plain-compare (& f32-cmp-0) 4)))
      (assert (not (f32-plain-compare (& f32-cmp-0) 10)))
      (assert (f32-plain-compare (& f32-cmp-0) 16))
      (assert (f32-plain-compare (& f32-cmp-0) 5))
      (assert (f32-plain-compare (& f32-cmp-0) 11))
      (assert (not (f32-plain-compare (& f32-cmp-0) 17)))
      (assert (not (f32-plain-compare (& f32-cmp-0) 18)))
      (assert (not (f32-plain-compare (& f32-cmp-1) 0)))
      (assert (not (f32-plain-compare (& f32-cmp-1) 6)))
      (assert (not (f32-plain-compare (& f32-cmp-1) 12)))
      (assert (not (f32-plain-compare (& f32-cmp-1) 1)))
      (assert (not (f32-plain-compare (& f32-cmp-1) 7)))
      (assert (not (f32-plain-compare (& f32-cmp-1) 13)))
      (assert (f32-plain-compare (& f32-cmp-1) 2))
      (assert (f32-plain-compare (& f32-cmp-1) 8))
      (assert (f32-plain-compare (& f32-cmp-1) 14))
      (assert (f32-plain-compare (& f32-cmp-1) 3))
      (assert (f32-plain-compare (& f32-cmp-1) 9))
      (assert (f32-plain-compare (& f32-cmp-1) 15))
      (assert (not (f32-plain-compare (& f32-cmp-1) 4)))
      (assert (not (f32-plain-compare (& f32-cmp-1) 10)))
      (assert (not (f32-plain-compare (& f32-cmp-1) 16)))
      (assert (f32-plain-compare (& f32-cmp-1) 5))
      (assert (f32-plain-compare (& f32-cmp-1) 11))
      (assert (f32-plain-compare (& f32-cmp-1) 17))
      (assert (not (f32-plain-compare (& f32-cmp-1) 18)))
      (assert (not (f32-plain-compare (& f32-cmp-2) 0)))
      (assert (not (f32-plain-compare (& f32-cmp-2) 6)))
      (assert (not (f32-plain-compare (& f32-cmp-2) 12)))
      (assert (f32-plain-compare (& f32-cmp-2) 1))
      (assert (f32-plain-compare (& f32-cmp-2) 7))
      (assert (not (f32-plain-compare (& f32-cmp-2) 13)))
      (assert (not (f32-plain-compare (& f32-cmp-2) 2)))
      (assert (not (f32-plain-compare (& f32-cmp-2) 8)))
      (assert (f32-plain-compare (& f32-cmp-2) 14))
      (assert (f32-plain-compare (& f32-cmp-2) 3))
      (assert (f32-plain-compare (& f32-cmp-2) 9))
      (assert (f32-plain-compare (& f32-cmp-2) 15))
      (assert (f32-plain-compare (& f32-cmp-2) 4))
      (assert (f32-plain-compare (& f32-cmp-2) 10))
      (assert (not (f32-plain-compare (& f32-cmp-2) 16)))
      (assert (not (f32-plain-compare (& f32-cmp-2) 5)))
      (assert (not (f32-plain-compare (& f32-cmp-2) 11)))
      (assert (f32-plain-compare (& f32-cmp-2) 17))
      (assert (not (f32-plain-compare (& f32-cmp-2) 18)))
      (assert (f32-plain-compare (& f32-cmp-3) 0))
      (assert (f32-plain-compare (& f32-cmp-3) 6))
      (assert (f32-plain-compare (& f32-cmp-3) 12))
      (assert (f32-plain-compare (& f32-cmp-3) 1))
      (assert (f32-plain-compare (& f32-cmp-3) 7))
      (assert (f32-plain-compare (& f32-cmp-3) 13))
      (assert (not (f32-plain-compare (& f32-cmp-3) 2)))
      (assert (not (f32-plain-compare (& f32-cmp-3) 8)))
      (assert (not (f32-plain-compare (& f32-cmp-3) 14)))
      (assert (not (f32-plain-compare (& f32-cmp-3) 3)))
      (assert (not (f32-plain-compare (& f32-cmp-3) 9)))
      (assert (not (f32-plain-compare (& f32-cmp-3) 15)))
      (assert (not (f32-plain-compare (& f32-cmp-3) 4)))
      (assert (not (f32-plain-compare (& f32-cmp-3) 10)))
      (assert (not (f32-plain-compare (& f32-cmp-3) 16)))
      (assert (f32-plain-compare (& f32-cmp-3) 5))
      (assert (f32-plain-compare (& f32-cmp-3) 11))
      (assert (f32-plain-compare (& f32-cmp-3) 17))
      (assert (f32-plain-compare (& f32-cmp-3) 18))
      (assert (not (f32-plain-compare (& f32-cmp-4) 0)))
      (assert (not (f32-plain-compare (& f32-cmp-4) 6)))
      (assert (f32-plain-compare (& f32-cmp-4) 12))
      (assert (f32-plain-compare (& f32-cmp-4) 1))
      (assert (f32-plain-compare (& f32-cmp-4) 7))
      (assert (f32-plain-compare (& f32-cmp-4) 13))
      (assert (not (f32-plain-compare (& f32-cmp-4) 2)))
      (assert (not (f32-plain-compare (& f32-cmp-4) 8)))
      (assert (not (f32-plain-compare (& f32-cmp-4) 14)))
      (assert (f32-plain-compare (& f32-cmp-4) 3))
      (assert (f32-plain-compare (& f32-cmp-4) 9))
      (assert (not (f32-plain-compare (& f32-cmp-4) 15)))
      (assert (f32-plain-compare (& f32-cmp-4) 4))
      (assert (f32-plain-compare (& f32-cmp-4) 10))
      (assert (not (f32-plain-compare (& f32-cmp-4) 16)))
      (assert (not (f32-plain-compare (& f32-cmp-4) 5)))
      (assert (not (f32-plain-compare (& f32-cmp-4) 11)))
      (assert (f32-plain-compare (& f32-cmp-4) 17))
      (assert (not (f32-plain-compare (& f32-cmp-4) 18)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 0)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 6)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 12)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 1)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 7)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 13)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 2)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 8)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 14)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 3)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 9)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 15)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 4)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 10)))
      (assert (not (f32-plain-compare (& f32-cmp-5) 16)))
      (assert (f32-plain-compare (& f32-cmp-5) 5))
      (assert (f32-plain-compare (& f32-cmp-5) 11))
      (assert (f32-plain-compare (& f32-cmp-5) 17))
      (assert (not (f32-plain-compare (& f32-cmp-5) 18)))
      (assert (= (f64-at-cast-signed (& f64-cast-pos) 0) 42))
      (assert (= (f64-at-cast-signed (& f64-cast-neg) 0) -42))
      (assert (= (f64-at-cast-signed (& f64-cast-pos) 1) 42))
      (assert (= (f64-at-cast-signed (& f64-cast-neg) 1) -42))
      (assert (= (f64-at-cast-signed (& f64-cast-pos) 2) 42))
      (assert (= (f64-at-cast-signed (& f64-cast-neg) 2) -42))
      (assert (= (f64-at-cast-signed (& f64-cast-pos) 3) 42))
      (assert (= (f64-at-cast-signed (& f64-cast-neg) 3) -42))
      (assert (= (f64-at-cast-signed (& f64-cast-pos) 4) 42))
      (assert (= (f64-at-cast-unsigned (& f64-cast-pos) 0) (cast 42 : u64)))
      (assert (= (f64-at-cast-unsigned (& f64-cast-pos) 1) (cast 42 : u64)))
      (assert (= (f64-at-cast-unsigned (& f64-cast-pos) 2) (cast 42 : u64)))
      (assert (= (f64-at-cast-unsigned (& f64-cast-pos) 3) (cast 42 : u64)))
      (assert
        (=
          (f64-at-cast-unsigned (& f64-cast-big) 3)
          (+ (shl (cast 1 : u64) 63) (shl (cast 1 : u64) 40))))
      (assert (= (f64-plain-cast-signed (& f64-cast-pos) 0) 42))
      (assert (= (f64-plain-cast-signed (& f64-cast-neg) 0) -42))
      (assert (= (f64-plain-cast-signed (& f64-cast-pos) 1) 42))
      (assert (= (f64-plain-cast-signed (& f64-cast-neg) 1) -42))
      (assert (= (f64-plain-cast-signed (& f64-cast-pos) 2) 42))
      (assert (= (f64-plain-cast-signed (& f64-cast-neg) 2) -42))
      (assert (= (f64-plain-cast-signed (& f64-cast-pos) 3) 42))
      (assert (= (f64-plain-cast-signed (& f64-cast-neg) 3) -42))
      (assert (= (f64-plain-cast-signed (& f64-cast-pos) 4) 42))
      (assert (= (f64-plain-cast-unsigned (& f64-cast-pos) 0) (cast 42 : u64)))
      (assert (= (f64-plain-cast-unsigned (& f64-cast-pos) 1) (cast 42 : u64)))
      (assert (= (f64-plain-cast-unsigned (& f64-cast-pos) 2) (cast 42 : u64)))
      (assert (= (f64-plain-cast-unsigned (& f64-cast-pos) 3) (cast 42 : u64)))
      (assert
        (=
          (f64-plain-cast-unsigned (& f64-cast-big) 3)
          (+ (shl (cast 1 : u64) 63) (shl (cast 1 : u64) 40))))
      (assert (= (f32-at-cast-signed (& f32-cast-pos) 0) 42))
      (assert (= (f32-at-cast-signed (& f32-cast-neg) 0) -42))
      (assert (= (f32-at-cast-signed (& f32-cast-pos) 1) 42))
      (assert (= (f32-at-cast-signed (& f32-cast-neg) 1) -42))
      (assert (= (f32-at-cast-signed (& f32-cast-pos) 2) 42))
      (assert (= (f32-at-cast-signed (& f32-cast-neg) 2) -42))
      (assert (= (f32-at-cast-signed (& f32-cast-pos) 3) 42))
      (assert (= (f32-at-cast-signed (& f32-cast-neg) 3) -42))
      (assert (= (f32-at-cast-signed (& f32-cast-pos) 4) 42))
      (assert (= (f32-at-cast-unsigned (& f32-cast-pos) 0) (cast 42 : u64)))
      (assert (= (f32-at-cast-unsigned (& f32-cast-pos) 1) (cast 42 : u64)))
      (assert (= (f32-at-cast-unsigned (& f32-cast-pos) 2) (cast 42 : u64)))
      (assert (= (f32-at-cast-unsigned (& f32-cast-pos) 3) (cast 42 : u64)))
      (assert
        (=
          (f32-at-cast-unsigned (& f32-cast-big) 3)
          (+ (shl (cast 1 : u64) 63) (shl (cast 1 : u64) 40))))
      (assert (= (f32-plain-cast-signed (& f32-cast-pos) 0) 42))
      (assert (= (f32-plain-cast-signed (& f32-cast-neg) 0) -42))
      (assert (= (f32-plain-cast-signed (& f32-cast-pos) 1) 42))
      (assert (= (f32-plain-cast-signed (& f32-cast-neg) 1) -42))
      (assert (= (f32-plain-cast-signed (& f32-cast-pos) 2) 42))
      (assert (= (f32-plain-cast-signed (& f32-cast-neg) 2) -42))
      (assert (= (f32-plain-cast-signed (& f32-cast-pos) 3) 42))
      (assert (= (f32-plain-cast-signed (& f32-cast-neg) 3) -42))
      (assert (= (f32-plain-cast-signed (& f32-cast-pos) 4) 42))
      (assert (= (f32-plain-cast-unsigned (& f32-cast-pos) 0) (cast 42 : u64)))
      (assert (= (f32-plain-cast-unsigned (& f32-cast-pos) 1) (cast 42 : u64)))
      (assert (= (f32-plain-cast-unsigned (& f32-cast-pos) 2) (cast 42 : u64)))
      (assert (= (f32-plain-cast-unsigned (& f32-cast-pos) 3) (cast 42 : u64)))
      (assert
        (=
          (f32-plain-cast-unsigned (& f32-cast-big) 3)
          (+ (shl (cast 1 : u64) 63) (shl (cast 1 : u64) 40))))
      (assert (= (shape-gt (& row-gt)) 42))
      (assert (= (shape-castsum (& row-sum)) 42))
      (assert (= (shape-phi (& row-sum)) 42))
      (assert (= (shape-sum32 (& row-sum32)) 42))
      (assert (= (shape-collide (& row-collide)) 42))
      (assert (= (keep-zero 1.0) 1.0))
      (assert (= (shape-literal (& row-literal)) 42))
      (assert (> (+ (shape-nested (& nested-value)) 0.5) 1.0))
      (assert (= (shape-accumulate (& row-sum)) 42))
      (- 42 failures))))