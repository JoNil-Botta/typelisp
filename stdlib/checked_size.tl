;# Checked non-negative storage sizes, without collection dependencies.
;#
;# Invalid operands or signed-i64 overflow abort with status 134 and
;# `size: arithmetic overflow` before arithmetic or allocation. Callers retain
;# responsibility for the live-prefix and ownership invariants of their storage.
;: Existing runtime abort ABI; importing a collection here would create cycles.
(extern (size-abort [message : String]) : never (:symbol "tl_abort_string"))

;: Add non-negative sizes after proving the sum is representable.
(define (add [left : i64] [right : i64]) : i64
  (if (or (< left 0) (< right 0) (> left (- 9223372036854775807 right)))
    (size-abort "size: arithmetic overflow\n")
    (+ left right)))

;: Return a count whose element-byte product is representable.
;:
;: Zero-sized elements accept every non-negative count. The allocation primitive
;: retains its independent byte-size check; this boundary runs before callers
;: allocate or mutate storage derived from a new count.
(define (elements [count : i64] [element-bytes : i64]) : i64
  (if (or
    (< count 0)
    (< element-bytes 0)
    (and (> element-bytes 0) (> count (/ 9223372036854775807 element-bytes))))
    (size-abort "size: arithmetic overflow\n")
    count))