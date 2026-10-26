;; A borrow of a local stored into a field of a struct reached through a `&mut`
;; parameter outlives the local (#8890; spelled as in
;; `storage_dead_param_store_direct_reject`). Rust: E0597.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut a (RefBox a))]) : unit
  (let
    [a : i64 1]
    ; Must fail: `a` dies when `store` returns.
    (set! b.value (& a))))

(define (main) : i64
  0)