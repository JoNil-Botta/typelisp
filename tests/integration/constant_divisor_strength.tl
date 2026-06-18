(define (sdiv3 [x : i64]) : i64
  (/ x 3))

(define (smod3 [x : i64]) : i64
  (% x 3))

(define (sdiv-neg3 [x : i64]) : i64
  (/ x -3))

(define (smod-neg3 [x : i64]) : i64
  (% x -3))

(define (sdiv8 [x : i64]) : i64
  (/ x 8))

(define (smod8 [x : i64]) : i64
  (% x 8))

(define (sdiv-neg8 [x : i64]) : i64
  (/ x -8))

(define (smod-neg8 [x : i64]) : i64
  (% x -8))

(define (sdiv-prime [x : i64]) : i64
  (/ x 1000000007))

(define (smod-prime [x : i64]) : i64
  (% x 1000000007))

(define (sdiv-i32-3 [x : i32]) : i32
  (/ x (cast 3 : i32)))

(define (smod-i8-3 [x : i8]) : i8
  (% x (cast 3 : i8)))

(define (udiv3 [x : u64]) : u64
  (/ x (cast 3 : u64)))

(define (umod3 [x : u64]) : u64
  (% x (cast 3 : u64)))

(define (udiv7 [x : u64]) : u64
  (/ x (cast 7 : u64)))

(define (umod7 [x : u64]) : u64
  (% x (cast 7 : u64)))

(define (udiv8 [x : u64]) : u64
  (/ x (cast 8 : u64)))

(define (umod8 [x : u64]) : u64
  (% x (cast 8 : u64)))

(define (udiv-prime [x : u64]) : u64
  (/ x (cast 1000000007 : u64)))

(define (umod-prime [x : u64]) : u64
  (% x (cast 1000000007 : u64)))

(define (udiv-high [x : u64]) : u64
  (/ x (cast -2 : u64)))

(define (umod-high [x : u64]) : u64
  (% x (cast -2 : u64)))

(define (udiv-u32-3 [x : u32]) : u32
  (/ x (cast 3 : u32)))

(define (umod-u16-7 [x : u16]) : u16
  (% x (cast 7 : u16)))

(define (check-i64 [actual : i64] [expected : i64] [code : i64]) : i64
  (if (= actual expected)
    0
    code))

(define (check-u64 [actual : u64] [expected : u64] [code : i64]) : i64
  (if (= actual expected)
    0
    code))

(define (main) : i64
  (let
    [min : i64 (- (- 0 9223372036854775807) 1)]
    [umax : u64 (cast -1 : u64)]
    [errors : i64 0]
    (begin
      (set! errors (+ errors (check-i64 (sdiv3 min) -3074457345618258602 1)))
      (set! errors (+ errors (check-i64 (smod3 min) -2 2)))
      (set! errors (+ errors (check-i64 (sdiv3 -10) -3 3)))
      (set! errors (+ errors (check-i64 (smod3 -10) -1 4)))
      (set! errors (+ errors (check-i64 (sdiv-neg3 min) 3074457345618258602 5)))
      (set! errors (+ errors (check-i64 (smod-neg3 min) -2 6)))
      (set! errors (+ errors (check-i64 (sdiv8 -10) -1 7)))
      (set! errors (+ errors (check-i64 (smod8 -10) -2 8)))
      (set! errors (+ errors (check-i64 (sdiv-neg8 10) -1 9)))
      (set! errors (+ errors (check-i64 (smod-neg8 10) 2 10)))
      (set! errors (+ errors (check-i64 (sdiv-prime min) -9223371972 11)))
      (set! errors (+ errors (check-i64 (smod-prime min) -291172004 12)))
      (set!
        errors
        (+ errors (check-i64 (cast (sdiv-i32-3 (cast -10 : i32)) : i64) -3 21)))
      (set!
        errors
        (+ errors (check-i64 (cast (smod-i8-3 (cast -10 : i8)) : i64) -1 22)))
      (set! errors (+ errors (check-u64 (udiv3 umax) 6148914691236517205 13)))
      (set! errors (+ errors (check-u64 (umod3 umax) 0 14)))
      (set! errors (+ errors (check-u64 (udiv7 umax) 2635249153387078802 15)))
      (set! errors (+ errors (check-u64 (umod7 umax) 1 16)))
      (set! errors (+ errors (check-u64 (udiv8 umax) 2305843009213693951 17)))
      (set! errors (+ errors (check-u64 (umod8 umax) 7 18)))
      (set! errors (+ errors (check-u64 (udiv-prime umax) 18446743944 19)))
      (set! errors (+ errors (check-u64 (umod-prime umax) 582344007 20)))
      (set! errors (+ errors (check-u64 (udiv-high umax) 1 25)))
      (set! errors (+ errors (check-u64 (umod-high umax) 1 26)))
      (set!
        errors
        (+
          errors
          (check-u64 (cast (udiv-u32-3 (cast -1 : u32)) : u64) 1431655765 23)))
      (set!
        errors
        (+ errors (check-u64 (cast (umod-u16-7 (cast -1 : u16)) : u64) 1 24)))
      (if (= errors 0)
        42
        errors))))