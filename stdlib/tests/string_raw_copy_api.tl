(import stdlib.string)

(define (main) : i64
  (let
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 9)]
    [text : String "raw"]
    [dst : (MutPtr u8)
      (unsafe
        (__tl_array-data slots))]
    ;; The three live, disjoint destination ranges fit the nine-byte allocation.
    (unsafe
      (string.str-copy-bytes-into (string-data (& text)) dst 0 3)
      (string.str-copy-owned-bytes-into "own" dst 3 3)
      (string.str-copy-borrowed-bytes-into "bor" dst 6 3))
    (let
      [copied : String
        (unsafe
          (string-from-bytes (ptr-cast dst : (Ptr u8)) 9))]
      (if (string.eq (& copied) "rawownbor")
        42
        1))))