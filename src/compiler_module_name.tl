;; Complete dotted import identities share this byte-level contract. Token
;; boundaries and incomplete editor prefixes belong to their callers.
(import stdlib.string)

(define (compiler-module-name-tl-suffix? [name : (& name str)]) : bool
  (let
    [n : i64 (string.string-length name)]
    (if (< n 3)
      false
      (string.eq (string.substring name (- n 3) 3) ".tl"))))

(define (compiler-module-name-valid? [name : (& name str)]) : bool
  (let
    [n : i64 (string.string-length name)]
    [i : i64 0]
    [ok : bool (and (> n 0) (not (compiler-module-name-tl-suffix? name)))]
    [last-was-dot : bool true]
    (begin
      (while ok
        (if (< i n)
          (let
            [c : char (string.string-ref name i)]
            (if (or
              (string.char-eq c '/')
              (string.char-eq c '\\')
              (string.char-eq c ':'))
              (set! ok false)
              (if (string.char-eq c '.')
                (if last-was-dot
                  (set! ok false)
                  (begin
                    (set! last-was-dot true)
                    (set! i (+ i 1))))
                (begin
                  (set! last-was-dot false)
                  (set! i (+ i 1))))))
          (set! ok false)))
      (and (= i n) (not last-was-dot)))))