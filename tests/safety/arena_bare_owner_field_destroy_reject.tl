;; Storing a bare-annotated owner in a struct field moves the owner (#8172).
(import stdlib.arena)
(import stdlib.string)

(defstruct BareOwnerHolder
  (arena arena.Arena))

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [holder : BareOwnerHolder (BareOwnerHolder owner)]
    (begin
      (arena.destroy-safe! owner)
      (string.string-length (in-arena holder.arena (string.concat "a" "b"))))))