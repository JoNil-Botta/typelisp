;; #9257: `stdlib.args/args-string-shared-view` must not exist.
(import stdlib.args)
(import stdlib.string)

(define (main) : i64
  (let
    [text : String "flag"]
    [alias : String (args.args-string-shared-view (& text))]
    (string.string-length (& alias))))