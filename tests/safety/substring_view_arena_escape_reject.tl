(import "stdlib/string.tl")

(define (bad [seed : (& outer str)]) : (& outer str)
  (begin
    (string-length seed)
    (with-arena
      phase
      (let
        [text : String (int->string 42)]
        (substring-view (& phase text) 0 1)))))

(define (main) : i64
  (let
    [seed : String "seed"]
    (string-length (bad (& seed)))))