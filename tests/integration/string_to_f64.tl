;; Exercises the `string->f64` builtin (#721): the self-hosted lexer's

;; floating-point numeric-literal primitive. Parses several decimal strings -

;; integer-only, fractional, signed, and scientific-notation (e/E, signed

;; exponent) forms - and checks each against the equivalent f64 literal. main

;; returns 42 iff every parse matches exactly, otherwise the 1-based index of

;; the first parse that did not match.

(define (main) : i64
  (if (= (string->f64 "0.0") 0.0)
    (if (= (string->f64 "1.5") 1.5)
      (if (= (string->f64 "100") 100.0)
        (if (= (string->f64 "-2.25") -2.25)
          (if (= (string->f64 "3.0e2") 300.0)
            (if (= (string->f64 "25e-1") 2.5)
              42
              6)
            5)
          4)
        3)
      2)
    1))