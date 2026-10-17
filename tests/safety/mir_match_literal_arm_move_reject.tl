;; A match with a literal arm moves the bound payload out of the scrutinee, so a
;; later use of the scrutinee is a use after move.
(import stdlib.string as string)

(defenum Carrier
  (Text String)
  (None))

(define (consume [c : Carrier]) : i64
  (match c
    [(Carrier.Text _) 1]
    [(Carrier.None) 0]))

(define (main) : i64
  (let
    [c : Carrier (Carrier.Text (string.copy "abc"))]
    (if (=
      (match c
        [(Carrier.Text text) (string.string-length (& text))]
        [(Carrier.None) 0])
      3)
      (consume c)
      42)))