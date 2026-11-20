;; #9770: as arena_closure_escape_reject, with arena poisoning enabled.
(import stdlib.io)

(extern (tl_arena_poison_enable) : unit)

(define (mk [x : i64]) : (-> i64)
  (with-arena
    r
    (lambda () : i64
      x)))

(define (main) : i64
  (begin
    (tl_arena_poison_enable)
    (let
      [g (mk 77)]
      (let
        [v : i64 (g)]
        (begin
          (io.println "V03 v={}" v)
          (if (= v 77)
            42
            (bit-and v 255)))))))