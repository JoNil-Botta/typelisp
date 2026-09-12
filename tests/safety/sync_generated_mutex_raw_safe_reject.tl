;; Raw mutex reconstruction is an unsafe effect in generated modules too.
(import stdlib.sync)
(import (sync.mutex i64) as mutex_alias)

(define (main) : i64
  (let
    [words : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [_mutex : mutex_alias.Mutex (mutex_alias.load-raw words 0)]
    0))