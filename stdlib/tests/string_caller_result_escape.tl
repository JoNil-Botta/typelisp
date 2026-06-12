(import "stdlib/string_caller_result.tl")

; Must fail: `string-replace-result` may return a borrowed no-match result tied
; to `inner`, not `outer`.
(define (main [outer : String] [old : String] [new : String]) : (StringReplaceResult
    outer
    old
    new)
  (with-arena
    inner
    (let
      [text : String "inner"]
      (string-replace-result (& text) (& old) (& new)))))