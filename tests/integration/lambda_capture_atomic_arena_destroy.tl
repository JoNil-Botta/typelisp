(import stdlib.arena)

;; Refs #9481. A return after destroy alone also succeeded with the wrong
;; root: the runtime ignored an invalid unmap. Check the captured word too.
;; Refs #9482: never use the owner or its allocations after the lambda ends it.
(define (main) : i64
  (let
    [owner (arena.make-atomic)]
    [root : i64 owner.handle]
    [destroy
      (lambda () : i64
        (let
          [same-root : bool (= owner.handle root)]
          (arena.destroy-safe! owner)
          (if same-root
            42
            1)))]
    (destroy)))