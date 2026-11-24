;; Exact embedded fallback must agree for text and binary includes.
;; Disk stdlib/atomic.tl is 3300 bytes (with `;#` / `;:` doc comments);
;; embedded fallback strips doc comments while keeping exact `\n` line breaks
;; (1645 bytes, with `(defstruct AtomicI64Buffer` at byte 22 / line 23).
(import stdlib.string)

(include-str embedded-stdlib-text "stdlib/atomic.tl")

(include-bin embedded-stdlib-bytes "stdlib/atomic.tl")

(define (main) : i64
  (let
    [length : i64 (string.string-length embedded-stdlib-text)]
    [index : i64 0]
    [same : bool (= length (array-length embedded-stdlib-bytes))]
    (while (and same (< index length))
      (unless
        (=
          (cast (string.string-ref embedded-stdlib-text index) : u8)
          (array-ref embedded-stdlib-bytes index))
        (set! same false))
      (set! index (+ index 1)))
    (let
      [length-ok : bool
        (if (string.is-string-prefix-at (& embedded-stdlib-text) ";#" 0)
          (= length 3300)
          (and
            (= length 1645)
            (string.is-string-prefix-at
              (& embedded-stdlib-text)
              "(defstruct AtomicI64Buffer"
              22)))]
      (if (and same length-ok)
        42
        1))))