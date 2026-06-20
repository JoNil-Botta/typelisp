(define decimal-max : u64
  18446744073709551615)
(define hex-max : u64
  0xffffffffffffffff)
(define binary-max : u64
  0b1111111111111111111111111111111111111111111111111111111111111111)
(define decimal-high-bit : u64
  9223372036854775808)
(define hex-high-bit : u64
  0x8000000000000000)
(define binary-high-bit : u64
  0b1000000000000000000000000000000000000000000000000000000000000000)

(define (main) : i64
  (cond
    [(!= decimal-max (cast -1 : u64)) 1]
    [(!= hex-max (cast -1 : u64)) 2]
    [(!= binary-max (cast -1 : u64)) 3]
    [(!= decimal-high-bit (shl (cast 1 : u64) 63)) 4]
    [(!= hex-high-bit (shl (cast 1 : u64) 63)) 5]
    [(!= binary-high-bit (shl (cast 1 : u64) 63)) 6]
    [else 42]))