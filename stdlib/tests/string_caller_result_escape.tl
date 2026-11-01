(import stdlib.string_caller_result)

; Must fail: `string-replace-result` may return a borrowed no-match result tied
; to `inner`, not `outer`.
(define (main
  [outer : (& outer String)]
  [old : (& old str)]
  [new : (& new str)]) : (string_caller_result.StringReplaceResult
    outer
    old
    new)
  (with-arena
    inner
    (let
      [text : String "inner"]
      (string_caller_result.string-replace-result (& text) old new))))