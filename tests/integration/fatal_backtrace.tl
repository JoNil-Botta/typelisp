(import stdlib.io)

;; Debug-build fatal backtrace fixture. The recursive branch pins adjacent
;; repeated-frame compression; the outer calls remain non-tail at opt0. The
;; panic starts in a `with` cleanup, pinning the no-unwind cleanup contract.
(define (backtrace-leaf [value : i64]) : i64
  (if (= value 42)
    (io.panic "fatal backtrace fixture")
    value))

(define (backtrace-recurse [depth : i64] [value : i64]) : i64
  (if (= depth 0)
    (backtrace-leaf value)
    (+ (backtrace-recurse (- depth 1) value) 1)))

(define (backtrace-middle [value : i64]) : i64
  (+ (backtrace-recurse 3 value) 1))

(define (backtrace-outer [value : i64]) : i64
  (+ (backtrace-middle value) 1))

(define (backtrace-cleanup [value : i64]) : unit
  (begin
    (backtrace-outer value)
    unit))

(define (main) : i64
  (begin
    (with ([value 42 backtrace-cleanup]) unit)
    0))