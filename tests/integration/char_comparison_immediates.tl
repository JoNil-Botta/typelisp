;; Dynamic byte against constant byte, in both operand positions.
(define failures : i64
  0)

(define (assert-bool-eq [actual : bool] [expected : bool]) : unit
  (when (!= actual expected) (set! failures (+ failures 1))))

(define (check-byte [value : i64]) : unit
  (let
    [byte : char (cast value : char)]
    (assert-bool-eq (= byte (cast 0 : char)) (= value 0))
    (assert-bool-eq (= (cast 0 : char) byte) (= 0 value))
    (assert-bool-eq (!= byte (cast 0 : char)) (!= value 0))
    (assert-bool-eq (!= (cast 0 : char) byte) (!= 0 value))
    (assert-bool-eq (< byte (cast 0 : char)) (< value 0))
    (assert-bool-eq (< (cast 0 : char) byte) (< 0 value))
    (assert-bool-eq (<= byte (cast 0 : char)) (<= value 0))
    (assert-bool-eq (<= (cast 0 : char) byte) (<= 0 value))
    (assert-bool-eq (> byte (cast 0 : char)) (> value 0))
    (assert-bool-eq (> (cast 0 : char) byte) (> 0 value))
    (assert-bool-eq (>= byte (cast 0 : char)) (>= value 0))
    (assert-bool-eq (>= (cast 0 : char) byte) (>= 0 value))
    (assert-bool-eq (= byte (cast 127 : char)) (= value 127))
    (assert-bool-eq (= (cast 127 : char) byte) (= 127 value))
    (assert-bool-eq (!= byte (cast 127 : char)) (!= value 127))
    (assert-bool-eq (!= (cast 127 : char) byte) (!= 127 value))
    (assert-bool-eq (< byte (cast 127 : char)) (< value 127))
    (assert-bool-eq (< (cast 127 : char) byte) (< 127 value))
    (assert-bool-eq (<= byte (cast 127 : char)) (<= value 127))
    (assert-bool-eq (<= (cast 127 : char) byte) (<= 127 value))
    (assert-bool-eq (> byte (cast 127 : char)) (> value 127))
    (assert-bool-eq (> (cast 127 : char) byte) (> 127 value))
    (assert-bool-eq (>= byte (cast 127 : char)) (>= value 127))
    (assert-bool-eq (>= (cast 127 : char) byte) (>= 127 value))
    (assert-bool-eq (= byte (cast 128 : char)) (= value 128))
    (assert-bool-eq (= (cast 128 : char) byte) (= 128 value))
    (assert-bool-eq (!= byte (cast 128 : char)) (!= value 128))
    (assert-bool-eq (!= (cast 128 : char) byte) (!= 128 value))
    (assert-bool-eq (< byte (cast 128 : char)) (< value 128))
    (assert-bool-eq (< (cast 128 : char) byte) (< 128 value))
    (assert-bool-eq (<= byte (cast 128 : char)) (<= value 128))
    (assert-bool-eq (<= (cast 128 : char) byte) (<= 128 value))
    (assert-bool-eq (> byte (cast 128 : char)) (> value 128))
    (assert-bool-eq (> (cast 128 : char) byte) (> 128 value))
    (assert-bool-eq (>= byte (cast 128 : char)) (>= value 128))
    (assert-bool-eq (>= (cast 128 : char) byte) (>= 128 value))
    (assert-bool-eq (= byte (cast 255 : char)) (= value 255))
    (assert-bool-eq (= (cast 255 : char) byte) (= 255 value))
    (assert-bool-eq (!= byte (cast 255 : char)) (!= value 255))
    (assert-bool-eq (!= (cast 255 : char) byte) (!= 255 value))
    (assert-bool-eq (< byte (cast 255 : char)) (< value 255))
    (assert-bool-eq (< (cast 255 : char) byte) (< 255 value))
    (assert-bool-eq (<= byte (cast 255 : char)) (<= value 255))
    (assert-bool-eq (<= (cast 255 : char) byte) (<= 255 value))
    (assert-bool-eq (> byte (cast 255 : char)) (> value 255))
    (assert-bool-eq (> (cast 255 : char) byte) (> 255 value))
    (assert-bool-eq (>= byte (cast 255 : char)) (>= value 255))
    (assert-bool-eq (>= (cast 255 : char) byte) (>= 255 value))))

(define (main) : i64
  (let
    [value : i64 0]
    (while (< value 256)
      (check-byte value)
      (set! value (+ value 1)))
    (if (= failures 0)
      42
      1)))