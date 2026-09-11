(import stdlib.format)

(defstruct RawOnlyWriter
  (value i64))

(define (format-writer-cell [writer : RawOnlyWriter]) : (Array RawOnlyWriter 1)
  (array writer))

(unsafe
  (define (format-write-raw [_address : i64] [_data : String]) : i64
    0))

(define (main) : i64
  (let
    [writer : RawOnlyWriter (RawOnlyWriter 0)]
    [result : format.FormatResult (format.write! writer "x")]
    0))