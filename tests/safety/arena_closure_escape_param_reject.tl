;; #9770: as arena_closure_escape_reject.
(import stdlib.io)

(define (f [x : i64]) : (-> i64)
  (with-arena
    r
    (lambda () : i64
      x)))

(define (main) : i64
  (let
    [g (f 77)]
    [v : i64 (g)]
    (begin
      (io.println "T20 v={}" v)
      (if (= v 77)
        42
        (bit-and v 255)))))