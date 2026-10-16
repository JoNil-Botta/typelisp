(import stdlib.vector)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

(define (record-cleanup [_value : i64]) : unit
  unit)

(defstruct Token
  (:cleanup cleanup-token)
  (value i64 (:cleanup record-cleanup)))

(import (vector.vector Token) as tokens)

(define (main) : i64
  (let
    [kind : String
      (byte_buf.to-string (io.stdin-read-buffer (io.stdin-read-line)))]
    (with
      ([v (tokens.new) tokens.cleanup-vec])
      (tokens.push-ref! (&mut v) (Token 1))
      (cond
        [(string.eq (& kind) "negative") (set! v.len -1)]
        [(string.eq (& kind) "maximum") (set! v.len 9223372036854775807)]
        [(string.eq (& kind) "slots")
          (set! v.len 2)
          (set! v.state.live (__tl_make-array bool 2))]
        [(string.eq (& kind) "live")
          (set! v.state.live (__tl_make-array bool 0))]
        [else unit])
      (tokens.set-ref! (&mut v) 0 (Token 42))
      42)))