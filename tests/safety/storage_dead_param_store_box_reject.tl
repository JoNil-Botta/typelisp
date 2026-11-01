;; A borrow of a local boxed and stored through a `&mut` parameter outlives
;; the local (#8890; spelled as in `storage_dead_param_store_direct_reject`).
;; Rust: E0597.
(define (store [b : (&mut a (Box (& a i64)))]) : unit
  (let
    [a : i64 1]
    ; Must fail: `a` dies when `store` returns.
    (set! (deref b) (box (& a)))))

(define (main) : i64
  0)