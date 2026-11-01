(import stdlib.arena)
(import stdlib.string)

(defstruct Holder
  (:lifetimes r)
  (owner (arena.Arena r)))

(define (make [h : (& handle (Holder source))]) : (in source String)
  (in-arena h.owner (string.int->string -12345)))

(define (erase [h : (& handle (Holder source))]) : String
  (let
    [f
      (lambda () : String
        (when true (return (make h)))
        (in-arena h.owner 0)
        (string.append "x" ""))]
    [text (f)]
    (in-arena h.owner 0)
    text))

(define (main) : i64
  (let
    [h (Holder (arena.make))]
    [result (erase (& h))]
    (arena.destroy-safe! h.owner)
    (string.string-length result)))