;; Copies must preserve snapshot semantics under overlap, leave surrounding
;; bytes alone, and never read outside either end of a short source range.
(import stdlib.runtime)

(extern (copy-bytes [dst : (MutPtr u8)] [src : (Ptr u8)] [n : i64]) : unit (:symbol "tl_memcpy"))
(extern (copy-fresh [dst : (MutPtr u8)] [src : (Ptr u8)] [n : i64]) : unit (:symbol "tl_memcpy_fresh"))

(define (pattern [i : i64]) : u8
  (cast (bit-and (+ (* i 37) 11) 255) : u8))

(define (copy-case!
  [dst : (MutPtr u8)]
  [src : (Ptr u8)]
  [n : i64]
  [fresh : bool]) : unit
  (if fresh
    (copy-fresh dst src n)
    (copy-bytes dst src n)))

(define (overlap-cases) : bool
  (let
    [actual : (__tl_dyn-array u8) (__tl_make-array u8 256)]
    [source : (__tl_dyn-array u8) (__tl_make-array u8 256)]
    [ok : bool true]
    [n : i64 0]
    (begin
      (while (< n 130)
        (let
          [src : i64 0]
          (begin
            (while (< src 17)
              (let
                [dst : i64 0]
                (begin
                  (while (< dst 17)
                    (let
                      [mode : i64 0]
                      (begin
                        (while (< mode 2)
                          (let
                            [i : i64 0]
                            (begin
                              (while (< i 256)
                                (begin
                                  (set! (array-ref actual i) (pattern i))
                                  (set! (array-ref source i) (pattern (+ i 1)))
                                  (set! i (+ i 1))))
                              (unsafe
                                (copy-case!
                                  (ptr-offset (__tl_array-data actual) dst)
                                  (ptr-cast
                                    (ptr-offset
                                      (if (= mode 0)
                                        (__tl_array-data actual)
                                        (__tl_array-data source))
                                      src)
                                    : (Ptr u8))
                                  n
                                  (= mode 1)))
                              (set! i 0)
                              (while (< i 256)
                                (let
                                  [expected : u8
                                    (if (and (>= i dst) (< i (+ dst n)))
                                      (pattern (+ (+ src (- i dst)) mode))
                                      (pattern i))]
                                  (begin
                                    (unless
                                      (= (array-ref actual i) expected)
                                      (set! ok false))
                                    (set! i (+ i 1)))))
                              (set! mode (+ mode 1)))))
                        (set! dst (+ dst 1)))))
                  (set! src (+ src 1)))))
            (set! n (+ n 1)))))
      ok)))

(cfg
  linux
  (define (guard-cases) : bool
    (let
      [x : i64
        (unsafe
          (syscall 9 0 12288 0 34 -1 0))]
      [y : i64
        (unsafe
          (syscall 9 0 12288 0 34 -1 0))]
      [ok : bool true]
      [n : i64 0]
      (if (or (< x 0) (< y 0))
        false
        (begin
          (unless
            (=
              (unsafe
                (syscall 10 (+ x 4096) 4096 3))
              0)
            (set! ok false))
          (unless
            (=
              (unsafe
                (syscall 10 (+ y 4096) 4096 3))
              0)
            (set! ok false))
          (while (and ok (< n 130))
            (let
              [mode : i64 0]
              (begin
                (while (< mode 8)
                  (let
                    [src : i64
                      (+
                        x
                        (if (= (bit-and mode 1) 0)
                          4096
                          (- 8192 n)))]
                    [dst : i64
                      (+
                        y
                        (if (= (bit-and mode 2) 0)
                          4096
                          (- 8192 n)))]
                    [i : i64 0]
                    (begin
                      (while (< i 4096)
                        (begin
                          (unsafe
                            (ptr-write!
                              (int->ptr
                                (cast (+ y (+ 4096 i)) : u64)
                                : (MutPtr u8))
                              (cast 165 : u8)))
                          (set! i (+ i 1))))
                      (set! i 0)
                      (while (< i n)
                        (begin
                          (unsafe
                            (ptr-write!
                              (int->ptr (cast (+ src i) : u64) : (MutPtr u8))
                              (pattern i)))
                          (set! i (+ i 1))))
                      (unsafe
                        (copy-case!
                          (int->ptr (cast dst : u64) : (MutPtr u8))
                          (int->ptr (cast src : u64) : (Ptr u8))
                          n
                          (>= mode 4)))
                      (set! i 0)
                      (while (< i 4096)
                        (let
                          [addr : i64 (+ y (+ 4096 i))]
                          [expected : u8
                            (if (and (>= addr dst) (< addr (+ dst n)))
                              (pattern (- addr dst))
                              (cast 165 : u8))]
                          (begin
                            (unless
                              (=
                                (unsafe
                                  (ptr-read
                                    (int->ptr (cast addr : u64) : (Ptr u8))))
                                expected)
                              (set! ok false))
                            (set! i (+ i 1)))))
                      (set! mode (+ mode 1)))))
                (set! n (+ n 1)))))
          ;; Even completely inaccessible pointers are valid for a zero copy.
          (unsafe
            (copy-bytes
              (int->ptr (cast x : u64) : (MutPtr u8))
              (int->ptr (cast y : u64) : (Ptr u8))
              0)
            (copy-fresh
              (int->ptr (cast x : u64) : (MutPtr u8))
              (int->ptr (cast y : u64) : (Ptr u8))
              0))
          (unless
            (=
              (unsafe
                (syscall 11 x 12288))
              0)
            (set! ok false))
          (unless
            (=
              (unsafe
                (syscall 11 y 12288))
              0)
            (set! ok false))
          ok)))))

(cfg
  windows
  (define (guard-cases) : bool
    true))

(define (main) : i64
  (if (and (overlap-cases) (guard-cases))
    42
    1))