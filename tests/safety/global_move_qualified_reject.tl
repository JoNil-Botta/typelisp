;: Imported globals obey the same ownership rule after alias resolution.
(import global_move_qualified_helper as helper)

(define (main) : i64
  (let
    [_moved : String helper.global-text]
    42))