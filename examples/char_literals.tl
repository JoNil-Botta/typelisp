;; char_literals.tl — character literal forms (refs #27)
;;
;; TypeLisp char literals are written `'x'` (a single character followed by a
;; closing quote) or with an escaped payload such as `'\n'`. Escape forms spell
;; common control/whitespace characters directly:
;;
;;   ' '    -> 32   '\n' -> 10   '\t' -> 9
;;   '\r'   -> 13   '\0'     -> 0
;;
;; A single `'\n'` is the newline escape (10).
;; Code point of a char (Char is one byte; `cast` zero-extends to i64).
(import stdlib.io)

(define (code [c : char]) : i64
  (cast c : i64))

;; `main` prints and returns the sum of the five control literals' code points:
;; 32 + 10 + 9 + 13 + 0 = 64.
(define (main) : i64
  (let
    [result : i64
      (+ (code ' ') (+ (code '\n') (+ (code '\t') (+ (code '\r') (code '\0')))))]
    (begin
      (io.print-string "character literal code sum: ")
      (io.print result)
      result)))