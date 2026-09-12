;; A safe caller cannot reinterpret an unrelated scalar as an owned String.
(import stdlib.string)

(define (main) : i64
  (let
    [bad : String (__tl-compiler-owned-shared-view-dyn-ref-as 0 String)]
    (string-length (& bad))))