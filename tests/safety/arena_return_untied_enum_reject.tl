(import stdlib.arena)
(import stdlib.string)

(defenum Word
  (Ok String)
  (Err i64))

(define (read-word [n : i64]) : Word
  (if (> n 0)
    (Word.Ok (string.int->string n))
    (Word.Err n)))

(define (measure [owner : (& handle (arena.Arena source))] [n : i64]) : Word
  (let
    [length : i64
      (in-arena
        owner
        (match (read-word n)
          [(Word.Ok text) (string.string-length text)]
          [(Word.Err code) (return (Word.Err code))]))]
    (Word.Ok (string.int->string length))))

(define (main) : i64
  (let
    [owner (arena.make)]
    [result (measure (& owner) -42)]
    (arena.destroy-safe! owner)
    (match result
      [(Word.Ok _) 7]
      [(Word.Err code) (- 0 code)])))