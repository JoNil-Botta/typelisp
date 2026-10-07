;; Imports variant_root_clash_lib so the entry module reaches it only
;; transitively.
(import stdlib.arena)
(import variant_root_clash_lib as lib)

(define (via [a : i64]) : i64
  (+
    (lib.make a 2)
    (- (lib.eval (lib.settle (arena.current) a)) 7)
    (lib.mode-score Plain)))