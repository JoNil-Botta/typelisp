(import "stdlib/test.tl")
(import "stdlib/time.tl")

(define (assert-time-result-error-shape) : unit
  (let
    [expected : String "time unavailable"]
    (match (ErrTimeMs (TimeUnavailable "time unavailable"))
      [(OkTimeMs _) (panic "expected time error")]
      [(ErrTimeMs err)
        (let
          [actual : String (time-error-message err)]
          (assert-string-eq
            (& actual)
            (& expected)
            "time error message is exposed"))])))

(define (assert-unix-time-range [result : ResultTimeMs]) : unit
  (match result
    [(OkTimeMs ms)
      (begin
        (assert-true (> ms 946684800000) "Unix time is after 2000-01-01 UTC")
        (assert-true (< ms 4102444800000) "Unix time is before 2100-01-01 UTC"))]
    [(ErrTimeMs err) (panic (time-error-message err))]))

(define (assert-monotonic-nonnegative [result : ResultTimeMs]) : i64
  (match result
    [(OkTimeMs ms)
      (begin
        (assert-true (>= ms 0) "monotonic time is non-negative")
        ms)]
    [(ErrTimeMs err) (panic (time-error-message err))]))

(define (main) : i64
  (begin
    (assert-time-result-error-shape)
    (assert-unix-time-range (time-unix-ms))
    (let
      [first : i64 (assert-monotonic-nonnegative (time-monotonic-ms))]
      [second : i64 (assert-monotonic-nonnegative (time-monotonic-ms))]
      (begin
        (assert-true (>= second first) "monotonic time does not go backwards")
        (assert-i64-eq (time-ms-or (OkTimeMs 123) 0) 123 "time-ms-or ok")
        (assert-i64-eq
          (time-ms-or (ErrTimeMs (TimeUnavailable "x")) 7)
          7
          "time-ms-or fallback")
        42))))