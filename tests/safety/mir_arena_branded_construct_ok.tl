;; An arena-branded construction holds the allocation while its arena lives.
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
    (+ 40 (string.string-length box.text))))