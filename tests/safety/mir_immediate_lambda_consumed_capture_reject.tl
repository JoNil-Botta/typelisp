;; An immediately called lambda that moves a capture out consumes it: the
;; captured value is moved into the closure and unusable afterwards.
(import stdlib.string)

(define (main) : i64
  (let
    [text : String "forty-two"]
    [length : i64
      ((lambda () : i64
          (let
            [taken : String text]
            (string.string-length taken))))]
    (+ length (string.string-length text))))