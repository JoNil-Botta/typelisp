(import stdlib.string)

(import stdlib.text_buf)

(import stdlib.test)

; Current source uses with-arena; #801 will expose the same active-arena
; semantics under the with-arena spelling.
(define (main) : i64
  (let
    [program-buf : text_buf.TextBuf (text_buf.text-buf-append (text_buf.text-buf-empty) "scoped")]
    (with-arena
      outer
      (let
        [s : String "  outer  "]
        [outer-trimmed : String (string.string-trim (& s))]
        [outer-slice : String (string.substring-borrowed (& s) 2 5)]
        [outer-suffix : String "-append"]
        [outer-appended : String
          (string.string-append-borrowed (& outer-trimmed) (& outer-suffix))]
        [outer-number : String (string.int->string 12345)]
        [outer-expected : String "outer"]
        [outer-appended-expected : String "outer-append"]
        [outer-number-expected : String "12345"]
        (begin
          (test.assert-string-eq
            (& outer-trimmed)
            (& outer-expected)
            "outer stdlib string allocation")
          (test.assert-string-eq
            (& outer-slice)
            (& outer-expected)
            "outer stdlib substring allocation")
          (test.assert-string-eq
            (& outer-appended)
            (& outer-appended-expected)
            "outer stdlib string append allocation")
          (test.assert-string-eq
            (& outer-number)
            (& outer-number-expected)
            "outer stdlib int->string allocation")
          (with-arena
            inner
            (let
              [inner-replaced : String (string.string-replace "alpha" "ph" "ren")]
              [inner-slice : String (string.string-slice "alphabet" 2 3)]
              [inner-appended : String (string.string-append "inner" "-append")]
              [inner-concat : String (string.string-concat "inner" "-concat")]
              [inner-number : String (string.int->string -6789)]
              [inner-borrowed : String
                (string.string-append-borrowed (& inner-slice) (& inner-replaced))]
              [inner-rendered : String (text_buf.text-buf-render program-buf)]
              [inner-replaced-expected : String "alrena"]
              [inner-slice-expected : String "pha"]
              [inner-appended-expected : String "inner-append"]
              [inner-concat-expected : String "inner-concat"]
              [inner-number-expected : String "-6789"]
              [inner-borrowed-expected : String "phaalrena"]
              [inner-rendered-expected : String "scoped"]
              (begin
                (test.assert-string-eq
                  (& inner-replaced)
                  (& inner-replaced-expected)
                  "inner stdlib string allocation")
                (test.assert-string-eq
                  (& inner-slice)
                  (& inner-slice-expected)
                  "inner stdlib substring allocation")
                (test.assert-string-eq
                  (& inner-appended)
                  (& inner-appended-expected)
                  "inner stdlib string append allocation")
                (test.assert-string-eq
                  (& inner-concat)
                  (& inner-concat-expected)
                  "inner stdlib string concat allocation")
                (test.assert-string-eq
                  (& inner-number)
                  (& inner-number-expected)
                  "inner stdlib int->string allocation")
                (test.assert-string-eq
                  (& inner-borrowed)
                  (& inner-borrowed-expected)
                  "inner borrowed string append allocation")
                (test.assert-string-eq
                  (& inner-rendered)
                  (& inner-rendered-expected)
                  "inner stdlib text buffer render")
                (test.assert-i64-eq
                  (string-length outer-trimmed)
                  5
                  "outer arena value remains readable in inner arena")
                (test.assert-i64-eq
                  (string-length outer-appended)
                  12
                  "outer append value remains readable in inner arena")
                (test.assert-i64-eq
                  (string-length outer-number)
                  5
                  "outer int string value remains readable in inner arena")
                42))))))))