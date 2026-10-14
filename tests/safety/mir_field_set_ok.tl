;: Field stores: a moved field is reinitialized by a store, and a store through
;: a mutable reference writes the referent.
(defstruct Holder
  (items (__tl_dyn-array i64))
  (count i64))

(define (bump [holder : (&mut holder Holder)]) : unit
  (set! holder.count (+ holder.count 1)))

(define (main) : i64
  (let
    [holder : Holder (Holder (__tl_make-array i64 2) 38)]
    [taken : (__tl_dyn-array i64) holder.items]
    (begin
      (set! holder.items (__tl_make-array i64 1))
      (bump (&mut holder))
      (bump (&mut holder))
      (+ holder.count (array-length taken) (array-length holder.items) -1))))