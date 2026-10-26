;; A borrow of a local stored through a `&mut` parameter outlives the local:
;; the referent lifetime is the caller's, live at every return (#8890). The
;; `&mut` and its referent share the spelling `a` with the local, so typing
;; accepts the store and the ownership graph decides: the local's storage ends
;; while the stored loan is live. Rust: E0597 "`a` does not live long enough".
(define (store [out : (&mut a (& a i64))]) : unit
  (let
    [a : i64 1]
    ; Must fail: `a` dies when `store` returns.
    (set! (deref out) (& a))))

(define (main) : i64
  0)