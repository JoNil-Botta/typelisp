;; A borrow of a local stored into caller storage and overwritten before the
;; return: the stored reference has the caller's lifetime `a`, which is live
;; at every point of the body, so the loan must outlive the local wherever it
;; is stored (#8890; spelled as in `storage_dead_param_store_direct_reject`).
;; Rust: E0597 "assignment requires that `a` is borrowed for `'a`", the
;; overwrite notwithstanding.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [p : (& a i64)] [b : (&mut a (RefBox a))]) : unit
  (let
    [a : i64 1]
    ; Must fail: the borrow is stored for the caller's `a`.
    (set! b.value (& a))
    (set! b.value p)))

(define (main) : i64
  0)