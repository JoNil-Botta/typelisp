(import stdlib.arena)
(import stdlib.string)

(define (allocate-shared [target : (& loan (arena.Arena storage))]) : (in
    storage
    String)
  (in-arena target (string.concat "4" "2")))

(define (allocate-wrapped [target : (& loan (arena.Arena storage))]) : (in
    storage
    String)
  (let
    [view : (& loan (arena.Arena storage)) target]
    (in-arena
      ;; lint-allow: single-begin
      (begin
        view)
      (string.concat "ab" "cd"))))

(define (allocate-exclusive [target : (&mut loan (arena.Arena storage))]) : (in
    storage
    String)
  (in-arena target (string.concat "x" "y")))

(define (main) : i64
  (let
    [owner (arena.make)]
    [first (allocate-shared (& owner))]
    [first-size (string.string-length first)]
    [second (allocate-wrapped (& owner))]
    [second-size (string.string-length second)]
    [third (allocate-exclusive (&mut owner))]
    [third-size (string.string-length third)]
    [last
      (in-arena owner (string.concat "abcdefghijklmnopq" "abcdefghijklmnopq"))]
    [last-size (string.string-length last)]
    (begin
      (unsafe
        ;; lint-allow: raw-arena-op
        (arena.destroy owner))
      (+ (+ first-size second-size) (+ third-size last-size)))))