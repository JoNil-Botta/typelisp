;; enum_string_payload.tl — an enum variant carrying a String payload is
;; constructed, returned across a function boundary (heap-promoted), and its
;; payload bound back out in a `match` arm. This is the construct/return/match
;; capability a real lexer needs for identifier/keyword tokens (`TIdent`,
;; refs #27); arrays of such tokens and building an identifier substring from
;; the source remain separate gaps.
(import "stdlib/string.tl")

(defenum Token
  (TIdent String)
  (TEnd))

;; Construct a String-payload variant and return it. The returned enum and its
;; String payload are both heap-promoted so they outlive this frame.
(define (mk [s : String]) : Token
  (TIdent s))

;; Match the variant and bind its String payload back out at type String, then
;; measure it. The `TEnd` arm proves the dispatch is by tag.
(define (ident-length [t : Token]) : i64
  (match t
    [(TIdent s) (string-length s)]
    [(TEnd) 0]))

;; (TIdent "hello") -> bind "hello" -> length 5.
(define (main) : i64
  (ident-length (mk "hello")))