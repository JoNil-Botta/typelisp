;; A borrow of a local returned inside a tuple outlives the local (typing
;; rejects it first, as `storage_dead_return_direct_reject`). Rust: E0515
;; "cannot return value referencing local variable `a`".
(define (leak [p : (& a i64)]) : (Tuple (& a i64) i64)
  (let
    [a : i64 1]
    ; Must fail: `a` dies when `leak` returns.
    (return (tuple (& a) 2))))

(define (main) : i64
  0)