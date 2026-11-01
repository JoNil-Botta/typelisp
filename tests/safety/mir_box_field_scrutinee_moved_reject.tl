;; Matching a move-only field of box contents by value moves it out, which
;; consumes the box: the box is unusable afterwards.
(import stdlib.string)

(defenum Label
  (Text String)
  (Blank))

(defstruct Payload
  (label Label))

(define (main) : i64
  (let
    [boxed : (Box Payload) (box (Payload (Label.Text (string.copy "abc"))))]
    [length : i64
      (match (deref boxed).label
        [(Text text) (string.string-length text)]
        [(Blank) 0])]
    (match (deref boxed).label
      [(Text text) (+ length (string.string-length text))]
      [(Blank) length])))