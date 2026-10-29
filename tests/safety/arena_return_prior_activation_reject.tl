(import stdlib.arena)
(import stdlib.string)

(defstruct Holder
  (:lifetimes r)
  (owner (arena.Arena r)))

(define (make [h : (& handle (Holder source))]) : (in source String)
  (in-arena h.owner (string.int->string -12345)))

(define (erase [h : (& handle (Holder source))] [c : bool]) : String
  (in-arena h.owner 0)
  (when c (return (make h)))
  (string.append "x" ""))

(define (main) : i64
  (let
    [h (Holder (arena.make))]
    [result (erase (& h) true)]
    (arena.destroy-safe! h.owner)
    (string.string-length result)))