;; A borrow of an inner-scope local stored in an outer local that is read after
;; the scope ends. Typing rejects the store first: the outer local's type
;; names the outer `x`, which outlives the inner one. Rust: E0597 "`x` does
;; not live long enough ... borrow later used here".
(define (outer) : i64
  (let
    [x : i64 1]
    [r (& x)]
    (let
      [x : i64 2]
      (set! r (& x)))
    ; Must fail: the inner `x` is dead here.
    (deref r)))

(define (main) : i64
  0)