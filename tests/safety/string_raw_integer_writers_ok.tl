;; The two raw integer writers may touch only their proven destination spans.
;; Neighboring sentinels catch either underwrite or overwrite (#8915).
(import stdlib.string)

(define (main) : i64
  (let
    [slots : (__tl_dyn-array u8) (__tl_make-array u8 8)]
    [index : i64 0]
    [dst : (MutPtr u8)
      (unsafe
        (__tl_array-data slots))]
    (begin
      (while (< index 8)
        (set! (array-ref slots index) (cast 126 : u8))
        (set! index (+ index 1)))
      ;; Byte span [1,2) and digit span [3,5) both fit the live allocation.
      (unsafe
        (string.int->string-write-byte! dst 1 65)
        (string.int->string-write-negative-digits! dst 3 -42 2))
      (if (and
        (= (array-ref slots 0) (cast 126 : u8))
        (= (array-ref slots 1) (cast 65 : u8))
        (= (array-ref slots 2) (cast 126 : u8))
        (= (array-ref slots 3) (cast 52 : u8))
        (= (array-ref slots 4) (cast 50 : u8))
        (= (array-ref slots 5) (cast 126 : u8))
        (= (array-ref slots 6) (cast 126 : u8))
        (= (array-ref slots 7) (cast 126 : u8)))
        42
        1))))