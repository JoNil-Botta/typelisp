(import stdlib.vector)
(import stdlib.io)
(import stdlib.string)

(define cleanup-count : i64
  0)

(define (drop-value [_value : i64]) : unit
  (set! cleanup-count (+ cleanup-count 1)))

(defstruct Token
  (:cleanup cleanup-token)
  (value i64 (:cleanup drop-value)))

(import (vector.vector Token) as tokens)

(define (main) : i64
  (let
    [mode : i64 (string.>int (io.arg 1))]
    (begin
      (with
        ([items (tokens.new) tokens.cleanup-vec])
        (begin
          (if (or (= mode 0) (= mode 3))
            (tokens.push-ref! (&mut items) (Token 10))
            (set!
              items.len
              (if (= mode 1)
                1
                -1)))
          (when (= mode 3) (set! items.state.live (__tl_make-array bool 0)))
          (tokens.set-ref! (&mut items) 0 (Token 42))))
      (if (= cleanup-count 2)
        42
        1))))