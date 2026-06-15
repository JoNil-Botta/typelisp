(import stdlib.test)

(import stdlib.time)

(define (assert-time-result-error-shape) : unit
  (let
    [expected : String "time unavailable"]
    (match (time.ErrTimeMs (time.TimeUnavailable "time unavailable"))
      [(time.OkTimeMs _) (panic "expected time error")]
      [(time.ErrTimeMs err)
        (let
          [actual : String (time.time-error-message err)]
          (test.assert-string-eq
            (& actual)
            (& expected)
            "time error message is exposed"))])))

(define (assert-unix-time-range [result : time.ResultTimeMs]) : unit
  (match result
    [(time.OkTimeMs ms)
      (begin
        (test.assert-true (> ms 946684800000) "Unix time is after 2000-01-01 UTC")
        (test.assert-true (< ms 4102444800000) "Unix time is before 2100-01-01 UTC"))]
    [(time.ErrTimeMs err) (panic (time.time-error-message err))]))

(define (assert-monotonic-nonnegative [result : time.ResultTimeMs]) : i64
  (match result
    [(time.OkTimeMs ms)
      (begin
        (test.assert-true (>= ms 0) "monotonic time is non-negative")
        ms)]
    [(time.ErrTimeMs err) (panic (time.time-error-message err))]))

(define (main) : i64
  (begin
    (assert-time-result-error-shape)
    (assert-unix-time-range (time.time-unix-ms))
    (let
      [first : i64 (assert-monotonic-nonnegative (time.time-monotonic-ms))]
      [second : i64 (assert-monotonic-nonnegative (time.time-monotonic-ms))]
      (begin
        (test.assert-true (>= second first) "monotonic time does not go backwards")
        (test.assert-i64-eq (time.time-ms-or (time.OkTimeMs 123) 0) 123 "time-ms-or ok")
        (test.assert-i64-eq
          (time.time-ms-or (time.ErrTimeMs (time.TimeUnavailable "x")) 7)
          7
          "time-ms-or fallback")
        42))))