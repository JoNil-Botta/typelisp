;; End-to-end proof for the typed clone-root -> stdlib :Decls macro handoff.
;; `stdlib.clone` is implicit, repeated roots reuse one helper, multiple roots
;; must not corrupt the shared AST pools, and unused aggregates must not request
;; helpers.
(defstruct CloneMacroUsed
  (name String)
  (count i64))

(defenum CloneMacroChoice
  (None)
  (Some String i64))

(defstruct CloneMacroUnused
  (name String)
  (ignored String))

(define (main) : i64
  (let
    [record : CloneMacroUsed (clone (CloneMacroUsed "a" 20))]
    [record-copy : CloneMacroUsed (clone record)]
    [choice : CloneMacroChoice (clone (CloneMacroChoice.Some "b" 20))]
    (+
      (struct-get record-copy count)
      (+
        (__tl_string_length (struct-get record-copy name))
        (match choice
          [(CloneMacroChoice.None) 0]
          [(CloneMacroChoice.Some text value)
            (+ value (__tl_string_length text))])))))