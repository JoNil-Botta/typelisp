(import stdlib.process)

; The returned string is tied to the info, not to an unrelated caller lifetime.
(define (escape [outer : (& outer str)]) : (& outer str)
  (let
    [info : process.ProcessMaybeStringInfo
      (process.maybe-string-info (process.stdin-string "local"))]
    (process.maybe-string-info-value info)))

(define (main) : i64
  (let
    [text : String "outer"]
    (string-length (escape (& text)))))