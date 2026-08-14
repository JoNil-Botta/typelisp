;: replace! cannot transfer ownership out of permanent global storage.
(define global-text : String
  "old")

(define (main) : i64
  (begin
    (replace! global-text "new")
    42))