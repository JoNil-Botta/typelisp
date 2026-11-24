;; #9945: `with` cleanup lowering must emit an indirect call when the cleanup
;; expression names a local or parameter callable binding.
(defstruct PairHandle
  (a i64)
  (b i64))

(define trace : i64
  0)

(define (push-trace [v : i64]) : unit
  (set! trace (+ (* trace 100) v)))

(define (top-close [h : i64]) : unit
  (push-trace h))

(define (run-param-cleanup [close : (-> i64 unit)] [val : i64]) : i64
  (with ([h val close]) (+ h 1)))

(define (run-param-early-return [close : (-> i64 unit)] [val : i64]) : i64
  (with
    ([h val close])
    ;; Shadow `close` inside the body before an early return to verify the
    ;; cleanup still invokes the outer callable binding.
    (let
      [close : i64 999]
      (when (> close 0) (return (+ h 2))))
    0))

(define (run-local-lambda [val : i64]) : i64
  (let
    [close : (-> i64 unit)
      (lambda ([h : i64]) : unit
        (push-trace (+ h 10)))]
    (with ([h val close]) (+ h 0))))

(define (run-capturing-closure [delta : i64] [val : i64]) : i64
  (let
    [close : (-> i64 unit)
      (lambda ([h : i64]) : unit
        (push-trace (+ h delta)))]
    (with ([h val close]) (+ h 0))))

(define (run-local-fn-alias [val : i64]) : i64
  (let
    [close : (-> i64 unit) top-close]
    (with ([h val close]) (+ h 0))))

(define (run-loop-break [close : (-> i64 unit)]) : i64
  (let
    [i : i64 0]
    (while (< i 3)
      (with
        ([h (+ i 30) close])
        (set! i (+ i 1))
        (when (= i 2) (break))
        (let
          [_ : i64 (+ h 0)]
          unit)))
    i))

(define (run-multi-binding-shadow [first-close : (-> i64 unit)]) : i64
  (let
    [second-close : (-> i64 unit)
      (lambda ([h : i64]) : unit
        (push-trace (+ h 40)))]
    (with ([a 1 first-close] [first-close 2 second-close]) (+ a first-close))))

(define (run-struct-cleanup [close : (-> PairHandle unit)]) : i64
  (with ([p (PairHandle 3 4) close]) (+ p.a p.b)))

(define (main) : i64
  (set! trace 0)
  (unless (= (run-param-cleanup top-close 11) 12) (return 1))
  (unless (= trace 11) (return 2))
  (set! trace 0)
  (unless (= (run-param-early-return top-close 12) 14) (return 3))
  (unless (= trace 12) (return 4))
  (set! trace 0)
  (unless (= (run-local-lambda 5) 5) (return 5))
  (unless (= trace 15) (return 6))
  (set! trace 0)
  (unless (= (run-capturing-closure 20 7) 7) (return 7))
  (unless (= trace 27) (return 8))
  (set! trace 0)
  (unless (= (run-local-fn-alias 19) 19) (return 9))
  (unless (= trace 19) (return 10))
  (set! trace 0)
  (unless (= (run-loop-break top-close) 2) (return 11))
  (unless (= trace 3031) (return 12))
  (set! trace 0)
  (unless (= (run-multi-binding-shadow top-close) 3) (return 13))
  ;; LIFO: `second-close` runs on 2 -> 42, then `first-close` runs on 1 -> 1.
  (unless (= trace 4201) (return 14))
  (set! trace 0)
  (let
    [pair-close : (-> PairHandle unit)
      (lambda ([p : PairHandle]) : unit
        (push-trace (+ (* p.a 10) p.b)))]
    (unless (= (run-struct-cleanup pair-close) 7) (return 15)))
  (unless (= trace 34) (return 16))
  42)