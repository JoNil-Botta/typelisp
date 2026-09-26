;; `(import m as a)` makes m's definitions reachable only qualified, so this
;; file's bare `string-eq` and `string-concat` are stdlib.string's helpers even
;; though bare_string_helper_defs declares both. That module's own bare calls
;; still reach its definitions (#7957).
(import stdlib.string)
(import bare_string_helper_defs as defs)

(define (main) : i64
  (cond
    [(not (string-eq "a" "a")) 1]
    [(not (= (string-length (string-concat "x" "yz")) 3)) 2]
    [(not (= (string-length (defs.joined "x" "yz")) 2)) 3]
    [(defs.same? "a" "a") 4]
    [(not (defs.same-helper? "a" "a")) 5]
    [else 42]))