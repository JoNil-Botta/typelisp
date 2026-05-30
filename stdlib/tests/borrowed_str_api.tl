;; Check-only fixture for borrowed-str-capable stdlib gates (#1557).
(define (borrowed-str-length [s : (& text str)]) : i64
  (string-length s))

(define (borrowed-str-use [text : String]) : i64
  (let
    [view : (& text str) (& text)]
    (borrowed-str-length view)))