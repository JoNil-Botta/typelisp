(import stdlib.arena)

;; Refs #9481. A return after destroy alone also succeeded with the wrong
;; root: the runtime ignored an invalid unmap. Check the captured word too.
;; Refs #9482: the lambda reads the captured handle and is consumed by that
;; call; the caller ends the owner, and nothing uses it afterwards.
(define (main) : i64
  (let
    [owner (arena.make-atomic)]
    [root : i64 (arena.raw-handle owner)]
    [captured-root?
      (lambda () : bool
        (= (arena.raw-handle owner) root))]
    [same-root : bool (captured-root?)]
    (begin
      (arena.destroy-safe! owner)
      (if same-root
        42
        1))))