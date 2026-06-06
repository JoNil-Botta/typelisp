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
        [outer-suffix : String "-append"]
        [outer-appended : String
          (string-append-borrowed (& outer-trimmed) (& outer-suffix))]
        [outer-number : String (int->string 12345)]
        [outer-expected : String "outer"]
        [outer-appended-expected : String "outer-append"]
        [outer-number-expected : String "12345"]
        (begin
          (assert-string-eq
            (& outer-trimmed)
            (& outer-expected)
            "outer stdlib string allocation")
          (assert-string-eq
            (& outer-slice)
            (& outer-expected)
            "outer stdlib substring allocation")
          (assert-string-eq
            (& outer-appended)
            (& outer-appended-expected)
            "outer stdlib string append allocation")
          (assert-string-eq
            (& outer-number)
            (& outer-number-expected)
            "outer stdlib int->string allocation")
          (with-arena
            inner
            (let
              [inner-replaced : String (string-replace "alpha" "ph" "ren")]
              [inner-slice : String (string-slice "alphabet" 2 3)]
              [inner-appended : String (string-append "inner" "-append")]
              [inner-concat : String (string-concat "inner" "-concat")]
              [inner-number : String (int->string -6789)]
              [inner-borrowed : String
                (string-append-borrowed (& inner-slice) (& inner-replaced))]
              [inner-rendered : String (text-buf-render program-buf)]
              [inner-replaced-expected : String "alrena"]
              [inner-slice-expected : String "pha"]
              [inner-appended-expected : String "inner-append"]
              [inner-concat-expected : String "inner-concat"]
              [inner-number-expected : String "-6789"]
              [inner-borrowed-expected : String "phaalrena"]
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
                  (& inner-appended)
                  (& inner-appended-expected)
                  "inner stdlib string append allocation")
                (assert-string-eq
                  (& inner-concat)
                  (& inner-concat-expected)
                  "inner stdlib string concat allocation")
                (assert-string-eq
                  (& inner-number)
                  (& inner-number-expected)
                  "inner stdlib int->string allocation")
                (assert-string-eq
                  (& inner-borrowed)
                  (& inner-borrowed-expected)
                  "inner borrowed string append allocation")
                (assert-string-eq
                  (& inner-rendered)
                  (& inner-rendered-expected)
                  "inner stdlib text buffer render")
                (assert-i64-eq
                  (string-length outer-trimmed)
                  5
                  "outer arena value remains readable in inner arena")
                (assert-i64-eq
                  (string-length outer-appended)
                  12
                  "outer append value remains readable in inner arena")
                (assert-i64-eq
                  (string-length outer-number)
                  5
                  "outer int string value remains readable in inner arena")
                42))))))))