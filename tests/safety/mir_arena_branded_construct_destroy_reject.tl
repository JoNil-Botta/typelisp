;; A struct holding an arena allocation (an arena-branded construction) is
;; invalidated when its arena is destroyed.
(import stdlib.arena as memory)
(import stdlib.string)

(defstruct TextBox
  (:lifetimes owner)
  (text (in owner String)))

(define (main) : i64
  (let
    [owner (memory.make)]
    [text (in-arena owner (string.append "a" "b"))]
    [box (TextBox text)]
    (begin
      (memory.destroy-safe! owner)
      (string.string-length box.text))))