;; char_literals.tl — character literal forms (refs #27)
;;
;; TypeLisp char literals are written `#x'` (a single character followed by a
;; closing quote) or `#\x'` (an escaped form). On top of the single-character
;; and escape forms, NAMED literals spell out common control/whitespace
;; characters by name:
;;
;;   #\space'    -> 32   #\newline' -> 10   #\tab' -> 9
;;   #\return'   -> 13   #\nul'     -> 0
;;
;; A single `#\n'` is still the newline ESCAPE (10), distinct from the name
;; `#\newline'`; a lone letter after `#\` is never read as a (truncated) name.
;; Code point of a char (Char is one byte; `cast` zero-extends to i64).
(define (code [c : char]) : i64
  (cast c : i64))

;; `main` returns the SUM of the five named literals' code points as its exit
;; code: 32 + 10 + 9 + 13 + 0 = 64. Running this program therefore exits 64,
;; an observable check that every named literal lowers to the right value.
(define (main) : i64
  (+
    (code #\space')
    (+ (code #\newline') (+ (code #\tab') (+ (code #\return') (code #\nul'))))))