; Locks down integer wrapping and cast bit semantics.
(define (add8 [a : i8] [b : i8]) : i8
  (+ a b))

(define (sub8 [a : i8] [b : i8]) : i8
  (- a b))

(define (mul8 [a : i8] [b : i8]) : i8
  (* a b))

(define (neg8 [a : i8]) : i8
  (neg a))

(define (addu8 [a : u8] [b : u8]) : u8
  (+ a b))

(define (widen-i8 [a : i8]) : i64
  (cast a : i64))

(define (widen-u8 [a : u8]) : i64
  (cast a : i64))

(define (narrow-u16 [a : u16]) : u8
  (cast a : u8))

(define (char-from-u16 [a : u16]) : char
  (cast a : char))

(define (main) : i64
  (if (!= (cast (add8 (cast 127 : i8) (cast 1 : i8)) : i64) -128)
      1
      (if (!= (cast (sub8 (cast -128 : i8) (cast 1 : i8)) : i64) 127)
          2
          (if (!= (cast (mul8 (cast 16 : i8) (cast 16 : i8)) : i64) 0)
              3
              (if (!= (cast (neg8 (cast -128 : i8)) : i64) -128)
                  4
                  (if (!= (cast (addu8 (cast 255 : u8) (cast 1 : u8)) : i64) 0)
                      5
                      (if (!= (widen-i8 (cast -1 : i8)) -1)
                          6
                          (if (!= (widen-u8 (cast 255 : u8)) 255)
                              7
                              (if (!= (cast (narrow-u16 (cast 257 : u16)) : i64) 1)
                                  8
                                  (if (!= (cast (char-from-u16 (cast 300 : u16)) : i64) 44)
                                      9
                                      0))))))))))
