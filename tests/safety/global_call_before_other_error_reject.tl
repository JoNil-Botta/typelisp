;: The call that may assign borrowed `g` is reported although a later
;: statement of the body has an ownership error of its own (#7904).
(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (rebind!) : unit
  (set! g (Big 9 9 9 9)))

(define (field-a [r : (& r Big)]) : (& r i64)
  (& r.a))

(define (read [r : (& r i64)] [_u : unit]) : i64
  (deref r))

(define (take [n : (& n i64)]) : i64
  1)

(define (f [n : i64]) : i64
  (let
    [k : i64 (read (field-a (& g)) (rebind!))]
    [borrowed : (& n i64) (& n)]
    (begin
      (set! n 2)
      (+ k (take borrowed)))))

(define (main) : i64
  (f 1))