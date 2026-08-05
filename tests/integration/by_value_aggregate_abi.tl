;; End-to-end native ABI matrix for internal fixed arrays and tuples.
;; Every structural call below is intentionally ordinary source-level code:
;; no extern declarations or pointer shims are involved.
(import stdlib.string)

(define (abi-check [ok : bool]) : i64
  (if ok
    1
    0))

;; Register-boundary fixed arrays (and the Win64 16-byte byref boundary).
(define (abi-array-u8-1 [value : (Array u8 1)]) : (Array u8 1)
  value)

(define (abi-array-u8-2 [value : (Array u8 2)]) : (Array u8 2)
  value)

(define (abi-array-u8-3 [value : (Array u8 3)]) : (Array u8 3)
  value)

(define (abi-array-u8-4 [value : (Array u8 4)]) : (Array u8 4)
  value)

(define (abi-array-u8-8 [value : (Array u8 8)]) : (Array u8 8)
  value)

(define (abi-array-u8-16 [value : (Array u8 16)]) : (Array u8 16)
  value)

;; A 24-byte memory-class array is copied into private callee storage before
;; mutation, so the caller's original remains unchanged.
(define (abi-memory-array-roundtrip [value : (Array i64 3)]) : (Array i64 3)
  (begin
    (array-set! value 1 99)
    value))

;; SysV mixed INTEGER/SSE register groups and recursive nested layout.
(define (abi-mixed-tuple-roundtrip [value : (Tuple i64 f64)]) : (Tuple i64 f64)
  value)

(define (abi-nested-tuple-roundtrip
  [value : (Tuple (Tuple u8 i32) (Array u16 2))]) : (Tuple
    (Tuple u8 i32)
    (Array u16 2))
  (begin
    (array-set! (tuple-ref value 1) 1 77)
    value))

;; Five scalar arguments plus a structural argument force register/stack
;; pressure on both target ABIs while the result remains structural.
(define (abi-pressure
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [value : (Tuple i64 i64)]) : (Tuple i64 i64)
  (tuple (+ a (+ b (+ c (+ d e)))) (+ (tuple-ref value 0) (tuple-ref value 1))))

;; Structural early returns cover both a register-class tuple and a
;; memory/sret fixed array.
(define (abi-early-tuple [flag : bool]) : (Tuple i64 i64)
  (if flag
    (return (tuple 40 2))
    (tuple 1 1)))

(define (abi-early-array [flag : bool]) : (Array i64 3)
  (if flag
    (return (array 40 1 1))
    (array 2 2 2)))

;; Noncapturing function value and indirect structural call.
(define (abi-indirect-roundtrip [value : (Tuple i64 i64)]) : (Tuple i64 i64)
  value)

;; Capturing closure called through a function value; its scalar capture and
;; structural argument both contribute to the returned tuple.
(define (abi-capturing-roundtrip) : (Tuple i64 i64)
  (let
    [base : i64 30]
    [fn : (-> (Tuple i64 i64) (Tuple i64 i64))
      (lambda ([value : (Tuple i64 i64)]) : (Tuple i64 i64)
        (tuple (+ base (tuple-ref value 0)) (+ base (tuple-ref value 1))))]
    (fn (tuple 5 7))))

;; Every ISA variant has the same result so dispatch remains deterministic on
;; hosts with or without AVX2/AVX-512 support.
(define (abi-dispatch-scalar [value : (Tuple i64 i64)]) : (Tuple i64 i64)
  (tuple (+ (tuple-ref value 0) 10) (+ (tuple-ref value 1) 20)))

(define (abi-dispatch-avx2 [value : (Tuple i64 i64)]) : (Tuple i64 i64)
  (tuple (+ (tuple-ref value 0) 10) (+ (tuple-ref value 1) 20)))

(define (abi-dispatch-avx512 [value : (Tuple i64 i64)]) : (Tuple i64 i64)
  (tuple (+ (tuple-ref value 0) 10) (+ (tuple-ref value 1) 20)))

(defdispatch
  abi-dispatch
  (scalar abi-dispatch-scalar)
  (avx2 abi-dispatch-avx2)
  (avx512 abi-dispatch-avx512))

;; Tail-position recursion returning a structural value.
(define (abi-tail-structural [n : i64] [value : (Tuple i64 i64)]) : (Tuple
    i64
    i64)
  (if (= n 0)
    value
    (abi-tail-structural (- n 1) value)))

;; A 24-byte memory-class tuple containing a non-Copy String handle. Returning
;; this value is a raw representation move; no source-level clone is involved.
(define (abi-shallow-handle-roundtrip [value : (Tuple String i64 i64)]) : (Tuple
    String
    i64
    i64)
  value)

(define (main) : i64
  (let
    [a1-value : u8 (array-ref (abi-array-u8-1 (array 11)) 0)]
    [a2 : (Array u8 2) (abi-array-u8-2 (array 12 22))]
    [a3 : (Array u8 3) (abi-array-u8-3 (array 1 2 3))]
    [a4 : (Array u8 4) (abi-array-u8-4 (array 14 24 34 44))]
    [a8 : (Array u8 8) (abi-array-u8-8 (array 18 28 38 48 58 68 78 88))]
    [a16 : (Array u8 16)
      (abi-array-u8-16
        (array 16 26 36 46 56 66 76 86 96 106 116 126 136 146 156 166))]
    [memory-original : (Array i64 3) (array 1 2 3)]
    [memory-returned : (Array i64 3)
      (abi-memory-array-roundtrip memory-original)]
    [mixed : (Tuple i64 f64) (abi-mixed-tuple-roundtrip (tuple 40 2.5))]
    [nested-original : (Tuple (Tuple u8 i32) (Array u16 2))
      (tuple (tuple 7 32) (array 6 8))]
    [nested-returned : (Tuple (Tuple u8 i32) (Array u16 2))
      (abi-nested-tuple-roundtrip nested-original)]
    [pressure : (Tuple i64 i64) (abi-pressure 1 2 3 4 5 (tuple 10 20))]
    [early-tuple : (Tuple i64 i64) (abi-early-tuple true)]
    [early-tuple-false : (Tuple i64 i64) (abi-early-tuple false)]
    [early-array : (Array i64 3) (abi-early-array true)]
    [early-array-false : (Array i64 3) (abi-early-array false)]
    [indirect : (Tuple i64 i64)
      (let
        [fn : (-> (Tuple i64 i64) (Tuple i64 i64)) abi-indirect-roundtrip]
        (fn (tuple 9 33)))]
    [captured : (Tuple i64 i64) (abi-capturing-roundtrip)]
    [dispatched : (Tuple i64 i64) (abi-dispatch (tuple 20 22))]
    [tail : (Tuple i64 i64) (abi-tail-structural 3 (tuple 40 2))]
    [shallow : (Tuple String i64 i64)
      (abi-shallow-handle-roundtrip (tuple "shallow" 17 25))]
    [score : i64 0]
    (begin
      (set! score (+ score (abi-check (= (cast a1-value : i64) 11))))
      (set! score (+ score (abi-check (= (cast (array-ref a2 0) : i64) 12))))
      (set! score (+ score (abi-check (= (cast (array-ref a2 1) : i64) 22))))
      (set! score (+ score (abi-check (= (cast (array-ref a3 0) : i64) 1))))
      (set! score (+ score (abi-check (= (cast (array-ref a3 1) : i64) 2))))
      (set! score (+ score (abi-check (= (cast (array-ref a3 2) : i64) 3))))
      (set! score (+ score (abi-check (= (cast (array-ref a4 0) : i64) 14))))
      (set! score (+ score (abi-check (= (cast (array-ref a4 2) : i64) 34))))
      (set! score (+ score (abi-check (= (cast (array-ref a4 3) : i64) 44))))
      (set! score (+ score (abi-check (= (cast (array-ref a8 0) : i64) 18))))
      (set! score (+ score (abi-check (= (cast (array-ref a8 7) : i64) 88))))
      (set! score (+ score (abi-check (= (cast (array-ref a16 15) : i64) 166))))
      (set! score (+ score (abi-check (= (cast (array-ref a16 0) : i64) 16))))
      (set! score (+ score (abi-check (= (array-ref memory-returned 1) 99))))
      (set! score (+ score (abi-check (= (array-ref memory-original 1) 2))))
      (set! score (+ score (abi-check (= (tuple-ref mixed 0) 40))))
      (set! score (+ score (abi-check (= (tuple-ref mixed 1) 2.5))))
      (set!
        score
        (+
          score
          (abi-check
            (= (cast (array-ref (tuple-ref nested-returned 1) 1) : i64) 77))))
      (set!
        score
        (+
          score
          (abi-check
            (= (cast (array-ref (tuple-ref nested-original 1) 1) : i64) 8))))
      (set! score (+ score (abi-check (= (tuple-ref pressure 0) 15))))
      (set! score (+ score (abi-check (= (tuple-ref pressure 1) 30))))
      (set! score (+ score (abi-check (= (tuple-ref early-tuple 0) 40))))
      (set! score (+ score (abi-check (= (tuple-ref early-tuple 1) 2))))
      (set! score (+ score (abi-check (= (array-ref early-array 0) 40))))
      (set! score (+ score (abi-check (= (array-ref early-array 2) 1))))
      (set! score (+ score (abi-check (= (tuple-ref early-tuple-false 0) 1))))
      (set! score (+ score (abi-check (= (tuple-ref early-tuple-false 1) 1))))
      (set! score (+ score (abi-check (= (array-ref early-array-false 0) 2))))
      (set! score (+ score (abi-check (= (array-ref early-array-false 2) 2))))
      (set! score (+ score (abi-check (= (tuple-ref indirect 1) 33))))
      (set! score (+ score (abi-check (= (tuple-ref captured 0) 35))))
      (set! score (+ score (abi-check (= (tuple-ref captured 1) 37))))
      (set! score (+ score (abi-check (= (tuple-ref dispatched 0) 30))))
      (set! score (+ score (abi-check (= (tuple-ref dispatched 1) 42))))
      (set! score (+ score (abi-check (= (tuple-ref tail 0) 40))))
      (set! score (+ score (abi-check (= (tuple-ref tail 1) 2))))
      (set!
        score
        (+ score (abi-check (string.eq (tuple-ref shallow 0) "shallow"))))
      (set!
        score
        (+ score (abi-check (= (string.string-length (tuple-ref shallow 0)) 7))))
      (set! score (+ score (abi-check (= (tuple-ref shallow 1) 17))))
      (set! score (+ score (abi-check (= (tuple-ref shallow 2) 25))))
      (if (= score 40)
        42
        1))))