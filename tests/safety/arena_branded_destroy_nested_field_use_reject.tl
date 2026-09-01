(import stdlib.arena)
(import stdlib.string)

(defstruct BrandedDestroyPayload
  (:lifetimes owner)
  (text (in owner String)))

(defstruct BrandedDestroyNestedOwner
  (:lifetimes owner)
  (arena (arena.Arena owner)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (string.append "owned" "-text"))]
    [payload (BrandedDestroyPayload text)]
    [state (BrandedDestroyNestedOwner owner)]
    (begin
      (arena.destroy-safe! state.arena)
      (string.string-length payload.text))))