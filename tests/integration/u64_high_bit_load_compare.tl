(define (threshold) : u64
  (shl (cast 1 : u64) 63))

(define (dynamic-array-clear-high-bit) : i64
  (let
    [items : (Array u64) (make-array u64 1)]
    (begin
      (array-set! items 0 (cast 0x6666666666666667 : u64))
      (if (>= (array-ref items 0) (threshold))
        1
        42))))

(define (fixed-array-clear-high-bit) : i64
  (let
    [items : (Array u64 1) (array (cast 0x6666666666666667 : u64))]
    (if (>= (array-ref items 0) (threshold))
      2
      42)))

(define (dynamic-array-set-high-bit) : i64
  (let
    [items : (Array u64) (make-array u64 1)]
    (begin
      (array-set! items 0 (threshold))
      (if (>= (array-ref items 0) (threshold))
        42
        3))))

(define (fixed-array-set-high-bit) : i64
  (let
    [items : (Array u64 1) (array (threshold))]
    (if (>= (array-ref items 0) (threshold))
      42
      4)))

(define (main) : i64
  (cond
    [(!= (dynamic-array-clear-high-bit) 42) 1]
    [(!= (fixed-array-clear-high-bit) 42) 2]
    [(!= (dynamic-array-set-high-bit) 42) 3]
    [(!= (fixed-array-set-high-bit) 42) 4]
    [else 42]))