(define (sum8
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ a b) c) d) e) f) g) h))

;; Address-taken sink: keeps sum8 an emitted out-of-line body at every opt
;; level (see functions.tl) - the target-parity checker reads its stack-arg
;; marshalling.
(define keep-sum8 : (-> i64 i64 i64 i64 i64 i64 i64 i64 i64) sum8)

(define (main) : i64
  (sum8 1 2 3 4 5 6 7 8))