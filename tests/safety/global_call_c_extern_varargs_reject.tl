;; An open C varargs extern may receive a callback pointer in its variadic tail
;; and invoke TypeLisp code that mutates a borrowed global.
(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(extern (dispatch [tag : i64] ...) : i64 (:symbol "dispatch"))

(define (rebind!) : unit
  (set! g (Big 9 9 9 9)))

(define taken : (-> unit)
  rebind!)

(define (read-after [r : (& r Big)]) : i64
  (begin
    (unsafe
      (dispatch 0))
    r.a))

(define (main) : i64
  (read-after (& g)))