; The first selected compact destination must bounds-trap before the later
; body expression can run (#7083).
(define (main) : i64
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (spmd-compact
      ([i : i64 0 4] [slot : i64 1])
      (= i 2)
      (begin
        (set! (array-ref out slot) i)
        (/ 1 0)
        unit))))