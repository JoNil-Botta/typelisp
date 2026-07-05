(import stdlib.string)

(define (bad [seed : (& outer str)]) : (& outer str)
  (begin
    (string-length seed)
    (with-arena
      phase
      (let
        [text : String (string.int->string 42)]
        (string.substring-view (& phase text) 0 1)))))

(define (main) : i64
  (let
    [seed : String "seed"]
    (string-length (bad (& seed)))))