;: Matching an enum field read through a reference matches it in place (a
;: shared view): nothing moves, and the owner is usable after the match.
(import stdlib.string)

(defenum Kind
  (Named String)
  (Plain i64))

(defstruct Decl
  (kind Kind)
  (line i64))

(define (line-of [decl : (& d Decl)]) : i64
  (match decl.kind
    [(Kind.Named _) decl.line]
    [(Kind.Plain n) (+ n decl.line)]))

(define (main) : i64
  (let
    [decl : Decl (Decl (Kind.Plain 40) 1)]
    [first : i64 (line-of (& decl))]
    (+ first decl.line)))