;; Differential byte search across every SIMD alignment and short/tail length.
(import stdlib.string)
(import stdlib.test)
(import stdlib.iterator)

(extern (find-byte [src : (Ptr u8)] [count : i64] [value : u8]) : i64 (:symbol "tl_memchr"))

(define (reference-search [src : (Ptr u8)] [count : i64] [value : u8]) : i64
  (for [i (iterator.range 0 count)]
    (when
      (=
        (unsafe
          (ptr-read (ptr-offset src i)))
        value)
      (return i)))
  -1)

(define (differential-cases) : bool
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 96)]
    [data : (MutPtr u8)
      (unsafe
        (__tl_array-data bytes))]
    (for [alignment (iterator.range 0 16)]
      (let
        [src : (Ptr u8)
          (unsafe
            (ptr-cast (ptr-offset data alignment) : (Ptr u8)))]
        (for [n (iterator.range 0 66)]
          (for [kind (iterator.range 0 6)]
            (let
              [value : u8
                (cast
                  (match kind
                    [0 0]
                    [1 1]
                    [2 127]
                    [3 128]
                    [4 254]
                    [_ 255])
                  : u8)]
              [other : u8 (bit-xor value (cast 128 : u8))]
              (for [i (iterator.range 0 96)]
                (set! (array-ref bytes i) other))
              (for [hit (iterator.range 0 (+ n 1))]
                ;; Two adjacent hits must still return the first. A hit at n
                ;; is outside the range and must report a miss.
                (set! (array-ref bytes (+ alignment hit)) value)
                (set! (array-ref bytes (+ alignment (+ hit 1))) value)
                (unless
                  (= (find-byte src n value) (reference-search src n value))
                  (return false))
                (set! (array-ref bytes (+ alignment hit)) other)
                (set! (array-ref bytes (+ alignment (+ hit 1))) other))))
          ;; All 256 byte values, with varied data and repeated matches.
          (for [i (iterator.range 0 96)]
            (set! (array-ref bytes i) (cast (bit-and (* i 37) 255) : u8)))
          (for [value (iterator.range 0 256)]
            (unless
              (=
                (find-byte src n (cast value : u8))
                (reference-search src n (cast value : u8)))
              (return false))))))
    ;; Neither empty nor negative lengths may dereference the pointer.
    (let
      [null : (Ptr u8)
        (unsafe
          (int->ptr (cast 0 : u64) : (Ptr u8)))]
      (and
        (= (find-byte null 0 (cast 0 : u8)) -1)
        (= (find-byte null -1 (cast 255 : u8)) -1)
        (= (find-byte null -9223372036854775808 (cast 1 : u8)) -1)))))

;; Linux's inaccessible neighbors catch reads before the start or past the
;; supplied end. The cross-platform differential cases above cover both ABIs.
(cfg
  linux
  (define (guard-page-cases) : bool
    (let
      [base : i64
        (unsafe
          (syscall 9 0 12288 0 34 -1 0))]
      [ok : bool true]
      (when (< base 0) (return false))
      (if (=
        (unsafe
          (syscall 10 (+ base 4096) 4096 3))
        0)
        (for [n (iterator.range 0 130)]
          (for [side (iterator.range 0 2)]
            (let
              [data : (MutPtr u8)
                (unsafe
                  (int->ptr
                    (cast
                      (+
                        base
                        (if (= side 0)
                          4096
                          (- 8192 n)))
                      : u64)
                    : (MutPtr u8)))]
              [src : (Ptr u8)
                (unsafe
                  (ptr-cast data : (Ptr u8)))]
              (for [i (iterator.range 0 n)]
                (unsafe
                  (ptr-write! (ptr-offset data i) (cast 128 : u8))))
              (unless (= (find-byte src n (cast 0 : u8)) -1) (set! ok false))
              (when
                (> n 0)
                (unsafe
                  (ptr-write! (ptr-offset data (- n 1)) (cast 0 : u8)))
                (unless
                  (= (find-byte src n (cast 0 : u8)) (- n 1))
                  (set! ok false))))))
        (set! ok false))
      (unless
        (=
          (unsafe
            (syscall 11 base 12288))
          0)
        (set! ok false))
      ok)))

(define (public-string-cases) : bool
  (let
    [text : String "0123456789abcdef0123456789abcdef--end"]
    (and
      (= (string.index-of-byte (& text) 1 (cast 48 : u8)) 16)
      (= (string.index-of-byte (& text) 16 (cast 48 : u8)) 16)
      (= (string.index-of-byte (& text) 32 (cast 100 : u8)) 36)
      (= (string.index-of-byte (& text) 37 (cast 100 : u8)) -1)
      (= (string.index-of-byte (& text) -1 (cast 48 : u8)) -1)
      (string.contains-char (& text) 'e')
      (not (string.contains-char (& text) 'z')))))

(test
  runtime-memchr
  (test.assert-true
    (differential-cases)
    "byte oracle, alignments, lengths and hits")
  (test.assert-true
    (public-string-cases)
    "public string search offsets and misses")
  (cfg
    linux
    (test.assert-true
      (guard-page-cases)
      "search never crosses either guard page")))

(define (main) : i64
  (if (and
    (differential-cases)
    (public-string-cases)
    (cfg linux (guard-page-cases) true))
    42
    1))