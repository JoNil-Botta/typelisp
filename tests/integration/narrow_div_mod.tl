; Exercises narrow integer division and modulo instruction selection.
; 100 / 5 = 20, 42 / 6 = 7, 17 % 5 = 2, 22 % 7 = 1, total 30.
(define (div32 [a : i32] [b : i32]) : i32
  (/ a b))

(define (div16 [a : u16] [b : u16]) : u16
  (/ a b))

(define (mod8 [a : i8] [b : i8]) : i8
  (% a b))

(define (modu8 [a : u8] [b : u8]) : u8
  (% a b))

(define (main) : i64
  (+ (+ (+ (cast (div32 (cast 100 : i32) (cast 5 : i32)) : i64)
           (cast (div16 (cast 42 : u16) (cast 6 : u16)) : i64))
        (cast (mod8 (cast 17 : i8) (cast 5 : i8)) : i64))
     (cast (modu8 (cast 22 : u8) (cast 7 : u8)) : i64)))
