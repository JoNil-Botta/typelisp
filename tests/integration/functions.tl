(define (double [x : i64]) : i64
  (+ x x))

(define (add3 [a : i64] [b : i64] [c : i64]) : i64
  (+ (+ a b) c))

;; Address-taken sink: keeps add3 an emitted out-of-line body at every opt
;; level now that the inliner absorbs one-block callees at call and tail-call
;; sites - the backend target-parity checker reads this function's body.
(define keep-add3 : (-> i64 i64 i64 i64)
  add3)

(define (main) : i64
  (add3 (double 10) 5 7))