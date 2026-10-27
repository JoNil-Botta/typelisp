;; Complete fixed-array returns can forward only after excluding result aliases,
;; frame-retaining arguments and observable work after the recursive call.
(import stdlib.iterator)

(define (make-fixed-array [depth : i64]) : (Array i64 3)
  (if (> depth 0)
    (make-fixed-array (- depth 1))
    (array 10 11 21)))

(define (make-four [depth : i64] [seed : i64]) : (Array i64 4)
  (if (> depth 0)
    (make-four (- depth 1) (+ seed 1))
    (array seed (+ seed 1) (+ seed 2) (+ seed 3))))

;; These references point into successive activations. Reusing one frame would
;; change the lifetime of the outgoing borrow, even though the result is tail.
(define (frame-held [depth : i64] [input : (& i64)]) : (Array i64 3)
  (if (> depth 0)
    (let
      [next : i64 (+ (deref input) 1)]
      (frame-held (- depth 1) (& next)))
    (array (deref input) 11 21)))

(define (post-call [depth : i64]) : (Array i64 3)
  (if (> depth 0)
    (let
      [value : (Array i64 3) (post-call (- depth 1))]
      (array (+ (array-ref value 0) 1) (array-ref value 1) (array-ref value 2)))
    (array 10 11 21)))

;; A structural by-value argument still owes its ABI materialization and private
;; storage. A second live result keeps each call's temporary independent.
(define (array-input [depth : i64] [input : (Array i64 3)]) : (Array i64 3)
  (if (> depth 0)
    (array-input (- depth 1) input)
    input))

;; Frame capture can refuse scalar self-tailrec conversion too. Its original
;; inliner policy must remain intact when array-result forwarding is added.
(define (sum-ref [input : (& (Array i64 3))] [n : i64]) : i64
  (let
    [total : i64 0]
    [i : i64 0]
    (while (< i n)
      (set! total (+ total (array-ref (deref input) (% i 3))))
      (set! i (+ i 1)))
    total))

(define (frame-refused-loop [n : i64] [total : i64]) : i64
  (if (= n 0)
    total
    (let
      [temporary : (Array i64 3) (array n 1 2)]
      (frame-refused-loop (- n 1) (+ total (sum-ref (& temporary) n))))))

(define (main) : i64
  (let
    [issue : (Array i64 3) (make-fixed-array 2)]
    [deep : (Array i64 3) (make-fixed-array 4096)]
    [four : (Array i64 4) (make-four 64 10)]
    [seed : i64 10]
    [framed : (Array i64 3) (frame-held 32 (& seed))]
    [post : (Array i64 3) (post-call 32)]
    [first : (Array i64 3) (array-input 16 (array 10 11 21))]
    [second : (Array i64 3) (array-input 8 (array 20 21 1))]
    [policy-total : i64 0]
    (for [k (iterator.range 0 3)]
      (set! policy-total (+ policy-total (frame-refused-loop 4 k))))
    (if (and
      (= policy-total 66)
      (= (+ (array-ref issue 0) (array-ref issue 1) (array-ref issue 2)) 42)
      (= (+ (array-ref deep 0) (array-ref deep 1) (array-ref deep 2)) 42)
      (= (array-ref four 0) 74)
      (= (array-ref four 3) 77)
      (= (array-ref framed 0) 42)
      (= (array-ref post 0) 42)
      (= (+ (array-ref first 0) (array-ref first 1) (array-ref first 2)) 42)
      (= (+ (array-ref second 0) (array-ref second 1) (array-ref second 2)) 42))
      42
      1)))