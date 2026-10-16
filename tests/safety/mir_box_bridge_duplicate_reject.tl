;; The bootstrap bridge `__tl-box-place` is `deref`: reading a move-only box
;; content by value moves it, so a second read is a use of a moved box rather
;; than a second owner of the same string.
(import stdlib.string)

(define (main) : i64
  (let
    [boxed : (Box String) (box (string.copy "abc"))]
    [first : String (__tl-box-place boxed)]
    [second : String (__tl-box-place boxed)]
    (+ (string.string-length first) (string.string-length second))))