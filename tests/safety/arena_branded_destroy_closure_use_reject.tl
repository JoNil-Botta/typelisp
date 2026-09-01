(import stdlib.arena)
(import stdlib.string)

(defstruct BrandedOwner
  (:lifetimes owner)
  (arena (arena.Arena owner)))

(define (main) : i64
  (let
    [owner (arena.make-atomic)]
    [text (in-arena owner (string.append "owned" "-text"))]
    [state (BrandedOwner owner)]
    [read-text : (-> i64)
      (lambda () : i64
        (string.string-length text))]
    (begin
      (arena.destroy-safe! state.arena)
      (read-text))))