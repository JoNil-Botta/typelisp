;; `program` outlives every lifetime: a function may return a `(& program T)`
;; reference, or an aggregate that stores one, without an input tied to it
;; (#8630).
(defstruct Named
  (name (& program str)))

(define greeting : Named
  (Named "hello"))

(define (name-of [named : Named]) : (& program str)
  named.name)

(define (greeting-name) : (& program str)
  greeting.name)

(define (make-named) : Named
  (Named "world"))

(define (main) : i64
  (if (and
    (= (__tl_string_ref (name-of (make-named)) 0) 'w')
    (= (__tl_string_ref (greeting-name) 0) 'h'))
    42
    1))