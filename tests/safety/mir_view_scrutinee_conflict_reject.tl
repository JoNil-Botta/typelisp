;: A binding from an enum matched through a reference is a view of the
;: referent: the owner cannot be mutated while the binding is live.
(import stdlib.string)

(defenum Kind
  (Named String)
  (Plain i64))

(defstruct Decl
  (kind Kind)
  (line i64))

(define (name-len [decl : (&mut d Decl)]) : i64
  (match decl.kind
    [(Kind.Named name)
      (begin
        (set! decl.kind (Kind.Plain 0))
        (string.string-length (& name)))]
    [(Kind.Plain n) n]))

(define (main) : i64
  (let
    [decl : Decl (Decl (Kind.Named (string.copy "ab")) 40)]
    (+ (name-len (&mut decl)) decl.line)))