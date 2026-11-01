;; A borrow of a local pushed into a vector reached through a `&mut` parameter
;; outlives the local (#8890; spelled as in
;; `storage_dead_param_store_direct_reject`). Rust: E0597.
(define (store [items : (&mut a (__tl_dyn-array (& a i64)))]) : unit
  (let
    [a : i64 1]
    ; Must fail: `a` dies when `store` returns.
    (__tl_array-push! (deref items) (& a))))

(define (main) : i64
  0)