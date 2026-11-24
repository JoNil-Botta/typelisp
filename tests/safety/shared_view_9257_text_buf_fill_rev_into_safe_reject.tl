;; #9257: `text_buf.fill-rev-into` requires `unsafe` because it writes through a
;; raw `(MutPtr u8)` destination pointer.
(import stdlib.text_buf)

(define (main) : i64
  (let
    [buf : text_buf.TextBuf (text_buf.empty)]
    [dst : (MutPtr u8) (ptr-null : (MutPtr u8))]
    (text_buf.fill-rev-into buf.chunks dst 0)
    0))