;: Result traversal respects local and pattern bindings that shadow globals.
(defenum GlobalMoveChoice
  (Text String)
  (None))

(define global-text : String
  "global")

(define (from-let) : String
  (let
    [global-text : String "local"]
    global-text))

(define (from-match [choice : GlobalMoveChoice]) : String
  (match choice
    [(Text global-text) global-text]
    [(None) "fallback"]))

(define (main) : i64
  42)