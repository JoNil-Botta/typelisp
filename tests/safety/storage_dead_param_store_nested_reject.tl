;; A borrow of a local stored through two `&mut` references outlives the
;; local (#8890; spelled as in `storage_dead_param_store_direct_reject`).
;; Rust: E0597.
(define (store [pp : (&mut a (&mut a (& a i64)))]) : unit
  (let
    [a : i64 1]
    ; Must fail: `a` dies when `store` returns.
    (set! (deref (deref pp)) (& a))))

(define (main) : i64
  0)