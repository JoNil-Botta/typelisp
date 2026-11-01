;# RFC 5280 UTC certificate times, independent of locale and host timezone.
;#
;# ```typelisp
;# (import stdlib.x509_time as time)
;# (import stdlib.byte_buf)
;# (define (main) : i64
;#   (let [text : String "700101000000Z"]
;#     (match (time.parse (byte_buf.str-as-bytes (& text)) 23 0)
;#       [(time.TimeOk instant) (if (= instant.epoch-ms 0) 42 1)]
;#       [(time.TimeErr _) 1])))
;# ```
(import stdlib.byte_buf)

;: Time failure categories independent of DER framing.
(defenum ErrorKind
  (InvalidOffset)
  (InvalidTime))

;: Failure at an original-source byte offset; contains no input bytes.
(defstruct Error
  (kind ErrorKind)
  (offset i64))

;: Parsed calendar fields and signed milliseconds since 1970-01-01 UTC.
(defstruct Instant
  (year i64)
  (month i64)
  (day i64)
  (hour i64)
  (minute i64)
  (second i64)
  (epoch-ms i64))

;: Complete time or a byte-located failure; no partial instant is returned.
(defenum TimeResult
  (TimeOk Instant)
  (TimeErr Error))

;: Gregorian leap-year predicate over validated positive years.
(define (leap-year? [year : i64]) : bool
  (and (= (% year 4) 0) (or (!= (% year 100) 0) (= (% year 400) 0))))

;: Days in a validated Gregorian month.
(define (month-days [year : i64] [month : i64]) : i64
  (cond
    [(= month 2)
      (if (leap-year? year)
        29
        28)]
    [(or (= month 4) (= month 6) (= month 9) (= month 11)) 30]
    [else 31]))

;: Days before January 1, counted from 0001-01-01.
(define (year-days [year : i64]) : i64
  (let
    [previous : i64 (- year 1)]
    (+
      (- (+ (* previous 365) (/ previous 4)) (/ previous 100))
      (/ previous 400))))

;: Parse exactly YYMMDDHHMMSSZ (tag 23) or YYYYMMDDHHMMSSZ (tag 24).
;: `source-offset` locates this borrowed content in the enclosing DER input.
;: Years 0001..9999 fit signed milliseconds by construction (less than 2^49).
(define (parse [input : (& input bytes)] [tag : i64] [source-offset : i64]) : TimeResult
  (let
    [length : i64 (byte_buf.bytes-length input)]
    [year-width : i64
      (if (= tag 23)
        2
        4)]
    [fields : (Array i64 6) (make-array i64 6)]
    [position : i64 0]
    [field : i64 0]
    (when
      (or (< source-offset 0) (> source-offset (- 9223372036854775807 length)))
      (return (TimeErr (Error (InvalidOffset) 0))))
    (when
      (or (and (!= tag 23) (!= tag 24)) (!= length (+ year-width 11)))
      (return (TimeErr (Error (InvalidTime) source-offset))))
    (while (< field 6)
      (let
        [width : i64
          (if (= field 0)
            year-width
            2)]
        [index : i64 0]
        [value : i64 0]
        (while (< index width)
          (let
            [code : i64 (cast (byte_buf.bytes-ref input position) : i64)]
            (when
              (or (< code 48) (> code 57))
              (return
                (TimeErr (Error (InvalidTime) (+ source-offset position)))))
            (set! value (+ (* value 10) (- code 48))))
          (set! position (+ position 1))
          (set! index (+ index 1)))
        (set! (array-ref fields field) value))
      (set! field (+ field 1)))
    (when
      (!= (byte_buf.bytes-ref input position) (cast 90 : u8))
      (return (TimeErr (Error (InvalidTime) (+ source-offset position)))))
    (let
      [year : i64 (array-ref fields 0)]
      [month : i64 (array-ref fields 1)]
      [day : i64 (array-ref fields 2)]
      [hour : i64 (array-ref fields 3)]
      [minute : i64 (array-ref fields 4)]
      [second : i64 (array-ref fields 5)]
      (when
        (= tag 23)
        (set!
          year
          (+
            year
            (if (>= year 50)
              1900
              2000))))
      (when (= year 0) (return (TimeErr (Error (InvalidTime) source-offset))))
      (when
        (or (< month 1) (> month 12))
        (return (TimeErr (Error (InvalidTime) (+ source-offset year-width)))))
      (when
        (or (< day 1) (> day (month-days year month)))
        (return
          (TimeErr (Error (InvalidTime) (+ source-offset (+ year-width 2))))))
      (when
        (> hour 23)
        (return
          (TimeErr (Error (InvalidTime) (+ source-offset (+ year-width 4))))))
      (when
        (> minute 59)
        (return
          (TimeErr (Error (InvalidTime) (+ source-offset (+ year-width 6))))))
      (when
        (> second 59)
        (return
          (TimeErr (Error (InvalidTime) (+ source-offset (+ year-width 8))))))
      (let
        [days : i64 (- (year-days year) (year-days 1970))]
        [index : i64 1]
        (while (< index month)
          (set! days (+ days (month-days year index)))
          (set! index (+ index 1)))
        (set! days (+ days (- day 1)))
        (TimeOk
          (Instant
            year
            month
            day
            hour
            minute
            second
            (*
              (+ (+ (* days 86400) (* hour 3600)) (+ (* minute 60) second))
              1000)))))))