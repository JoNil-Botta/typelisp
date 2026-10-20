;; A borrow of a local returned inside a struct outlives the local (typing
;; rejects it first, as `storage_dead_return_direct_reject`). Rust: E0515
;; "cannot return value referencing local variable `a`".
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (leak [p : (& a i64)]) : (RefBox a)
  (let
    [a : i64 1]
    ; Must fail: `a` dies when `leak` returns.
    (return (RefBox (& a)))))

(define (main) : i64
  0)