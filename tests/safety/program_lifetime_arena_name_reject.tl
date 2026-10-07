;: `program` is the reserved lifetime that outlives every region, so it cannot
;: name a `with-arena` region: a value allocated there would escape the arena
;: into a global (#8630).
(import stdlib.string)

(define g : String
  (string.int->string 1))

(define (main) : i64
  (with-arena program (set! g (string.int->string 22)))
  (string.string-length g))