(import stdlib.io)

(extern (invoke [callback : (-> i64)]) : i64 (:symbol "tl_test_callback_invoke"))
(extern (save [callback : (-> i64)]) : i64 (:symbol "tl_test_callback_save"))
(extern (invoke-exported) : i64 (:symbol "tl_test_callback_invoke_exported"))
(extern (invoke-saved) : i64 (:symbol "tl_test_callback_invoke_saved"))

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
          [else (invoke-exported)])
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

(define (main) : i64
  (let
    [n : i64 (+ 2 (io.arg-count))]
    (if (and
      (check n 0)
      (check n 1)
      (check n 2)
      (check n 3)
      (check 0 0)
      (check 0 1)
      (check 0 2)
      (check 0 3))
      42
      1)))