(import stdlib.arena)
(import stdlib.string)

(defstruct Named
  (name String)
  (k i64))

(define (f [owner : (& handle (arena.Arena source))] [c : bool]) : Named
  (let
    [text (string.append "abc" "")]
    (in-arena owner (when c (return (Named text 39))))
    (Named (string.append "x" "") 0)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [n (f (& owner) true)]
    (arena.destroy-safe! owner)
    (+ n.k (string.string-length n.name))))