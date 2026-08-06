;: Macro-generated module globals obey the same ownership rule.
(defmacro (global-module) : Module
  `(begin
    (module generated.global_move)
    (define global-text : String
      "generated")))

(import (global-module) as generated)

(define (main) : i64
  (let
    [_moved : String generated.global-text]
    42))
