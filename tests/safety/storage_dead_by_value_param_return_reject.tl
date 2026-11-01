;; A returned borrow of a by-value parameter outlives the parameter: its
;; storage belongs to the call, and the result lives in the caller (#8890).
;; Rust: E0515 "cannot return reference to function parameter `a`".
(define (leak [a : i64] [p : (& a i64)]) : (& a i64)
  ; Must fail: `a` dies when `leak` returns.
  (& a))

(define (main) : i64
  0)