;; Under `(import stdlib.string)` every bare helper spelling compiles, links and
;; runs (#7957): `eq`, `string-eq` and `string=?` compare bytes, and the
;; deprecated `string-append` and `string-concat` build a new String through
;; the runtime concat ABI. `string-concat` is also the name of the runtime
;; prelude's private implementation, and `eq` of stdlib.string's own
;; definition; neither may turn the bare spelling into a call to an undefined
;; symbol. Nested and tail-position concatenation take their own lowering
;; paths, so both are exercised.
(import stdlib.string)

(define (joined [left : String] [right : String]) : String
  (string-concat left right))

(define (main) : i64
  (let
    [same : String "same"]
    (cond
      [(not (eq "abc" "abc")) 1]
      [(eq "abc" "abd") 2]
      [(not (string-eq same "same")) 3]
      [(string-eq "a" "ab") 4]
      [(not (string=? "" "")) 5]
      [(string=? "x" "y") 6]
      [(not (= (string-length (string-concat "ab" "cd")) 4)) 7]
      [(not (string-eq (string-concat "ab" "cd") "abcd")) 8]
      [(not (string=? (string-concat (string-concat "a" "b") "c") "abc")) 9]
      [(not (string=? (string-append "ab" (string-concat "c" "d")) "abcd")) 10]
      [(not (string-eq (joined "x" "y") "xy")) 11]
      [(not (= (string-length "hello") 5)) 12]
      [(not (= (string-ref "hello" 1) 'e')) 13]
      [(not (= (char-at "hello" 4) 'o')) 14]
      [else 42])))