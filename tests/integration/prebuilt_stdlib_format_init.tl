;; stdlib.format reads globals that the prebuilt module initializes at
;; startup; formatting must see them initialized before main runs.
(import stdlib.format)
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (let
    [text : String (format.format (format.args "{}-{}" 40 2))]
    (io.print "{}\n" text)
    (if (string.eq text "40-2")
      42
      1)))