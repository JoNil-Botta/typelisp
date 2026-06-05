(import "stdlib/string_caller_result.tl")

(define (string-caller-result-borrowed-check
  [text : (& text str)]
  [old : (& old str)]
  [new : (& replacement str)]) : (StringReplaceResult text old replacement)
  (string-replace-borrowed-result text old new))

(define (string-caller-result-owned-check
  [text : (& text str)]
  [old : (& old str)]
  [new : (& replacement str)]
  [owned : String]) : (StringReplaceResult text old replacement)
  (string-replace-owned-result-like text old new owned))

(define (string-caller-result-render-check
  [result : (StringReplaceResult text old replacement)]) : String
  (string-replace-result-string result))

(define (string-caller-result-helper-check
  [text : (& text str)]
  [old : (& old str)]
  [new : (& replacement str)]) : (StringReplaceResult text old replacement)
  (string-replace-result text old new))

(define (string-caller-result-helper-borrowed-flag-check
  [text : (& text str)]
  [old : (& old str)]
  [new : (& replacement str)]) : bool
  (string-replace-result-borrowed? (string-replace-result text old new)))

(define (string-caller-result-helper-owned-render-check
  [text : (& text str)]
  [old : (& old str)]
  [new : (& replacement str)]) : String
  (string-replace-result-string (string-replace-result text old new)))