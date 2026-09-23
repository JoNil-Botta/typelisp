;; Every stdlib.string helper that the module really exports stays reachable
;; through its qualified name after #7883 (which rejects the unexported ones).
(import stdlib.string)
(import stdlib.string as s)

(define (main) : i64
  (let
    [joined : String (string.append "ab" "cd")]
    [glued : String (s.concat "ab" "cd")]
    (if (and
      (string.eq (& joined) (& glued))
      (string.string=? "ab" "ab")
      (= (string.string-ref "ab" 1) 'b')
      (= (string.char-at "ab" 0) 'a'))
      (- (string.string-length (& joined)) 4)
      1)))