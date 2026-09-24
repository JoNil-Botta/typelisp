(import stdlib.io)
(import stdlib.string)

(define (mix3 [seed : u64] [n : i64]) : u64
  (let
    [x0 : u64 (cast (+ seed 1) : u64)]
    [x1 : i64 (cast (+ seed 2) : i64)]
    [x2 : u64 (cast (+ seed 3) : u64)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! x0 (bit-xor (* x0 17) (cast (+ i 0) : u64)))
          (set! x1 (bit-xor (* x1 33) (cast (+ i 1) : i64)))
          (set! x2 (bit-xor (* x2 65) (cast (+ i 2) : u64)))
          (set! i (+ i 1))))
      (+ (* (+ (* (cast x0 : u64) 131) (cast x1 : u64)) 131) (cast x2 : u64)))))

(define (mix12 [seed : u64] [n : i64]) : u64
  (let
    [x0 : u64 (cast (+ seed 1) : u64)]
    [x1 : i64 (cast (+ seed 2) : i64)]
    [x2 : u64 (cast (+ seed 3) : u64)]
    [x3 : i64 (cast (+ seed 4) : i64)]
    [x4 : u64 (cast (+ seed 5) : u64)]
    [x5 : i64 (cast (+ seed 6) : i64)]
    [x6 : u64 (cast (+ seed 7) : u64)]
    [x7 : i64 (cast (+ seed 8) : i64)]
    [x8 : u64 (cast (+ seed 9) : u64)]
    [x9 : i64 (cast (+ seed 10) : i64)]
    [x10 : u64 (cast (+ seed 11) : u64)]
    [x11 : i64 (cast (+ seed 12) : i64)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! x0 (bit-xor (* x0 17) (cast (+ i 0) : u64)))
          (set! x1 (bit-xor (* x1 33) (cast (+ i 1) : i64)))
          (set! x2 (bit-xor (* x2 65) (cast (+ i 2) : u64)))
          (set! x3 (bit-xor (* x3 17) (cast (+ i 3) : i64)))
          (set! x4 (bit-xor (* x4 33) (cast (+ i 4) : u64)))
          (set! x5 (bit-xor (* x5 65) (cast (+ i 5) : i64)))
          (set! x6 (bit-xor (* x6 17) (cast (+ i 6) : u64)))
          (set! x7 (bit-xor (* x7 33) (cast (+ i 7) : i64)))
          (set! x8 (bit-xor (* x8 65) (cast (+ i 8) : u64)))
          (set! x9 (bit-xor (* x9 17) (cast (+ i 9) : i64)))
          (set! x10 (bit-xor (* x10 33) (cast (+ i 10) : u64)))
          (set! x11 (bit-xor (* x11 65) (cast (+ i 11) : i64)))
          (set! i (+ i 1))))
      (+
        (*
          (+
            (*
              (+
                (*
                  (+
                    (*
                      (+
                        (*
                          (+
                            (*
                              (+
                                (*
                                  (+
                                    (*
                                      (+
                                        (*
                                          (+
                                            (*
                                              (+
                                                (* (cast x0 : u64) 131)
                                                (cast x1 : u64))
                                              131)
                                            (cast x2 : u64))
                                          131)
                                        (cast x3 : u64))
                                      131)
                                    (cast x4 : u64))
                                  131)
                                (cast x5 : u64))
                              131)
                            (cast x6 : u64))
                          131)
                        (cast x7 : u64))
                      131)
                    (cast x8 : u64))
                  131)
                (cast x9 : u64))
              131)
            (cast x10 : u64))
          131)
        (cast x11 : u64)))))

(define (main) : i64
  (let
    [seed : u64 (cast (string.>int (io.arg 1)) : u64)]
    (begin
      (io.println "{} {}" (mix3 seed 4097) (mix12 seed 4097))
      0)))