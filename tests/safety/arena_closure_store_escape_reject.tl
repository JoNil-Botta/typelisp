;; #9770: a closure made in an arena cannot be stored into an outer local.
(import stdlib.io)

(define (f [x : i64] [o : (-> i64)]) : i64
  (let
    [k : (-> i64) o]
    (begin
      (with-arena
        r
        (set!
          k
          (lambda () : i64
            x)))
      (k))))

(define (main) : i64
  (let
    [v : i64
      (f
        77
        (lambda () : i64
          0))]
    (begin
      (io.println "T22 v={}" v)
      (if (= v 77)
        42
        (bit-and v 255)))))