(define (sdiv3 [x : i64]) : i64
  (/ x 3))

(define (smod3 [x : i64]) : i64
  (% x 3))

(define (sdiv2 [x : i64]) : i64
  (/ x 2))

(define (smod2 [x : i64]) : i64
  (% x 2))

(define (sdiv7 [x : i64]) : i64
  (/ x 7))

(define (smod7 [x : i64]) : i64
  (% x 7))

(define (sdiv10 [x : i64]) : i64
  (/ x 10))

(define (smod10 [x : i64]) : i64
  (% x 10))

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

(define (sdiv-wide [x : i64]) : i64
  (/ x 4611686018427387903))

(define (smod-wide [x : i64]) : i64
  (% x 4611686018427387903))

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

(define (check-s2 [x : i64] [q : i64] [r : i64]) : i64
  (if (and (= (sdiv2 x) q) (= (smod2 x) r))
    0
    1))

(define (check-s3 [x : i64] [q : i64] [r : i64]) : i64
  (if (and (= (sdiv3 x) q) (= (smod3 x) r))
    0
    1))

(define (check-s7 [x : i64] [q : i64] [r : i64]) : i64
  (if (and (= (sdiv7 x) q) (= (smod7 x) r))
    0
    1))

(define (check-s10 [x : i64] [q : i64] [r : i64]) : i64
  (if (and (= (sdiv10 x) q) (= (smod10 x) r))
    0
    1))

(define (check-sprime [x : i64] [q : i64] [r : i64]) : i64
  (if (and (= (sdiv-prime x) q) (= (smod-prime x) r))
    0
    1))

(define (check-swide [x : i64] [q : i64] [r : i64]) : i64
  (if (and (= (sdiv-wide x) q) (= (smod-wide x) r))
    0
    1))

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
      ;; Signed opt0/opt2 parity corpus. Every helper keeps its divisor literal
      ;; in the function body, and the expected quotient truncates toward zero;
      ;; the remainder therefore has the dividend's sign.
      (set! errors (+ errors (check-s2 min -4611686018427387904 0)))
      (set! errors (+ errors (check-s2 (+ min 1) -4611686018427387903 -1)))
      (set! errors (+ errors (check-s2 -3 -1 -1)))
      (set! errors (+ errors (check-s2 -2 -1 0)))
      (set! errors (+ errors (check-s2 -1 0 -1)))
      (set! errors (+ errors (check-s2 0 0 0)))
      (set! errors (+ errors (check-s2 1 0 1)))
      (set! errors (+ errors (check-s2 2 1 0)))
      (set! errors (+ errors (check-s2 3 1 1)))
      (set!
        errors
        (+ errors (check-s2 9223372036854775807 4611686018427387903 1)))
      (set! errors (+ errors (check-s3 min -3074457345618258602 -2)))
      (set! errors (+ errors (check-s3 (+ min 1) -3074457345618258602 -1)))
      (set! errors (+ errors (check-s3 -4 -1 -1)))
      (set! errors (+ errors (check-s3 -3 -1 0)))
      (set! errors (+ errors (check-s3 -2 0 -2)))
      (set! errors (+ errors (check-s3 -1 0 -1)))
      (set! errors (+ errors (check-s3 0 0 0)))
      (set! errors (+ errors (check-s3 1 0 1)))
      (set! errors (+ errors (check-s3 2 0 2)))
      (set! errors (+ errors (check-s3 3 1 0)))
      (set! errors (+ errors (check-s3 4 1 1)))
      (set!
        errors
        (+ errors (check-s3 9223372036854775807 3074457345618258602 1)))
      (set! errors (+ errors (check-s7 min -1317624576693539401 -1)))
      (set! errors (+ errors (check-s7 (+ min 1) -1317624576693539401 0)))
      (set! errors (+ errors (check-s7 -8 -1 -1)))
      (set! errors (+ errors (check-s7 -7 -1 0)))
      (set! errors (+ errors (check-s7 -6 0 -6)))
      (set! errors (+ errors (check-s7 -1 0 -1)))
      (set! errors (+ errors (check-s7 0 0 0)))
      (set! errors (+ errors (check-s7 1 0 1)))
      (set! errors (+ errors (check-s7 6 0 6)))
      (set! errors (+ errors (check-s7 7 1 0)))
      (set! errors (+ errors (check-s7 8 1 1)))
      (set!
        errors
        (+ errors (check-s7 9223372036854775807 1317624576693539401 0)))
      (set! errors (+ errors (check-s10 min -922337203685477580 -8)))
      (set! errors (+ errors (check-s10 (+ min 1) -922337203685477580 -7)))
      (set! errors (+ errors (check-s10 -11 -1 -1)))
      (set! errors (+ errors (check-s10 -10 -1 0)))
      (set! errors (+ errors (check-s10 -9 0 -9)))
      (set! errors (+ errors (check-s10 -1 0 -1)))
      (set! errors (+ errors (check-s10 0 0 0)))
      (set! errors (+ errors (check-s10 1 0 1)))
      (set! errors (+ errors (check-s10 9 0 9)))
      (set! errors (+ errors (check-s10 10 1 0)))
      (set! errors (+ errors (check-s10 11 1 1)))
      (set!
        errors
        (+ errors (check-s10 9223372036854775807 922337203685477580 7)))
      (set! errors (+ errors (check-sprime min -9223371972 -291172004)))
      (set! errors (+ errors (check-sprime (+ min 1) -9223371972 -291172003)))
      (set! errors (+ errors (check-sprime -1000000008 -1 -1)))
      (set! errors (+ errors (check-sprime -1000000007 -1 0)))
      (set! errors (+ errors (check-sprime -1000000006 0 -1000000006)))
      (set! errors (+ errors (check-sprime -1 0 -1)))
      (set! errors (+ errors (check-sprime 0 0 0)))
      (set! errors (+ errors (check-sprime 1 0 1)))
      (set! errors (+ errors (check-sprime 1000000006 0 1000000006)))
      (set! errors (+ errors (check-sprime 1000000007 1 0)))
      (set! errors (+ errors (check-sprime 1000000008 1 1)))
      (set!
        errors
        (+ errors (check-sprime 9223372036854775807 9223371972 291172003)))
      (set! errors (+ errors (check-swide min -2 -2)))
      (set! errors (+ errors (check-swide (+ min 1) -2 -1)))
      (set! errors (+ errors (check-swide -4611686018427387904 -1 -1)))
      (set! errors (+ errors (check-swide -4611686018427387903 -1 0)))
      (set!
        errors
        (+ errors (check-swide -4611686018427387902 0 -4611686018427387902)))
      (set! errors (+ errors (check-swide -1 0 -1)))
      (set! errors (+ errors (check-swide 0 0 0)))
      (set! errors (+ errors (check-swide 1 0 1)))
      (set!
        errors
        (+ errors (check-swide 4611686018427387902 0 4611686018427387902)))
      (set! errors (+ errors (check-swide 4611686018427387903 1 0)))
      (set! errors (+ errors (check-swide 4611686018427387904 1 1)))
      (set! errors (+ errors (check-swide 9223372036854775807 2 1)))
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