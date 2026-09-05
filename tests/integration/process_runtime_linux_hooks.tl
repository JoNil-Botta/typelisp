;; Fault state for the dedicated native Linux process-runtime gate. This module
;; is source-resolved only under `process-linux-test-hooks`; it is deliberately
;; excluded from the installed compiler's embedded stdlib payload.
(define no-injection : i64
  -9223372036854775808)
(define counts : (__tl_dyn-array i64)
  (__tl_make-array i64 16))
(define fail-kind-a : i64
  0)
(define fail-call-a : i64
  0)
(define fail-errno-a : i64
  0)
(define fail-kind-b : i64
  0)
(define fail-call-b : i64
  0)
(define fail-errno-b : i64
  0)
(define write-max : i64
  0)
(define read-max : i64
  0)
(define child-fail-kind : i64
  0)
(define child-fail-errno : i64
  0)
(define marker-mode-value : i64
  0)

(define (reset!) : unit
  (let
    [index : i64 0]
    (begin
      (while (< index (array-length counts))
        (begin
          (set! (array-ref counts index) 0)
          (set! index (+ index 1))))
      (set! fail-kind-a 0)
      (set! fail-call-a 0)
      (set! fail-errno-a 0)
      (set! fail-kind-b 0)
      (set! fail-call-b 0)
      (set! fail-errno-b 0)
      (set! write-max 0)
      (set! read-max 0)
      (set! child-fail-kind 0)
      (set! child-fail-errno 0)
      (set! marker-mode-value 0))))

(define (fail-on! [kind : i64] [call : i64] [errno-code : i64]) : unit
  (begin
    (set! fail-kind-a kind)
    (set! fail-call-a call)
    (set! fail-errno-a errno-code)))

(define (fail-second-on! [kind : i64] [call : i64] [errno-code : i64]) : unit
  (begin
    (set! fail-kind-b kind)
    (set! fail-call-b call)
    (set! fail-errno-b errno-code)))

(define (child-fail-on! [kind : i64] [errno-code : i64]) : unit
  (begin
    (set! child-fail-kind kind)
    (set! child-fail-errno errno-code)))

(define (set-write-max! [count : i64]) : unit
  (set! write-max count))

(define (set-read-max! [count : i64]) : unit
  (set! read-max count))

(define (set-marker-mode! [mode : i64]) : unit
  (set! marker-mode-value mode))

(define (call-count [kind : i64]) : i64
  (if (and (>= kind 0) (< kind (array-length counts)))
    (array-ref counts kind)
    0))

(define (injected-result [kind : i64]) : i64
  (let
    [call : i64 (+ (array-ref counts kind) 1)]
    (begin
      (set! (array-ref counts kind) call)
      (cond
        [(and (= kind fail-kind-a) (= call fail-call-a)) (- 0 fail-errno-a)]
        [(and (= kind fail-kind-b) (= call fail-call-b)) (- 0 fail-errno-b)]
        [else no-injection]))))

(define (write-request-count [count : i64]) : i64
  (if (and (> write-max 0) (> count write-max))
    write-max
    count))

(define (read-request-count [count : i64]) : i64
  (if (and (> read-max 0) (> count read-max))
    read-max
    count))

(define (child-injected-result [kind : i64]) : i64
  (if (= kind child-fail-kind)
    (- 0 child-fail-errno)
    no-injection))

(define (marker-mode) : i64
  marker-mode-value)