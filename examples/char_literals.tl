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
(define (code [c : char]) : i64
  (cast c : i64))

;; `main` returns the SUM of the five control literals' code points as its exit
;; code: 32 + 10 + 9 + 13 + 0 = 64. Running this program therefore exits 64,
;; an observable check that every control literal lowers to the right value.
(define (main) : i64
  (+ (code ' ') (+ (code '\n') (+ (code '\t') (+ (code '\r') (code '\0'))))))