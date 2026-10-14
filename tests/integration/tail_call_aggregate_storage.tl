;; A tail call must keep argument storage live through the callee. Capturing
;; an incoming aggregate or borrowing a local creates storage in this frame;
;; discarding it before the jump lets the callee's scratch array overwrite it.
(defstruct TailPayload
  (a i64)
  (b i64)
  (c i64))

(define (tail-consume [value : TailPayload] [index : i64]) : i64
  (let
    [scratch : (Array i64 8) (array 0 0 0 0 0 0 0 0)]
    (+ (+ value.a (+ value.b value.c)) (array-ref scratch index))))

(define (tail-forward [value : TailPayload] [index : i64]) : i64
  (tail-consume value index))

(define (tail-local [index : i64]) : i64
  (let
    [value : TailPayload (TailPayload 11 13 18)]
    (tail-consume value index)))

(define (tail-consume-reference [value : (& value i64)] [index : i64]) : i64
  (let
    [scratch : (Array i64 8) (array 0 0 0 0 0 0 0 0)]
    (+ (deref value) (array-ref scratch index))))

(define (tail-projection [first : bool] [index : i64]) : i64
  (let
    [value : TailPayload (TailPayload 42 0 42)]
    [selected : (& value i64)
      (if first
        (& value.a)
        (& value.c))]
    (tail-consume-reference selected index)))

(define (tail-consume-pointer [value : (Ptr i64)] [index : i64]) : i64
  (let
    [scratch : (Array i64 8) (array 0 0 0 0 0 0 0 0)]
    (+
      (unsafe
        (ptr-read value))
      (array-ref scratch index))))

(define (tail-pointer-projection [first : bool] [index : i64]) : i64
  (let
    [value : TailPayload (TailPayload 42 0 42)]
    [bytes : (Ptr u8)
      (unsafe
        (ptr-cast (ptr-addr-of value) : (Ptr u8)))]
    [selected : (Ptr i64)
      (unsafe
        (ptr-cast
          (ptr-offset
            bytes
            (if first
              0
              16))
          : (Ptr i64)))]
    (tail-consume-pointer selected index)))

;; A scalar-only call remains eligible for ordinary tail-call handling.
(define (tail-scalar [value : i64]) : i64
  (+ value 1))

(define (tail-scalar-forward [value : i64]) : i64
  (tail-scalar value))

;; Unchanged references keep their caller's storage and must remain tail jumps.
;; This depth exceeds even the 1 GiB native main stack if recursion returns.
(define (tail-reference-loop [value : (& value TailPayload)] [n : i64]) : i64
  (if (= n 0)
    (+ value.a (+ value.b value.c))
    (tail-reference-loop value (- n 1))))

(define (tail-mut-reference-loop [value : (&mut value TailPayload)] [n : i64]) : i64
  (if (= n 0)
    value.a
    (tail-mut-reference-loop value (- n 1))))

(define (main) : i64
  (let
    [value : TailPayload (TailPayload 11 13 18)]
    [first : i64 (tail-forward value 0)]
    [second : i64 (tail-forward value 1)]
    (if (and
      (= first 42)
      (= second 42)
      (= (tail-local 2) 42)
      (= (tail-projection true 3) 42)
      (= (tail-projection false 4) 42)
      (= (tail-pointer-projection true 5) 42)
      (= (tail-pointer-projection false 6) 42)
      (= (tail-reference-loop (& value) 10000000) 42)
      (= (tail-mut-reference-loop (&mut value) 10000000) 11)
      (= (tail-scalar-forward 41) 42))
      42
      1)))