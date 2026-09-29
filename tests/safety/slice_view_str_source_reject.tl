;; A `str` is text, not a Slice: only a bytes view may read its bytes.
(define (main) : i64
  (let
    [text : String "abc"]
    [view : (& text (Slice u8)) (slice-view (& text) 0 3)]
    (array-length view)))