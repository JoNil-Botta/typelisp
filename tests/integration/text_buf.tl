;; text_buf.tl - Integration driver for the selfhost text buffer module.
(import "text_buf_core.tl")

(define (check-string [got : String] [want : String] [message : String]) : unit
  (if (string-eq got want)
    unit
    (panic message)))

(define (main) : i64
  (begin
    (check-string
      (text-buf-render (text-buf-empty))
      ""
      "text-buf empty render failed")
    (let
      [buf : TextBuf
        (text-buf-append
          (text-buf-append (text-buf-append (text-buf-empty) "alpha") " ")
          "beta")]
      (check-string
        (text-buf-render buf)
        "alpha beta"
        "text-buf multi-chunk order failed"))
    (let
      [buf : TextBuf
        (text-buf-append
          (text-buf-append (text-buf-append (text-buf-empty) "ha") "ha")
          "ha")]
      (check-string
        (text-buf-render buf)
        "hahaha"
        "text-buf repeated append failed"))
    (let
      [left : TextBuf
        (text-buf-append (text-buf-append (text-buf-empty) "left") "-")]
      [right : TextBuf
        (text-buf-append (text-buf-append (text-buf-empty) "right") "\n")]
      [joined : TextBuf (text-buf-append-buffer left right)]
      (begin
        (check-string
          (text-buf-render joined)
          "left-right\n"
          "text-buf buffer append failed")
        (print-string (text-buf-render joined))))
    0))