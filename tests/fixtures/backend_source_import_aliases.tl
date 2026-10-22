(import stdlib.string as text)
(import stdlib.string.string-length as size)
(import stdlib.arena)
(import stdlib.core_macros as logic)

(define (qualified-length [_arena : arena.Arena] [value : (& value str)]) : i64
  (text.string-length value))

(cfg
  linux
  (define selected-target : i64
    41))
(cfg
  windows
  (define selected-target : i64
    43))

(define (main) : i64
  (if (and
    (= (qualified-length (arena.Arena 0) "abc") 3)
    (= (size "ok") 2)
    (logic.or false true)
    (= (text.string-length "import") 6)
    (cfg linux (= selected-target 41) (= selected-target 43)))
    42
    1))