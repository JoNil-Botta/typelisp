(import stdlib.string)
(import stdlib.format)

(define (main) : i64
  (let
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 12)]
    [dst : (MutPtr u8)
      (unsafe
        (__tl_array-data slots))]
    [raw : String "raw"]
    (begin
      ;; Each source is live; disjoint destination spans fit the fresh 12-byte
      ;; allocation. These explicit unsafe calls retain the supported API.
      (unsafe
        (string.str-copy-bytes-into (string-data (& raw)) dst 0 3)
        (string.str-copy-owned-bytes-into "own" dst 3 3)
        (string.str-copy-borrowed-bytes-into "bor" dst 6 3)
        (format.format-write-fill! dst 9 1 '!')
        (format.format-copy-rendered-range! "end" 1 dst 10 2))
      (let
        [copied : String
          (unsafe
            (string-from-bytes (ptr-cast dst : (Ptr u8)) 12))]
        [part : String
          (unsafe
            (string.substring-copy-checked "0123" 1 2))]
        (if (and (string.eq copied "rawownbor!nd") (string.eq part "12"))
          42
          1)))))