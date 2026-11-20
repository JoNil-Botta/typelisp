;; #9770: a capturing closure's environment is allocated in the active arena,
;; so the closure carries its region and cannot leave the arena.
(import stdlib.io)

(define (mk [x : i64]) : (-> i64)
  (with-arena
    r
    (lambda () : i64
      x)))

(define (main) : i64
  (let
    [g (mk 77)]
    (let
      [v : i64 (g)]
      (begin
        (io.println "C2 v={}" v)
        (if (= v 77)
          42
          (bit-and v 255))))))