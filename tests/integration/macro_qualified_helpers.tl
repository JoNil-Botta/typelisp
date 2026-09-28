;; Macro-expanded qualified calls reach the named module's functions, not the
;; string helpers or builtins their bare spelling names (#8129).
(import stdlib.string)
(import macro_qualified_helper_defs as defs)
(import macro_qualified_helper_macros.*)

(define (tail-append) : String
  (q-append "a" "b"))

(define (tail-concat) : String
  (q-concat "a" "b"))

(define (tail-clone [cell : (& cell defs.Cell)]) : defs.Pair
  (q-clone cell))

(define (main) : i64
  (let
    [cell : defs.Cell (defs.Cell 1)]
    [pair : defs.Pair (q-clone (& cell))]
    [tail-pair : defs.Pair (tail-clone (& cell))]
    [appended : String (q-append "a" "b")]
    [concatenated : String (q-concat "a" "b")]
    [nested : String (q-append (q-concat "a" "b") "c")]
    (if (and
      (= (q-length "x") 99)
      (= (q-ref "x") 'z')
      (= (q-char-at "x") 'u')
      (q-eq "x" "y")
      (q-string-eq "x" "y")
      (q-string-eq? "x" "y")
      (s-eq appended "user")
      (s-eq concatenated "user")
      (s-eq nested "user")
      (s-eq (tail-append) "user")
      (s-eq (tail-concat) "user")
      (= (+ pair.a pair.b) 42)
      (= (+ tail-pair.a tail-pair.b) 42)
      (q-int-eq 3 2)
      (not (q-int-eq 2 2))
      (= (q-int-length 21) 42)
      (= (q-array-length "x") 66)
      (= (b-length "abc") 3)
      (= (b-ref "abc") 'b')
      (= (s-length "abcd") 4)
      (s-eq "x" "x")
      (not (s-eq "x" "y")))
      42
      1)))