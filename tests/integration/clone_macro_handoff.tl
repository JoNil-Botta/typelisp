;; End-to-end proof for the typed clone-root -> stdlib :Decls macro handoff.
(import stdlib.clone)

(defstruct CloneMacroUsed
  (name String))

(defstruct CloneMacroUnused
  (name String))

(define (clone-macro-copy [value : CloneMacroUsed]) : CloneMacroUsed
  (clone value))

(define (main) : i64
  (let
    [first : CloneMacroUsed (clone-macro-copy (CloneMacroUsed "a"))]
    [second : CloneMacroUsed (clone-macro-copy (CloneMacroUsed "b"))]
    (+
      40
      (+
        (__tl_string_length (struct-get first name))
        (__tl_string_length (struct-get second name))))))