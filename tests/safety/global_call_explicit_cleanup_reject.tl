;: An explicit call of a generated struct cleanup (`close-handle`, whose
;: field hook assigns `g`) while an earlier argument still borrows `g` (#7904).
(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (field-a [r : (& r Big)]) : (& r i64)
  (& r.a))

(define (read [r : (& r i64)] [n : i64]) : i64
  (+ n (deref r)))

(define (drop-word [n : i64]) : unit
  (set! g (Big n n n n)))

(defstruct Handle
  (:cleanup close-handle)
  (n i64 (:cleanup drop-word)))

(define (main) : i64
  (read
    (field-a (& g))
    (begin
      (close-handle (Handle 9))
      0)))