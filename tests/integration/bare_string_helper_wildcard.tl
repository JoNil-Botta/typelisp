;; `(import m.*)` binds m's `string-eq` and `string-concat` unqualified, so here
;; they are what the bare spellings call; bare `string=?`, which m does not
;; declare, stays stdlib.string's helper (#7957).
(import stdlib.string)
(import bare_string_helper_defs.*)

(define (main) : i64
  (cond
    [(string-eq "a" "a") 1]
    [(not (= (string-length (string-concat "x" "yz")) 2)) 2]
    [(not (string=? "a" "a")) 3]
    [(not (= (string-length (joined "x" "yz")) 2)) 4]
    [else 42]))