;; Storing a branded owner in a bare `arena.Arena` field moves the owner, as
;; erasing it into a bare binding does (#8172).
(import stdlib.arena)
(import stdlib.string)

(defstruct BareFieldHolder
  (arena arena.Arena))

(define (main) : i64
  (let
    [owner (arena.make)]
    [holder : BareFieldHolder (BareFieldHolder owner)]
    (begin
      (arena.destroy-safe! owner)
      (string.string-length (in-arena holder.arena (string.concat "a" "b"))))))