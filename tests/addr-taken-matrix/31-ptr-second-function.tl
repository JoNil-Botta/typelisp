;; the pointer is passed through a second function before the store.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (inner [p : (MutPtr i64)])
  (unsafe
    (ptr-write! p 5)))

(define (outer [p : (MutPtr i64)])
  (inner p))

(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    (outer p)
    (+ 1 v)))