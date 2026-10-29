(import stdlib.string)

(defenum Word
  (Ok String)
  (Err i64))

(define (read-word [n : i64]) : Word
  (if (> n 0)
    (Word.Ok (string.int->string n))
    (Word.Err n)))

(define (measure [n : i64]) : Word
  (let
    [length : i64
      (with-arena
        phase
        (match (read-word n)
          [(Word.Ok text) (string.string-length text)]
          [(Word.Err code) (return (Word.Err code))]))]
    (Word.Ok (string.int->string length))))

(define (main) : i64
  (match (measure -42)
    [(Word.Ok _) 7]
    [(Word.Err code) (- 0 code)]))