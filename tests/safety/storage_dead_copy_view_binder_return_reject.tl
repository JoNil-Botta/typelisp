;; A copyable value read through a reference is a copy in the binder's own
;; storage (the canonical type drops its region tag), so a borrow of it is a
;; borrow of a local and cannot be returned (#8889 review). Rust: E0515
;; "cannot return reference to local variable `v`".
(defstruct In
  (k i64)
  (n i64)
  (m i64))

(defstruct Out
  (s In)
  (t i64))

(define (leak [p : (& p Out)]) : (& p In)
  (let
    [v p.s]
    ; Must fail: `v` is a copy that dies when `leak` returns.
    (& v)))

(define (main) : i64
  0)