;; Dynamic byte against constant byte, in both operand positions.
(import stdlib.test)

(define (check-byte [value : i64]) : unit
  (let
    [byte : char (cast value : char)]
    (test.assert-bool-eq
      (= byte (cast 0 : char))
      (= value 0)
      "char immediate right")
    (test.assert-bool-eq
      (= (cast 0 : char) byte)
      (= 0 value)
      "char immediate left")
    (test.assert-bool-eq
      (!= byte (cast 0 : char))
      (!= value 0)
      "char immediate right")
    (test.assert-bool-eq
      (!= (cast 0 : char) byte)
      (!= 0 value)
      "char immediate left")
    (test.assert-bool-eq
      (< byte (cast 0 : char))
      (< value 0)
      "char immediate right")
    (test.assert-bool-eq
      (< (cast 0 : char) byte)
      (< 0 value)
      "char immediate left")
    (test.assert-bool-eq
      (<= byte (cast 0 : char))
      (<= value 0)
      "char immediate right")
    (test.assert-bool-eq
      (<= (cast 0 : char) byte)
      (<= 0 value)
      "char immediate left")
    (test.assert-bool-eq
      (> byte (cast 0 : char))
      (> value 0)
      "char immediate right")
    (test.assert-bool-eq
      (> (cast 0 : char) byte)
      (> 0 value)
      "char immediate left")
    (test.assert-bool-eq
      (>= byte (cast 0 : char))
      (>= value 0)
      "char immediate right")
    (test.assert-bool-eq
      (>= (cast 0 : char) byte)
      (>= 0 value)
      "char immediate left")
    (test.assert-bool-eq
      (= byte (cast 127 : char))
      (= value 127)
      "char immediate right")
    (test.assert-bool-eq
      (= (cast 127 : char) byte)
      (= 127 value)
      "char immediate left")
    (test.assert-bool-eq
      (!= byte (cast 127 : char))
      (!= value 127)
      "char immediate right")
    (test.assert-bool-eq
      (!= (cast 127 : char) byte)
      (!= 127 value)
      "char immediate left")
    (test.assert-bool-eq
      (< byte (cast 127 : char))
      (< value 127)
      "char immediate right")
    (test.assert-bool-eq
      (< (cast 127 : char) byte)
      (< 127 value)
      "char immediate left")
    (test.assert-bool-eq
      (<= byte (cast 127 : char))
      (<= value 127)
      "char immediate right")
    (test.assert-bool-eq
      (<= (cast 127 : char) byte)
      (<= 127 value)
      "char immediate left")
    (test.assert-bool-eq
      (> byte (cast 127 : char))
      (> value 127)
      "char immediate right")
    (test.assert-bool-eq
      (> (cast 127 : char) byte)
      (> 127 value)
      "char immediate left")
    (test.assert-bool-eq
      (>= byte (cast 127 : char))
      (>= value 127)
      "char immediate right")
    (test.assert-bool-eq
      (>= (cast 127 : char) byte)
      (>= 127 value)
      "char immediate left")
    (test.assert-bool-eq
      (= byte (cast 128 : char))
      (= value 128)
      "char immediate right")
    (test.assert-bool-eq
      (= (cast 128 : char) byte)
      (= 128 value)
      "char immediate left")
    (test.assert-bool-eq
      (!= byte (cast 128 : char))
      (!= value 128)
      "char immediate right")
    (test.assert-bool-eq
      (!= (cast 128 : char) byte)
      (!= 128 value)
      "char immediate left")
    (test.assert-bool-eq
      (< byte (cast 128 : char))
      (< value 128)
      "char immediate right")
    (test.assert-bool-eq
      (< (cast 128 : char) byte)
      (< 128 value)
      "char immediate left")
    (test.assert-bool-eq
      (<= byte (cast 128 : char))
      (<= value 128)
      "char immediate right")
    (test.assert-bool-eq
      (<= (cast 128 : char) byte)
      (<= 128 value)
      "char immediate left")
    (test.assert-bool-eq
      (> byte (cast 128 : char))
      (> value 128)
      "char immediate right")
    (test.assert-bool-eq
      (> (cast 128 : char) byte)
      (> 128 value)
      "char immediate left")
    (test.assert-bool-eq
      (>= byte (cast 128 : char))
      (>= value 128)
      "char immediate right")
    (test.assert-bool-eq
      (>= (cast 128 : char) byte)
      (>= 128 value)
      "char immediate left")
    (test.assert-bool-eq
      (= byte (cast 255 : char))
      (= value 255)
      "char immediate right")
    (test.assert-bool-eq
      (= (cast 255 : char) byte)
      (= 255 value)
      "char immediate left")
    (test.assert-bool-eq
      (!= byte (cast 255 : char))
      (!= value 255)
      "char immediate right")
    (test.assert-bool-eq
      (!= (cast 255 : char) byte)
      (!= 255 value)
      "char immediate left")
    (test.assert-bool-eq
      (< byte (cast 255 : char))
      (< value 255)
      "char immediate right")
    (test.assert-bool-eq
      (< (cast 255 : char) byte)
      (< 255 value)
      "char immediate left")
    (test.assert-bool-eq
      (<= byte (cast 255 : char))
      (<= value 255)
      "char immediate right")
    (test.assert-bool-eq
      (<= (cast 255 : char) byte)
      (<= 255 value)
      "char immediate left")
    (test.assert-bool-eq
      (> byte (cast 255 : char))
      (> value 255)
      "char immediate right")
    (test.assert-bool-eq
      (> (cast 255 : char) byte)
      (> 255 value)
      "char immediate left")
    (test.assert-bool-eq
      (>= byte (cast 255 : char))
      (>= value 255)
      "char immediate right")
    (test.assert-bool-eq
      (>= (cast 255 : char) byte)
      (>= 255 value)
      "char immediate left")))

(define (main) : i64
  (let
    [value : i64 0]
    (while (< value 256)
      (check-byte value)
      (set! value (+ value 1)))
    42))