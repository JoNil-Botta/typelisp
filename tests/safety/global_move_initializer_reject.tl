;: A second global cannot alias the owning storage of an earlier global.
(import stdlib.string)

(define global-source : String
  "owned")

(define global-alias : String
  global-source)

(define (main) : i64
  (string.string-length global-alias))
