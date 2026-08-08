;; Generated vector bang mutators evaluate an indexed nested place once, then
;; evaluate non-place operands once in ordinary left-to-right call order.
(import stdlib.vector)
(import (vector.vector i64) as ivec)

(defstruct World
  (balls ivec.Vec)
  (marker i64))

(define evaluation-order : i64
  0)

(define (next-index) : i64
  (begin
    (set! evaluation-order (+ (* evaluation-order 10) 1))
    0))

(define (next-value) : i64
  (begin
    (set! evaluation-order (+ (* evaluation-order 10) 2))
    42))

(define (main) : i64
  (let
    [worlds : (Array World 1) (array (World (ivec.new) 9))]
    (begin
      (ivec.push!
        (struct-get (array-ref worlds (next-index)) balls)
        (next-value))
      (if (and
        (= evaluation-order 12)
        (= (ivec.len (& (struct-get (array-ref worlds 0) balls))) 1)
        (= (ivec.get (& (struct-get (array-ref worlds 0) balls)) 0 0) 42)
        (= (struct-get (array-ref worlds 0) marker) 9))
        42
        1))))