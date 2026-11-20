;; #9770: as arena_closure_escape_reject, capturing an arena-local binding.
(import stdlib.io)

(define (f) : (-> i64)
  (with-arena
    r
    (let
      [x : i64 1]
      (lambda () : i64
        x))))

(define (main) : i64
  (let
    [g (f)]
    [v : i64 (g)]
    (begin
      (io.println "T21 v={}" v)
      (if (= v 1)
        42
        (bit-and v 255)))))