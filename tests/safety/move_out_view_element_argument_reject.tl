;; A move-only element read through a shared reference passed where its owned
;; type is expected is a move out of the reference (Rust E0507, E0208 as on
;; main), in a call argument as in a constructor field.
(defstruct Seq
  (slots (__tl_dyn-array String))
  (len i64))

(defstruct Wrap
  (s String))

(define (take [s : String]) : i64
  0)

; Must fail: the element belongs to `seq`'s referent.
(define (pass-element [seq : (& seq Seq)] [index : i64]) : i64
  (take (array-ref seq.slots index)))

(define (wrap-element [seq : (& seq Seq)] [index : i64]) : Wrap
  (Wrap (array-ref seq.slots index)))

(define (main) : i64
  42)