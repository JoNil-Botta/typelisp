;; Memory-class struct/enum and Tuple/Array results share one hidden-result
;; convention (#7887): a leading caller-owned pointer, returned as `u64`. This
;; exercises it across direct calls with more than six integer arguments,
;; SSE-heavy signatures, capturing closures, function-value (indirect) calls,
;; direct and indirect tail calls, and a `try` early exit that must build its
;; `Err` in the caller's slot. Inputs come from the argument count so no path
;; folds away.
(import stdlib.io)

(defstruct Quad
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(defstruct FQuad
  (a f64)
  (b f64)
  (c f64)
  (d f64))

(defenum QuadResult
  (Ok Quad)
  (Err i64))

(defenum Check
  (Ok)
  (Err i64))

;; Eight integer arguments: with a trailing pointer the result slot would go
;; to the stack; the leading pointer always travels in the first register.
(define (quad8
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]) : Quad
  (Quad (+ a b) (+ c d) (+ e f) (+ g h)))

(define (tuple8
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]) : (Tuple i64 i64 i64 i64)
  (tuple (+ a b) (+ c d) (+ e f) (+ g h)))

(define (fquad
  [a : f64]
  [b : f64]
  [c : f64]
  [d : f64]
  [e : f64]
  [f : f64]
  [g : f64]
  [h : f64]
  [i : f64]
  [n : i64]) : FQuad
  (FQuad (+ a b) (+ c d) (+ e (+ f g)) (+ h (+ i (cast n : f64)))))

;; Direct tail calls forward the caller's own slot, including past six
;; integer arguments, and through a self-recursive loop.
(define (quad8-tail
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]) : Quad
  (if (> a 3)
    (quad8-tail (- a 1) b c d e f g (+ h 1))
    (quad8 a b c d e f g h)))

(define (check [x : i64]) : Check
  (if (> x 0)
    Ok
    (Err (- 0 x))))

(define (checked [x : i64]) : QuadResult
  (let
    [_ (try (check x))]
    (Ok (Quad x x x x))))

(define (apply-quad [f : (-> i64 Quad)] [x : i64]) : Quad
  (f x))

;; An indirect tail call through a function value forwards the slot too.
(define (apply-quad-tail [f : (-> i64 Quad)] [x : i64]) : Quad
  (f (+ x 1)))

(define (quad-of [x : i64]) : Quad
  (Quad x (* 2 x) (* 3 x) (* 4 x)))

(define (quad-sum [q : Quad]) : i64
  (+ q.a q.b q.c q.d))

(define (tuple-sum [t : (Tuple i64 i64 i64 i64)]) : i64
  (+ (tuple-ref t 0) (tuple-ref t 1) (tuple-ref t 2) (tuple-ref t 3)))

(define (result-score [r : QuadResult]) : i64
  (match r
    [(Ok q) (quad-sum q)]
    [(Err e) (- 0 e)]))

(define (main) : i64
  (let
    [one : i64 (io.arg-count)]
    [k : i64 (+ one 1)]
    ;; Same layout, same transport: 8 both ways.
    [direct : i64 (quad-sum (quad8 one one one one one one one one))]
    [structural : i64 (tuple-sum (tuple8 one one one one one one one one))]
    [fq : FQuad (fquad 0.5 0.5 1.0 1.0 0.25 0.25 0.5 1.0 1.0 one)]
    [fsum : i64 (cast (+ fq.a fq.b fq.c fq.d) : i64)]
    ;; quad8-tail(5, 1, ...) loops twice, then quad8(3, 1, ..., 3): 12.
    [tailed : i64 (quad-sum (quad8-tail 5 one one one one one one one))]
    [captured : (-> i64 Quad)
      (lambda ([x : i64]) : Quad
        (Quad x k x k))]
    ;; 1 + 2 + 1 + 2 = 6.
    [closure : i64 (quad-sum (apply-quad captured one))]
    ;; quad-of 3 = 3 + 6 + 9 + 12 = 30.
    [indirect : i64 (quad-sum (apply-quad-tail quad-of k))]
    ;; Ok path: 4 * 2 = 8; Err path: check(-4) propagates 4 -> -4.
    [ok-path : i64 (result-score (checked k))]
    [err-path : i64 (result-score (checked (- 0 (* 2 k))))]
    (if (and
      (= direct 8)
      (= structural 8)
      (= fsum 7)
      (= tailed 12)
      (= closure 6)
      (= indirect 30)
      (= ok-path 8)
      (= err-path -4))
      42
      (+
        100
        (if (= direct 8)
          0
          1)
        (if (= structural 8)
          0
          2)
        (if (= fsum 7)
          0
          4)
        (if (= tailed 12)
          0
          8)
        (if (= closure 6)
          0
          16)
        (if (= indirect 30)
          0
          32)
        (if (= ok-path 8)
          0
          64)))))