;; A call in `unsafe` is exempt from the arena-store check: the caller states
;; the store's lifetime obligation itself.
(import stdlib.string)

(define g : String
  "")

(define (stash) : unit
  (set! g (string.append "a" "b")))

(define (main) : i64
  (with-arena
    phase
    ;; unsafe: `g` is not read after this arena ends.
    (unsafe
      (stash)))
  42)