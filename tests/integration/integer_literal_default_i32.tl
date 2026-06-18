(define (unconstrained-default) : i32
  (let
    [x (+ 1 2)]
    x))

(define (contextual-i64) : i64
  (let
    [x : i64 1]
    x))

(define (explicit-wide-cast) : i64
  (cast (cast 0x100000000 : u64) : i64))

(define (contextual-return-i64 [flag : bool]) : i64
  (return
    (if flag
      (contextual-i64)
      0)))

(define (contextual-make-array-len [n : i64]) : i64
  (array-length
    (make-array
      i64
      (if (< n 1)
        1
        n))))

(define (contextual-match-if [flag : bool]) : i64
  (match "ok"
    ["ok"
      (if flag
        (contextual-i64)
        0)]
    [_ 0]))

(define (main) : i64
  (begin
    (unless (= (unconstrained-default) 3) (return 1))
    (unless (= (contextual-i64) 1) (return 2))
    (unless (= (explicit-wide-cast) 4294967296) (return 3))
    (unless (= (contextual-return-i64 false) 0) (return 4))
    (unless (= (contextual-make-array-len 0) 1) (return 5))
    (unless (= (contextual-match-if false) 0) (return 6))
    42))