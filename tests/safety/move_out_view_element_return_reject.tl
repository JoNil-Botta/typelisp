;; A move-only element read through a shared reference and returned by value
;; is a move out of the reference (Rust E0507): the element is a place the
;; ownership graph takes, and the take of borrowed content is rejected (E0208),
;; as on main. A view the graph cannot take, such as a call's `(in p T)`
;; result, is the region escape E0205 instead.
(defstruct Seq
  (slots (__tl_dyn-array String))
  (len i64))

; Must fail: the element belongs to `seq`'s referent.
(define (seq-ref [seq : (& seq Seq)] [index : i64]) : String
  (array-ref seq.slots index))

(define (main) : i64
  42)