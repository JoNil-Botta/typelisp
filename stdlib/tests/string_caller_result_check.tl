(import stdlib.string_caller_result)

(define (string-caller-result-borrowed-check
  [text : (& text str)]
  [old : (& old str)]
  [new : (& replacement str)]) : (string_caller_result.StringReplaceResult text old replacement)
  (string_caller_result.string-replace-borrowed-result text old new))

(define (string-caller-result-owned-check
  [text : (& text str)]
  [old : (& old str)]
  [new : (& replacement str)]
  [owned : String]) : (string_caller_result.StringReplaceResult text old replacement)
  (string_caller_result.string-replace-owned-result-like text old new owned))

(define (string-caller-result-render-check
  [result : (string_caller_result.StringReplaceResult text old replacement)]) : String
  (string_caller_result.string-replace-result-string result))

(define (string-caller-result-helper-check
  [text : (& text str)]
  [old : (& old str)]
  [new : (& replacement str)]) : (string_caller_result.StringReplaceResult text old replacement)
  (string_caller_result.string-replace-result text old new))

(define (string-caller-result-helper-borrowed-flag-check
  [text : (& text str)]
  [old : (& old str)]
  [new : (& replacement str)]) : bool
  (string_caller_result.string-replace-result-borrowed? (string_caller_result.string-replace-result text old new)))

(define (string-caller-result-helper-owned-render-check
  [text : (& text str)]
  [old : (& old str)]
  [new : (& replacement str)]) : String
  (string_caller_result.string-replace-result-string (string_caller_result.string-replace-result text old new)))