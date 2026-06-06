(import "stdlib/string.tl")

(import "stdlib/text_buf.tl")

(import "stdlib/test.tl")

; Current source uses with-arena; #801 will expose the same active-arena
; semantics under the with-arena spelling.
(define (main) : i64
  (let
    [program-buf : TextBuf (text-buf-append (text-buf-empty) "scoped")]
    (with-arena
      outer
      (let
        [s : String "  outer  "]
        [outer-trimmed : String (string-trim (& s))]
        [outer-slice : String (substring-borrowed (& s) 2 5)]
        [outer-expected : String "outer"]
        (begin
          (assert-string-eq
            (& outer-trimmed)
            (& outer-expected)
            "outer stdlib string allocation")
          (assert-string-eq
            (& outer-slice)
            (& outer-expected)
            "outer stdlib substring allocation")
          (with-arena
            inner
            (let
              [inner-replaced : String (string-replace "alpha" "ph" "ren")]
              [inner-slice : String (string-slice "alphabet" 2 3)]
              [inner-rendered : String (text-buf-render program-buf)]
              [inner-replaced-expected : String "alrena"]
              [inner-slice-expected : String "pha"]
              [inner-rendered-expected : String "scoped"]
              (begin
                (assert-string-eq
                  (& inner-replaced)
                  (& inner-replaced-expected)
                  "inner stdlib string allocation")
                (assert-string-eq
                  (& inner-slice)
                  (& inner-slice-expected)
                  "inner stdlib substring allocation")
                (assert-string-eq
                  (& inner-rendered)
                  (& inner-rendered-expected)
                  "inner stdlib text buffer render")
                (assert-i64-eq
                  (string-length outer-trimmed)
                  5
                  "outer arena value remains readable in inner arena")
                42))))))))