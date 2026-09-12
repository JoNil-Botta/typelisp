;; Borrowed arrays may be inspected only through an explicit, typed unsafe
;; pointer boundary; no borrowed owner is returned to safe code.
(define (borrowed-i64-data [items : (& items (__tl_dyn-array i64))]) : (Ptr i64)
  (unsafe
    (ptr-cast
      (__tl_array-data
        (ptr-read
          (ptr-cast
            (__tl_array-data (array items))
            : (Ptr (__tl_dyn-array i64)))))
      : (Ptr i64))))

(define (borrowed-u8-data [items : (& items (__tl_dyn-array u8))]) : (Ptr u8)
  (unsafe
    (ptr-cast
      (__tl_array-data
        (ptr-read
          (ptr-cast (__tl_array-data (array items)) : (Ptr (__tl_dyn-array u8)))))
      : (Ptr u8))))

(define (main) : i64
  (let
    [words : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [octets : (__tl_dyn-array u8) (__tl_make-array u8 1)]
    (begin
      (set! (array-ref words 0) 20)
      (set! (array-ref octets 0) (cast 22 : u8))
      (if (and
        (=
          (unsafe
            (ptr-read (borrowed-i64-data (& words))))
          20)
        (=
          (unsafe
            (ptr-read (borrowed-u8-data (& octets))))
          (cast 22 : u8)))
        42
        1))))