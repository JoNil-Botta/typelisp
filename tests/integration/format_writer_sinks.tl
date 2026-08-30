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
    [text : text_buf.TextBuf (text_buf.empty)]
    [text-result : format.FormatResult
      (format.write! text "{{{}}}" point-value)]
    [debug-arguments (format.args "debug-retained")]
    [before-debug-arguments : i64 (profile.alloc-total)]
    [debug-arguments-result : format.FormatResult
      (format.write! bytes "{:+#200.0X?}" debug-arguments)]
    [debug-arguments-allocations : i64
      (- (profile.alloc-total) before-debug-arguments)]
    [debug-result : format.FormatResult
      (format.write! text "|{:?}/{:#X?}/{:>6.1?}" "a\n" (cast -1 : i8) true)]
    [debug-rvalue-result : format.FormatResult
      (format.write! bytes "|{:?}" (format.args "value={:#x?}" (cast -1 : i8)))]
    [debug-nested-arguments (format.args "<{:?}>" debug-arguments)]
    [debug-nested-result : format.FormatResult
      (format.write! bytes "|{:#X?}" debug-nested-arguments)]
    [rendered-debug-text : String (text_buf.render text)]
    [rendered-debug-bytes : String (byte_buf.to-string bytes)]
    (if (and
      (ok? static-result)
      (ok? bytes-result)
      (ok? text-result)
      (ok? debug-arguments-result)
      (ok? debug-result)
      (ok? debug-rvalue-result)
      (ok? debug-nested-result)
      (= static-allocations 0)
      (= debug-arguments-allocations 0)
      (= make-count 1)
      (string.eq point-value.label "place")
      (string.eq
        (& rendered-debug-bytes)
        "static|Point(1, 2)|Point(1, 2)|Point(3, 4)\ndebug-retained|value=0xff|<debug-retained>")
      (string.eq (& rendered-debug-text) "{Point(1, 2)}|\"a\\n\"/0xFF/     t"))
      42
      1)))