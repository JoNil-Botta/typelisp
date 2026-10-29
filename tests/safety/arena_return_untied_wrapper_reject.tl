(import stdlib.arena)
(import stdlib.string)

(defenum Wrapped
  (Text String)
  (Empty))

(define (wrap
  [owner : (& handle (arena.Arena source))]
  [text : String]
  [c : bool]) : Wrapped
  (in-arena owner (when c (return (Wrapped.Text text))))
  (Wrapped.Empty))

(define (main) : i64
  (let
    [text (string.int->string -12345)]
    [owner (arena.make)]
    [result (wrap (& owner) text true)]
    (arena.destroy-safe! owner)
    (match result
      [(Wrapped.Text s) (+ (string.string-length s) 36)]
      [(Wrapped.Empty) 7])))