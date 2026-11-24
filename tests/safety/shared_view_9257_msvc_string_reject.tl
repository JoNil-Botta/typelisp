;; #9257: `stdlib.msvc/msvc-string-shared-view` must not exist.
(import stdlib.msvc)
(import stdlib.string)

(define (main) : i64
  (let
    [text : String "link.exe"]
    [alias : String (msvc.msvc-string-shared-view (& text))]
    (string.string-length (& alias))))