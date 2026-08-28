(import format_owner_point as point)
(import stdlib.byte_buf)
(import stdlib.format)
(import stdlib.profile)
(import stdlib.string)
(import stdlib.text_buf)

(define make-count : i64
  0)

(define (make-point-once) : point.Point
  (begin
    (set! make-count (+ make-count 1))
    (point.make "temporary" 3 4)))

(define (ok? [result : format.FormatResult]) : bool
  (match result
    [(format.FormatOk) true]
    [(format.FormatErr _) false]))

(define (main) : i64
  (let
    [point-value : point.Point (point.make "place" 1 2)]
    [bytes : byte_buf.ByteBuf (byte_buf.with-capacity 128)]
    [before-static : i64 (profile.alloc-total)]
    [static-result : format.FormatResult (format.write! bytes "static")]
    [static-allocations : i64 (- (profile.alloc-total) before-static)]
    [bytes-result : format.FormatResult
      (format.writeln! bytes "|{0}|{0}|{1}" point-value (make-point-once))]
    [rendered-bytes : String (byte_buf.to-string bytes)]
    [text : text_buf.TextBuf (text_buf.empty)]
    [text-result : format.FormatResult
      (format.write! text "{{{}}}" point-value)]
    [rendered-text : String (text_buf.render text)]
    (if (and
      (ok? static-result)
      (ok? bytes-result)
      (ok? text-result)
      (= static-allocations 0)
      (= make-count 1)
      (string.eq point-value.label "place")
      (string.eq
        (& rendered-bytes)
        "static|Point(1, 2)|Point(1, 2)|Point(3, 4)\n")
      (string.eq (& rendered-text) "{Point(1, 2)}"))
      42
      1)))