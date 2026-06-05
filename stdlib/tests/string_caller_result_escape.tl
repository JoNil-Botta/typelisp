(import "stdlib/string_caller_result.tl")

; Must fail: the borrowed no-match result is tied to `inner`, not `outer`.
(define (main [outer : String] [old : String] [new : String]) : (StringReplaceResult
  outer
  old
  new)
  (with-arena
    inner
    (let
      [text : String "inner"]
      (string-replace-borrowed-result (& text) (& old) (& new)))))