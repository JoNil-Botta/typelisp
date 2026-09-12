;; Generated modules cannot reconstruct a trusted handle in safe code.
(import stdlib.sync)
(import (sync.channel i64) as channel_alias)

(define (main) : i64
  (let
    [words : (__tl_dyn-array i64) (__tl_make-array i64 7)]
    [_channel : channel_alias.Channel (channel_alias.load-raw words 0)]
    0))