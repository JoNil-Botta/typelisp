(import stdlib.time)

(define (unit-ok? [result : time.ResultTimeUnit]) : bool
  (match result
    [(OkTimeUnit) true]
    [(ErrTimeUnit _) false]))

(define (negative-error? [result : time.ResultTimeUnit]) : bool
  (match result
    [(OkTimeUnit) false]
    [(ErrTimeUnit err)
      (= (time.error-message err) "time: sleep duration must be nonnegative")]))

(define (main) : i64
  (let
    [before : i64 (time.ms-or (time.monotonic-ms) -1)]
    [slept : bool (unit-ok? (time.sleep-ms 20))]
    [after : i64 (time.ms-or (time.monotonic-ms) -1)]
    (if (and
      (negative-error? (time.sleep-ms -1))
      (unit-ok? (time.sleep-ms 0))
      slept
      (>= (- after before) 1))
      42
      1)))