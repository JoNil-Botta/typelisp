;; #9257: `text_buf.copy-chunk-into` requires `unsafe` because it writes through
;; a raw `(MutPtr u8)` destination pointer.
(import stdlib.text_buf)

(define (main) : i64
  (let
    [s : String "hello"]
    [dst : (MutPtr u8) (ptr-null : (MutPtr u8))]
    (text_buf.copy-chunk-into (& s) dst 0)
    0))