;; A plain variable beside a region-read scalar operand is read as itself and
;; taken at the operand's region-tagged type: the region tag only constrains
;; where a value may escape, and an operator result that is compared escapes
;; nothing (SPEC 3.9, 4.7.2; #9737).
(define global-i64 : i64
  5)
(define global-f64 : f64
  1.5)

(define (read-i64 [p : (& p i64)]) : (in p i64)
  (deref p))

(define (read-f64 [p : (& p f64)]) : (in p f64)
  (deref p))

(define (local-add-i64 [p : (& p i64)]) : bool
  (let
    [x : i64 3]
    (= (+ (read-i64 p) x) 10)))

(define (param-add-i64 [p : (& p i64)] [x : i64]) : bool
  (= (+ (read-i64 p) x) 11))

(define (global-add-i64 [p : (& p i64)]) : bool
  (= (+ (read-i64 p) global-i64) 12))

(define (local-compare-i64 [p : (& p i64)]) : bool
  (let
    [x : i64 6]
    (> (read-i64 p) x)))

(define (local-add-f64 [p : (& p f64)]) : bool
  (let
    [x : f64 0.25]
    (= (+ (read-f64 p) x) 2.75)))

(define (param-add-f64 [p : (& p f64)] [x : f64]) : bool
  (= (+ (read-f64 p) x) 3.0))

(define (global-add-f64 [p : (& p f64)]) : bool
  (= (+ (read-f64 p) global-f64) 4.0))

(define (local-compare-f64 [p : (& p f64)]) : bool
  (let
    [x : f64 2.0]
    (> (read-f64 p) x)))

;; The other operators take the same conversion.
(define (sub-mul-div-i64 [p : (& p i64)] [x : i64]) : bool
  (and
    (= (- (read-i64 p) x) 5)
    (= (* (read-i64 p) x) 14)
    (= (/ (read-i64 p) x) 3)
    (= (% (read-i64 p) x) 1)))

(define (sub-mul-div-f64 [p : (& p f64)] [x : f64]) : bool
  (and
    (= (- (read-f64 p) x) 0.5)
    (= (* (read-f64 p) x) 5.0)
    (= (/ (read-f64 p) x) 1.25)))

(define (compares-i64 [p : (& p i64)] [x : i64]) : bool
  (and (< x (read-i64 p)) (>= (read-i64 p) x) (!= (read-i64 p) x)))

;; A computed right operand whose branches are names.
(define (branch-operand-i64 [p : (& p i64)] [x : i64] [y : i64]) : bool
  (=
    (+
      (read-i64 p)
      (if (> x y)
        x
        y))
    16))

;; A name at a region-tagged scalar parameter, as an expression already is.
(define (tagged-parameter [p : (& p i64)] [v : (in p i64)]) : bool
  (> v 1))

(define (name-at-tagged-parameter [p : (& p i64)] [x : i64]) : bool
  (tagged-parameter p x))

(define (expression-at-tagged-parameter [p : (& p i64)] [x : i64]) : bool
  (tagged-parameter p (+ x 0)))

(define (main) : i64
  (let
    [a : i64 7]
    [b : f64 2.5]
    (if (and
      (local-add-i64 (& a))
      (param-add-i64 (& a) 4)
      (global-add-i64 (& a))
      (local-compare-i64 (& a))
      (local-add-f64 (& b))
      (param-add-f64 (& b) 0.5)
      (global-add-f64 (& b))
      (local-compare-f64 (& b))
      (sub-mul-div-i64 (& a) 2)
      (sub-mul-div-f64 (& b) 2.0)
      (compares-i64 (& a) 2)
      (branch-operand-i64 (& a) 9 4)
      (name-at-tagged-parameter (& a) 2)
      (expression-at-tagged-parameter (& a) 2))
      42
      7)))