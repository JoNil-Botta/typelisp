;: The owned-view idiom reads a reference's first word back out of a one-element
;: array; for a slice reference (two words) that word is the data pointer, so
;: lowering keeps the read instead of casting the reference (#8449).
(define (slice-data [s : (& s (Slice i64))]) : u64
  (unsafe
    (ptr-read (ptr-cast (__tl_array-data (array s)) : (Ptr u64)))))

(define (main) : i64
  (let
    [cells : (Array i64 3) (array 3 4 5)]
    (unsafe
      (ptr-read (int->ptr (slice-data (slice-view cells 0 3)) : (Ptr i64))))))