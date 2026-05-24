;; Exercises the `f64->bits` builtin (#721): the IEEE-754 bit-reinterpret the

;; self-hosted backend uses to serialize an f64 constant deterministically (it

;; emits `.quad <bits>` / `movabsq`). `f64->bits` yields a u64; these patterns

;; are all positive, so they are compared as i64 after a (purely integer) cast.

;; Returns 42 iff every bit pattern matches the known IEEE-754 encoding.

(define (bits-i64 [x : f64]) : i64
  (cast (f64->bits x) : i64))

(define (main) : i64
  (if (= (bits-i64 1.0) 4607182418800017408)
    ; 0x3FF0000000000000
    (if (= (bits-i64 2.0) 4611686018427387904)
      ; 0x4000000000000000
      (if (= (bits-i64 0.5) 4602678819172646912)
        ; 0x3FE0000000000000
        42
        3)
      2)
    1))