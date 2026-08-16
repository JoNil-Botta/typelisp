;; The source and generated intern lanes share one fixed-capacity pool. Exercise
;; each active/state-owned allocation direction at the real meeting boundary;
;; opaque generated allocation deliberately accepts one repeated spelling.
(import compiler_intern)
(import stdlib.io)
(import stdlib.string)

(define (fill-active-generated) : unit
  (let
    [i : i64 0]
    (while (< i (compiler_intern.intern-capacity))
      (begin
        (compiler_intern.intern-generated-name "opaque")
        (set! i (+ i 1))))))

(define (fill-state-generated
  [state : (&mut state compiler_intern.InternCompatState)]) : unit
  (let
    [i : i64 0]
    (while (< i (compiler_intern.intern-capacity))
      (begin
        (compiler_intern.intern-compat-state-generated-name state "opaque")
        (set! i (+ i 1))))))

(define (active-source-exhaustion) : i64
  (begin
    (compiler_intern.intern-reset!)
    (fill-active-generated)
    (compiler_intern.intern "source-overflow")))

(define (active-generated-exhaustion) : i64
  (begin
    (compiler_intern.intern-reset!)
    (fill-active-generated)
    (compiler_intern.intern-generated-name "generated-overflow")))

(define (state-source-exhaustion) : i64
  (let
    [state : compiler_intern.InternCompatState
      (compiler_intern.intern-compat-state-new)]
    (begin
      (fill-state-generated (&mut state))
      (compiler_intern.intern-compat-state-intern
        (&mut state)
        "source-overflow"))))

(define (state-generated-exhaustion) : i64
  (let
    [state : compiler_intern.InternCompatState
      (compiler_intern.intern-compat-state-new)]
    (begin
      (fill-state-generated (&mut state))
      (compiler_intern.intern-compat-state-generated-name
        (&mut state)
        "generated-overflow"))))

(define (main) : i64
  (match (string.>int (io.arg 1))
    [0 (active-source-exhaustion)]
    [1 (active-generated-exhaustion)]
    [2 (state-source-exhaustion)]
    [_ (state-generated-exhaustion)]))
