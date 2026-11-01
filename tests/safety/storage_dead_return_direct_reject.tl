;; A returned borrow of a local outlives the local. Typing rejects it first:
;; the `let` result names a lifetime that ends with the `let`. Rust: E0515
;; "cannot return reference to local variable `a`".
(define (leak [p : (& a i64)]) : (& a i64)
  (let
    [a : i64 1]
    ; Must fail: `a` dies when `leak` returns.
    (return (& a))))

(define (main) : i64
  0)