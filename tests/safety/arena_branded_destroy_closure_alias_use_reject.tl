(import stdlib.arena)
(import stdlib.string)

(defstruct BrandedClosureAliasOwner
  (:lifetimes owner)
  (arena (arena.Arena owner)))

(define (main) : i64
  (let
    [owner (arena.make-atomic)]
    [text (in-arena owner (string.append "owned" "-text"))]
    [state (BrandedClosureAliasOwner owner)]
    [read-text : (-> i64)
      (lambda () : i64
        (string.string-length text))]
    [read-alias : (-> i64) read-text]
    (begin
      (arena.destroy-safe! state.arena)
      (read-alias))))