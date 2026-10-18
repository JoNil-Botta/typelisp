(extern foreign-word (:symbol "tl_data_word") : i64)
(extern foreign-float (:symbol "tl_data_float") : f32)
(extern foreign-byte (:symbol "tl_data_byte") : u8)

(define local-word : i64
  7)

(define (left [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (left x (+ poke 1))
    (if (= foreign-word x)
      1
      0)))

(define (right [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (right x (+ poke 1))
    (if (< x foreign-word)
      1
      0)))

(define (add [x : i64] [poke : i64]) : i64
  (if (< poke 0)
    (add x (+ poke 1))
    (+ x foreign-word)))

(define (fraction [poke : i64]) : i64
  (if (< poke 0)
    (fraction (+ poke 1))
    (cast foreign-float : i64)))

(define (byte [poke : i64]) : i64
  (if (< poke 0)
    (byte (+ poke 1))
    (cast foreign-byte : i64)))

(define (main) : i64
  (if (and
    (= (left 7 0) 1)
    (= (left 8 0) 0)
    (= (right 6 0) 1)
    (= (right 7 0) 0)
    (= (right 8 0) 0)
    (= (add 35 0) 42)
    (= (fraction 0) 42)
    (= (byte 0) 255)
    (= local-word 7))
    42
    1))