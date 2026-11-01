(import stdlib.arena)
(import stdlib.string)

(defenum Parsed
  (Ok i64)
  (Err String))

(define (parse [n : i64]) : Parsed
  (if (> n 0)
    (Parsed.Ok n)
    (Parsed.Err (string.int->string n))))

(define (parse-in [owner : (& handle (arena.Arena source))] [n : i64]) : Parsed
  (let
    [value : i64 (in-arena owner (try (parse n)))]
    (Parsed.Ok value)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [result (parse-in (& owner) -12345)]
    (arena.destroy-safe! owner)
    (match result
      [(Parsed.Ok n) n]
      [(Parsed.Err text) (string.string-length text)])))