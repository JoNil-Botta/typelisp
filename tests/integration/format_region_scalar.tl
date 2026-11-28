(import stdlib.format)
(import stdlib.io)

(defstruct DisplayValue
  (n i64))

(define (format-write
  [value : (& DisplayValue)]
  [formatter : (&mut format.Formatter)]) : unit
  (format.formatter-write-string! formatter (format.format "{}" value.n)))

(define (read-tagged [p : (& p i64)]) : (in p i64)
  (deref p))

(define (read-display [p : (& p DisplayValue)]) : (in p DisplayValue)
  (deref p))

(define (identity [value : i64]) : i64
  value)

(define (show [p : (& p i64)]) : unit
  (let
    [value (read-tagged p)]
    [plain : i64 7]
    (io.print-format "{}\n" (read-tagged p))
    (io.print-format
      "{} {} {} {} {} {} {}\n"
      (read-tagged p)
      (let
        [bound (read-tagged p)]
        bound)
      value
      (+ (read-tagged p) 1)
      (cast (read-tagged p) : i64)
      plain
      (identity plain))
    (io.print-format "{}\n" (format.format "{:#x}" (read-tagged p)))
    (io.print-format "literal\n")))

(define (show-display [p : (& p DisplayValue)]) : unit
  (io.print-format "{}\n" (read-display p)))

(define (main) : i64
  (let
    [value : i64 42]
    [display (DisplayValue 99)]
    (show (& value))
    (show-display (& display))
    0))