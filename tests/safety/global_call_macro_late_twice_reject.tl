;: Each expansion of one macro template is its own late query: both `one`
;: and `two` are reported, each with its expansion (#7904).
(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(defmacro (via-read-after [x : Expr]) : Expr
  `(read-after ,x))

(define (one) : i64
  (via-read-after (& g)))

(define (two) : i64
  (via-read-after (& g)))

(define (main) : i64
  (+ (one) (two)))

(define (read-after [r : (& r Big)]) : i64
  (drop-temporary)
  r.a)

(define (drop-word [n : i64]) : unit
  (set! g (Big n n n n)))

(defstruct Handle
  (:cleanup close-handle)
  (n i64 (:cleanup drop-word)))

(define (fd [h : (& Handle)]) : i64
  h.n)

(define (drop-temporary) : unit
  (fd (& (Handle 9)))
  unit)