(import stdlib.io)

(define power31 : i64
  2147483648)
(define power34 : i64
  17179869184)
(define power62 : i64
  4611686018427387904)
(define unsigned-power34 : u64
  17179869184)
(define mutable-power : i64
  17179869184)
(define addressed-power : i64
  17179869184)
(define initialized-power : i64
  (+ 17179869184 (io.arg-count)))

(define (mul-right [value : i64]) : i64
  (* value power34))

(define (mul-left [value : i64]) : i64
  (* power62 value))

(define (mul31 [value : i64]) : i64
  (* value power31))

(define (mul-unsigned [value : u64]) : u64
  (* unsigned-power34 value))

(define (mul-mutable [value : i64]) : i64
  (* value mutable-power))

(define (mul-addressed [value : i64]) : i64
  (* addressed-power value))

(define (mul-initialized [value : i64]) : i64
  (* value initialized-power))

(define (write-ref! [value : (&mut value i64)] [next : i64]) : unit
  (set! (deref value) next))

(define (main) : i64
  (let
    [i : i64 -257]
    [ok : bool true]
    [argc : i64 (io.arg-count)]
    (begin
      (while (< i (+ 256 argc))
        (let
          [value : i64 (bit-xor (shl i 50) (+ (* i 65537) argc))]
          (begin
            (set!
              ok
              (and
                ok
                (= (mul-right value) (shl value 34))
                (= (mul-left value) (shl value 62))
                (= (mul31 value) (shl value 31))
                (=
                  (mul-unsigned (cast value : u64))
                  (shl (cast value : u64) 34))
                (= (mul-initialized value) (* value (+ 17179869184 argc)))))
            (set! i (+ i 1)))))
      (set! mutable-power 3)
      (write-ref! (&mut addressed-power) 5)
      (if (and
        ok
        (= (mul-mutable 14) 42)
        (= (mul-addressed 8) 40)
        (= (/ 34359738410 power34) 2)
        (= (% 34359738410 power34) 42)
        (= (+ power62 1) 4611686018427387905))
        42
        1))))