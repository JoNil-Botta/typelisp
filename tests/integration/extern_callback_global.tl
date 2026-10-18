(import stdlib.io)

(extern (invoke [callback : (-> i64)]) : i64 (:symbol "tl_test_callback_invoke"))
(extern (save [callback : (-> i64)]) : i64 (:symbol "tl_test_callback_save"))
(extern (invoke-exported) : i64 (:symbol "tl_test_callback_invoke_exported"))
(extern (invoke-saved) : i64 (:symbol "tl_test_callback_invoke_saved"))

;; Spelled like the runtime's region-mark reader, but linked to C code that
;; re-enters TypeLisp: the link, not the spelling, decides its effects.
(extern (tl_region_mark) : i64 (:symbol "tl_test_callback_invoke_exported"))

(defstruct Payload
  (value i64)
  (padding-a i64)
  (padding-b i64))

(define counter : i64
  0)
(define payload : Payload
  (Payload 0 7 9))

(define (increment)
  (:export-symbol "tl_test_callback_increment") : i64
  (set! counter (+ counter 1))
  (set! payload.value (+ payload.value 2))
  counter)

;; Keep a transitive caller across optimization, including the tail-call path.
(define (invoke-through [depth : i64]) : i64
  (if (> depth 0)
    (invoke-through (- depth 1))
    (invoke-saved)))

(define (alias-through [depth : i64]) : i64
  (if (> depth 0)
    (alias-through (- depth 1))
    (tl_region_mark)))

(define (read-around-callback [n : i64] [mode : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (while (< i n)
      (+= sum (+ counter payload.value))
      (begin
        (cond
          [(= mode 0) (invoke increment)]
          [(= mode 1) (invoke-saved)]
          [(= mode 2) (invoke-through n)]
          [(= mode 3) (invoke-exported)]
          [(= mode 4) (tl_region_mark)]
          [else (alias-through n)])
        unit)
      (+= i 1))
    sum))

(define (check [n : i64] [mode : i64]) : bool
  (set! counter 0)
  (set! payload (Payload 0 7 9))
  (save increment)
  (let
    [sum : i64 (read-around-callback n mode)]
    (and
      (= sum (/ (* 3 (* n (- n 1))) 2))
      (= counter n)
      (= payload.value (* 2 n))
      (= payload.padding-a 7)
      (= payload.padding-b 9))))

;; Two calls with equal arguments each re-enter: neither may reuse the other's
;; result.
(define (alias-twice-ok? [depth : i64]) : bool
  (set! counter 0)
  (let
    [first : i64
      (if (> depth 0)
        (alias-through depth)
        (tl_region_mark))]
    [second : i64
      (if (> depth 0)
        (alias-through depth)
        (tl_region_mark))]
    (and (= first 1) (= second 2) (= counter 2))))

;; Read, call, read without a loop: the second read may not reuse the first.
(define (alias-delta) : i64
  (let
    [before : i64 counter]
    (begin
      (tl_region_mark)
      unit)
    (- counter before)))

(define (alias-delta-through [depth : i64]) : i64
  (let
    [before : i64 counter]
    (begin
      (alias-through depth)
      unit)
    (- counter before)))

(define (main) : i64
  (let
    [n : i64 (+ 2 (io.arg-count))]
    (if (and
      (check n 0)
      (check n 1)
      (check n 2)
      (check n 3)
      (check n 4)
      (check n 5)
      (check 0 0)
      (check 0 1)
      (check 0 2)
      (check 0 3)
      (check 0 4)
      (check 0 5)
      (begin
        (set! counter 0)
        (= (alias-delta) 1))
      (begin
        (set! counter 0)
        (= (alias-delta-through n) 1))
      (alias-twice-ok? 0)
      (alias-twice-ok? n))
      42
      1)))