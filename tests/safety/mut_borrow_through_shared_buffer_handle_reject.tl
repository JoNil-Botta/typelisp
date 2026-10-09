;: A private buffer handle is move-only storage of its owner, so a `&mut` borrow
;: of the handle through a shared reference is rejected: the callee could
;: replace the buffer the shared owner holds (#8743).
(defstruct Owner
  (items (__tl_dyn-array i64)))

(define (install! [slot : (&mut (__tl_dyn-array i64))]) : unit
  (set! (deref slot) (__tl_make-array i64 4)))

(define (f [owner : (& Owner)]) : i64
  (install! (&mut owner.items))
  (array-length owner.items))

(define (main) : i64
  (let
    [owner (Owner (__tl_make-array i64 1))]
    (f (& owner))))