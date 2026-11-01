(import stdlib.io)

(defstruct Store
  (slots (__tl_dyn-array String))
  (len i64))

(defenum Chunks
  (Nil)
  (Dense (Box Store) i64))

(defmacro (first-slot-via-template [chunks : Expr]) : Expr
  `(match ,chunks
    [(Chunks.Nil) "nil"]
    [(Chunks.Dense store _)
      (let
        [s : (& store Store) (& (box-get store))]
        (array-ref s.slots 0))]))

(define (first-via-ref [chunks : (& chunks Chunks)]) : String
  (first-slot-via-template chunks))

(define (main) : i64
  (let
    [slots : (__tl_dyn-array String) (__tl_make-array String 2)]
    [_s : unit (set! (array-ref slots 0) "hello")]
    [c : Chunks (Chunks.Dense (box (Store slots 1)) 1)]
    (begin
      (io.println "via-ref=[{}]" (first-via-ref (& c)))
      0)))