;; string_append.tl — concatenate two Strings via the emit-on-demand,

;; libc-free `tl_string_concat` runtime. `(string-append a b)` /

;; `(string-concat a b)` : (-> String String String) allocates a fresh heap

;; String holding `a`'s bytes followed by `b`'s bytes. This prints

;; "foobar\n" (the literal "foo"+"bar", then a trailing newline appended via

;; the alias) and exits 0.

(define (main) : i64
  (begin
    (print-string (string-append "foo" "bar"))
    (print-string (string-concat "\n" ""))
    0))