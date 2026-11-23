;; Byte-wise load combining must treat a direct def of an address-taken local
;; as a memory write barrier so an earlier byte load cannot sink past `set!`.
;; Expected exit 41 at --opt-level 0, 1 and 2.
(define (read-split [y : i64]) : i64
  (let
    [x : i64 y]
    [p : (Ptr u8)
      (unsafe
        (ptr-cast (ptr-addr-of x) : (Ptr u8)))]
    [b0 : u64
      (cast
        (unsafe
          (ptr-read (ptr-offset p 0)))
        : u64)]
    (set! x (+ y 1))
    (let
      [b1 : u64
        (cast
          (unsafe
            (ptr-read (ptr-offset p 1)))
          : u64)]
      [b2 : u64
        (cast
          (unsafe
            (ptr-read (ptr-offset p 2)))
          : u64)]
      [b3 : u64
        (cast
          (unsafe
            (ptr-read (ptr-offset p 3)))
          : u64)]
      [b4 : u64
        (cast
          (unsafe
            (ptr-read (ptr-offset p 4)))
          : u64)]
      [b5 : u64
        (cast
          (unsafe
            (ptr-read (ptr-offset p 5)))
          : u64)]
      [b6 : u64
        (cast
          (unsafe
            (ptr-read (ptr-offset p 6)))
          : u64)]
      [b7 : u64
        (cast
          (unsafe
            (ptr-read (ptr-offset p 7)))
          : u64)]
      [w : u64
        (bit-or
          b0
          (bit-or
            (shl b1 8)
            (bit-or
              (shl b2 16)
              (bit-or
                (shl b3 24)
                (bit-or
                  (shl b4 32)
                  (bit-or (shl b5 40) (bit-or (shl b6 48) (shl b7 56))))))))]
      (cast (bit-and w 255) : i64))))

(define (main) : i64
  (read-split 41))