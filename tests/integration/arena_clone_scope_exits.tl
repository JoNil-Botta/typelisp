(import stdlib.arena)
(import stdlib.string)

(define (scratch-return [n : i64]) : i64
  (with-scratch
    (let
      [text (string.int->string n)]
      (return (string.string-length (& text))))))

(define (escape-return [scratch : arena.Arena] [n : i64]) : i64
  (with-escape
    scratch
    (with-scratch
      (let
        [text (string.int->string n)]
        (return (string.string-length (& text)))))))

(define (loop-exits [scratch : arena.Arena] [home : arena.Arena]) : i64
  (let
    [i : i64 0]
    [total : i64 0]
    (while (< i 100)
      (unless (arena.eq? (arena.current) home) (return 0))
      (set! i (+ i 1))
      (with-escape
        scratch
        (let
          [text (string.int->string i)]
          (set! total (+ total (string.string-length (& text))))
          (with-scratch (when (< i 10) (continue)) (break)))))
    (if (arena.eq? (arena.current) home)
      total
      0)))

(define (scratch-mark [scratch : arena.Arena]) : i64
  (in-arena scratch (return (arena.mark-raw-handle (arena.mark)))))

(define (lexical-return) : i64
  (with-arena
    phase
    (let
      [text (string.copy "twelve")]
      (return (string.string-length (& text))))))

(define (main) : i64
  (let
    [home (arena.current)]
    [scratch (arena.make)]
    [outer-mark (arena.mark)]
    [before (scratch-mark scratch)]
    [value (+ (scratch-return 123456789) (escape-return scratch 123456789))]
    [loop-value (loop-exits scratch home)]
    [lexical (lexical-return)]
    [after (scratch-mark scratch)]
    (if (and
      (arena.eq? (arena.current) home)
      (= before after)
      (arena.mark-eq? outer-mark (arena.mark)))
      (+ value (+ loop-value (+ lexical 7)))
      1)))