;; A module's own definition of a bare stdlib.string helper spelling is what
;; its calls reach, even under `(import stdlib.string)`: only the runtime
;; prelude's private `string-concat` and stdlib.string's own definitions stand
;; behind the helper spellings (#7957). These definitions keep the helpers'
;; signatures; a different signature is #8096.
(import stdlib.string)

(define (string-concat [_left : String] [right : String]) : String
  right)

(define (string-eq [_left : String] [_right : String]) : bool
  false)

(define (main) : i64
  (cond
    [(not (= (string-length (string-concat "x" "yz")) 2)) 1]
    [(string-eq "a" "a") 2]
    [else 42]))