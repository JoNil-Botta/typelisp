;; Selected runtime leaves survive linker aliases and ordinary function values.
(extern (copy-bytes [dst : (MutPtr u8)] [src : (Ptr u8)] [count : i64]) : unit (:symbol "tl_mem_copy_fwd"))
(extern (copy-words [dst : (MutPtr i64)] [src : (Ptr i64)] [count : i64]) : unit (:symbol "tl_mem_copy8_fwd"))
(extern (fill-words [dst : (MutPtr i64)] [count : i64] [value : i64]) : unit (:symbol "tl_mem_fill8"))
(extern (find-byte [src : (Ptr u8)] [count : i64] [value : u8]) : i64 (:symbol "tl_memchr"))

(define (apply-copy
  [copy : (-> (MutPtr u8) (Ptr u8) i64 unit)]
  [dst : (MutPtr u8)]
  [src : (Ptr u8)]
  [count : i64]) : unit
  (copy dst src count))

(define (main) : i64
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 32)]
    [words : (__tl_dyn-array i64) (__tl_make-array i64 32)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (set! (array-ref bytes 0) (cast 57 : u8))
      (unsafe
        (apply-copy
          copy-bytes
          (ptr-offset (__tl_array-data bytes) 1)
          (ptr-cast (__tl_array-data bytes) : (Ptr u8))
          31))
      (unsafe
        (fill-words (__tl_array-data words) 32 1234567))
      (set! (array-ref words 0) 7654321)
      (unsafe
        (copy-words
          (ptr-offset (__tl_array-data words) 1)
          (ptr-cast (__tl_array-data words) : (Ptr i64))
          31))
      (while (< i 32)
        (begin
          (unless
            (and
              (= (array-ref bytes i) (cast 57 : u8))
              (= (array-ref words i) 7654321))
            (set! ok false))
          (set! i (+ i 1))))
      (unsafe
        (when
          (!=
            (find-byte
              (ptr-cast (__tl_array-data bytes) : (Ptr u8))
              32
              (cast 57 : u8))
            0)
          (set! ok false))
        (when
          (!=
            (find-byte
              (ptr-cast (__tl_array-data bytes) : (Ptr u8))
              32
              (cast 58 : u8))
            -1)
          (set! ok false)))
      (if ok
        42
        1))))