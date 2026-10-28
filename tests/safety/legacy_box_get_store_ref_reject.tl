(import stdlib.io)

(defstruct Store
  (slots (__tl_dyn-array String))
  (len i64))

(defmacro (first-slot [b : Expr]) : Expr
  `(let
    [s (& (box-get ,b))]
    (clone (array-ref s.slots 0))))

(define (first-via-ref [b : (& b (Box Store))]) : String
  (first-slot b))

(define (main) : i64
  (let
    [slots : (__tl_dyn-array String) (__tl_make-array String 2)]
    [_s : unit (set! (array-ref slots 0) "hello")]
    [bx : (Box Store) (box (Store slots 1))]
    (begin
      (io.println "via-ref=[{}]" (first-via-ref (& bx)))
      0)))