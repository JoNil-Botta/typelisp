;; Explicit and elided mutable lifetimes and
;; return/local/call contexts must preserve caller storage across arena reset.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (sum-explicit [p : (& r i64)] [b : (&mut m (RefBox r))]) : i64
  (return
    (with-arena
      q
      (let
        [x : (Box i64) (box 30)]
        (set! b.value p)
        (+ (deref x) (deref b.value))))))

(define (read-int [value : i64]) : i64
  value)

(define (sum-local [p : (& r i64)] [b : (&mut (RefBox r))]) : i64
  (let
    [result : i64
      (with-arena
        q
        (let
          [x : (Box i64) (box 30)]
          (set! b.value p)
          (+ (deref x) (deref b.value))))]
    result))

(define (sum-argument [p : (& r i64)] [b : (&mut (RefBox r))]) : i64
  (read-int
    (with-arena
      q
      (let
        [x : (Box i64) (box 30)]
        (set! b.value p)
        (+ (deref x) (deref b.value))))))

(define (main) : i64
  (let
    [seed : i64 12]
    [holder : (RefBox seed) (RefBox (& seed))]
    (if (and
      (= (sum-explicit (& seed) (&mut holder)) 42)
      (= (sum-local (& seed) (&mut holder)) 42)
      (= (sum-argument (& seed) (&mut holder)) 42)
      (= (deref holder.value) 12))
      42
      1)))