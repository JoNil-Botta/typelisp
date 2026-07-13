;; Exact embedded fallback must agree for text and binary includes.
(import stdlib.string)

(include-str embedded-stdlib-text "stdlib/array.tl")

(include-bin embedded-stdlib-bytes "stdlib/array.tl")

(define (main) : i64
  (let
    [length : i64 (string.string-length embedded-stdlib-text)]
    [index : i64 0]
    [same : bool (= length (array-length embedded-stdlib-bytes))]
    (begin
      (while (and same (< index length))
        (begin
          (unless
            (=
              (cast (string.string-ref embedded-stdlib-text index) : u8)
              (array-ref embedded-stdlib-bytes index))
            (set! same false))
          (set! index (+ index 1))))
      (if (and same (= length 1364))
        42
        1))))