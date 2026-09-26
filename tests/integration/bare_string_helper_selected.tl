;; `(import m.item)` binds only that item unqualified: bare `string-eq` calls
;; m's definition, while bare `string-concat` stays stdlib.string's helper. An
;; aliased `(import stdlib.string as s)` still makes the bare helpers visible
;; (#7957).
(import stdlib.string as s)
(import bare_string_helper_defs.string-eq)

(define (main) : i64
  (cond
    [(string-eq "a" "a") 1]
    [(not (= (string-length (string-concat "x" "yz")) 3)) 2]
    [(not (s.eq "a" "a")) 3]
    [else 42]))