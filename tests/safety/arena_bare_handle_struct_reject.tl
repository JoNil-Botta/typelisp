;; #8173: a copied handle inside a returned struct ends with the owner too.
(import stdlib.arena)
(import stdlib.string)

(defstruct Holder
  (a arena.Arena))

(define (wrap [a : arena.Arena]) : Holder
  (Holder a))

(define (main) : i64
  (let
    [s : arena.Arena (arena.make)]
    [h : Holder (wrap s)]
    (begin
      (arena.destroy-safe! s)
      (string.string-length (in-arena h.a (string.concat "a" "b"))))))