;; A copyable aggregate that holds a reference, read through a reference, is
;; a copy in the binder's own storage like any copyable value, so a borrow of
;; it cannot be returned (#8889 review). Rust: E0515 "cannot return reference
;; to local variable `v`".
(defstruct Holder
  (:lifetimes q)
  (r (& q i64))
  (a i64)
  (b i64))

(defstruct Out
  (:lifetimes q)
  (h (Holder q))
  (t i64))

(define (leak [p : (& p (Out q))]) : (& p (Holder q))
  (let
    [v p.h]
    ; Must fail: `v` is a copy that dies when `leak` returns.
    (& v)))

(define (main) : i64
  0)