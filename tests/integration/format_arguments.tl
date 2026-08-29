(import stdlib.byte_buf)
(import stdlib.format)
(import stdlib.profile)
(import stdlib.string)
(import stdlib.text_buf)

(defstruct DisplayValue
  (text String))

(define value-evaluations : i64
  0)
(define direct-hook-calls : i64
  0)
(define fallback-hook-calls : i64
  0)

(define (make-value [text : String]) : DisplayValue
  (begin
    (set! value-evaluations (+ value-evaluations 1))
    (DisplayValue text)))

(define (to-string [_value : (& value DisplayValue)]) : String
  (begin
    (set! fallback-hook-calls (+ fallback-hook-calls 1))
    "fallback"))

(define (format-write
  [_value : (& value DisplayValue)]
  [formatter : (&mut formatter format.Formatter)]) : unit
  (begin
    (set! direct-hook-calls (+ direct-hook-calls 1))
    (format.formatter-write-string! formatter "direct")))

(define (ok? [result : format.FormatResult]) : bool
  (match result
    [(format.FormatOk) true]
    [(format.FormatErr _) false]))

(define (main) : i64
  (let
    [captured : i64 8]
    [named-value : i64 7]
    [value : DisplayValue (DisplayValue "kept")]
    [before-construction : i64 (profile.alloc-total)]
    [no-final-string-arguments
      (format.args
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:{}"
        value)]
    [construction-allocations : i64
      (- (profile.alloc-total) before-construction)]
    [arguments
      (format.args
        "{0}/{0}/{name}/{captured}"
        value
        (format.named name named-value))]
    [first : String (format.format arguments)]
    [second : String (format.format arguments)]
    [nested-arguments (format.args "<{}>" arguments)]
    [nested : String (format.format nested-arguments)]
    [literal-arguments (format.args "{}" "literal")]
    [literal : String (format.format literal-arguments)]
    [temporary-arguments (format.args "{}" (make-value "temporary"))]
    [temporary : String (format.format temporary-arguments)]
    [dynamic-arguments (format.args "{:1$}" "x" (cast 3 : i64))]
    [dynamic : String (format.format dynamic-arguments)]
    [direct-literal : String (format.format "{}" value)]
    [padded-fallback : String (format.format "{:>10}" value)]
    [bytes : byte_buf.ByteBuf (byte_buf.with-capacity 256)]
    [before-write : i64 (profile.alloc-total)]
    [bytes-result : format.FormatResult
      (format.write! bytes no-final-string-arguments)]
    [write-allocations : i64 (- (profile.alloc-total) before-write)]
    [rendered-bytes : String (byte_buf.to-string bytes)]
    [text : text_buf.TextBuf (text_buf.empty)]
    [text-result : format.FormatResult (format.writeln! text nested-arguments)]
    [rendered-text : String (text_buf.render text)]
    (if (and
      (> construction-allocations 0)
      (< construction-allocations 160)
      (= write-allocations 0)
      (= value-evaluations 1)
      (= fallback-hook-calls 1)
      (= direct-hook-calls 11)
      (string.eq first "direct/direct/7/8")
      (string.eq second first)
      (string.eq nested "<direct/direct/7/8>")
      (string.eq literal "literal")
      (string.eq temporary "direct")
      (string.eq dynamic "x  ")
      (string.eq direct-literal "direct")
      (string.eq padded-fallback "  fallback")
      (string.eq
        rendered-bytes
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:direct")
      (string.eq rendered-text "<direct/direct/7/8>\n")
      (string.eq value.text "kept")
      (= captured 8)
      (= named-value 7)
      (ok? bytes-result)
      (ok? text-result))
      42
      1)))