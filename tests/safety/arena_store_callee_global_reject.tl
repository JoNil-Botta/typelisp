;; #8681: a callee allocates in its caller's active arena; storing that
;; allocation into a global would outlive the arena.
(import stdlib.string)

(define g : String
  "")

(define (stash) : unit
  (set! g (string.append "a" "b")))

(define (main) : i64
  (with-arena phase (stash))
  (string.string-length g))