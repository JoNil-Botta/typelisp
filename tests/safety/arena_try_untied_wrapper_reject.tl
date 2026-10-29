(import stdlib.arena)
(import stdlib.string)

(defenum Word
  (Ok String)
  (Err String))

(define (f [owner : (& handle (arena.Arena source))] [text : String] [c : bool]) : Word
  (let
    [n : i64
      (in-arena
        owner
        (let
          [s
            (try
              (if c
                (Word.Err text)
                (Word.Ok (string.append "a" ""))))]
          (string.string-length s)))]
    (Word.Ok (string.int->string n))))

(define (main) : i64
  (let
    [owner (arena.make)]
    [w (f (& owner) (string.append "abc" "") true)]
    (arena.destroy-safe! owner)
    (match w
      [(Word.Ok t) (string.string-length t)]
      [(Word.Err t) (+ 39 (string.string-length t))])))