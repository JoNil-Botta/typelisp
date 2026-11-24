;; Macro-expanded qualified calls reach the named module's functions, not the
;; string helpers or builtins their bare spelling names (#8129).
;; Without (import stdlib.string) at the expansion site. The bare-spelling
;; macros are left out: a bare helper resolves where the macro is expanded.
;; lint-allow: unused-import
(import macro_qualified_helper_defs as defs)
(import macro_qualified_helper_macros.*)

(define (tail-append) : String
  (q-append "a" "b"))

(define (tail-concat) : String
  (q-concat "a" "b"))

(define (main) : i64
  (let
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
      (q-int-eq 3 2)
      (not (q-int-eq 2 2))
      (= (q-int-length 21) 42)
      (= (q-array-length "x") 66)
      (= (s-length "abcd") 4)
      (s-eq "x" "x")
      (not (s-eq "x" "y")))
      42
      1)))