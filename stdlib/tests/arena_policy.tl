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
        [outer-trimmed : String (string-trim "  outer  ")]
        (begin
          (assert-true
            (string-eq outer-trimmed "outer")
            "outer stdlib string allocation")
          (with-arena
            inner
            (let
              [inner-replaced : String (string-replace "alpha" "ph" "ren")]
              [inner-rendered : String (text-buf-render program-buf)]
              (begin
                (assert-true
                  (string-eq inner-replaced "alrena")
                  "inner stdlib string allocation")
                (assert-true
                  (string-eq inner-rendered "scoped")
                  "inner stdlib text buffer render")
                (assert-i64-eq
                  (string-length outer-trimmed)
                  5
                  "outer arena value remains readable in inner arena")
                42))))))))