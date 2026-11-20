;; #9770 control: a capturing closure made outside any arena is returned.
(import stdlib.io)

(extern (tl_arena_poison_enable) : unit)

(define (mk [x : i64]) : (-> i64)
  (lambda () : i64
    x))

(define (main) : i64
  (begin
    (tl_arena_poison_enable)
    (let
      [g (mk 77)]
      (let
        [v : i64 (g)]
        (begin
          (io.println "C1 v={}" v)
          (if (= v 77)
            42
            (bit-and v 255)))))))