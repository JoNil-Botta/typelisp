;; A pointer type carrying a local spelled like a caller lifetime reports the
;; store escape.
(defstruct PtrBox
  (:lifetimes a)
  (ptr (Ptr (& a i64))))

(define (store [b : (&mut a (PtrBox a))]) : unit
  (let
    [a : i64 1]
    [q : (Ptr (& a i64)) (ptr-null : (Ptr (& a i64)))]
    ; Must fail: `q`'s type names the local `a`.
    (set! b.ptr q)))

(define (main) : i64
  0)