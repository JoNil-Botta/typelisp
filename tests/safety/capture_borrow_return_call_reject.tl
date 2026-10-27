;; The returned borrow of a capture is read after another call reuses the
;; lambda's frame (#9297).
(define (scrub [n : i64]) : i64
  (let
    [a : (Array i64 16) (array 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)]
    (set! (array-ref a (% n 16)) n)
    (array-ref a (% n 16))))

(define (main) : i64
  (let
    [n : i64 42]
    ; Must fail: `(& n)` borrows the lambda's copy of `n`.
    [g
      (lambda () : (& n i64)
        (& n))]
    [r : (& n i64) (g)]
    [z : i64 (scrub 7)]
    (+ (- z 7) (deref r))))