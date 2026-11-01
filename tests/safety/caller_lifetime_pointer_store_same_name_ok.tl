;; A raw pointer whose pointee type is spelled with a local's lifetime holds no
;; loan of that local (a raw pointer carries none), so storing it into caller
;; storage keeps nothing of the local borrowed (#8890). Rust accepts the
;; equivalent: no borrow of `a` is taken.
(defstruct PtrBox
  (:lifetimes a)
  (ptr (Ptr (& a i64))))

(define (store [b : (&mut a (PtrBox a))]) : unit
  (let
    [a : i64 1]
    [q : (Ptr (& a i64)) (ptr-null : (Ptr (& a i64)))]
    (set! b.ptr q)))

(define (main) : i64
  0)