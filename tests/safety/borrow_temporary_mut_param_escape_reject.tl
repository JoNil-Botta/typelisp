;: A mutable parameter whose referent shares the temporary's lifetime could
;: keep the borrow after the call.
(defstruct Holder
  (:lifetimes a)
  (value (& a i64)))

(define (link! [_holder : (&mut (Holder a))] [_value : (& a i64)]) : unit
  unit)

(define (main) : i64
  (let
    [x : i64 1]
    [holder (Holder (& x))]
    (begin
      (link! (&mut holder) (& 5))
      (deref holder.value))))