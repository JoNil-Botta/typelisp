;# stdlib/env.tl - Environment variable helpers for TypeLisp (#854).
;#
;# Provides recoverable environment lookup and PATH-style list helpers on top of
;# compiler/runtime primitives:
;#
;# `env-var-exists?`, `env-var-value`, and `env-path-separator`.
;#
;# Usage: `(import "stdlib/env.tl")`
;#
;# ```typelisp
;# (import "stdlib/env.tl")
;# (define fallback : EnvMaybeString
;#   (let [name : String "TYPELISP_DOC_TEST_MISSING_ENV"] (env-get (& name))))
;# ```
(import "string.tl")

;: Optional String result for environment lookups.
(defenum EnvMaybeString
  (EnvNoString)
  (EnvSomeString String))

;: Immutable list of strings used for PATH-style environment variables.
(defenum EnvStringList
  (EnvStringNil)
  (EnvStringCons String EnvStringList))

;: Optional PATH-style list result. Missing variables use `EnvNoStringList`;
;: present empty variables use `EnvSomeStringList EnvStringNil`.
(defenum EnvMaybeStringList
  (EnvNoStringList)
  (EnvSomeStringList EnvStringList))

;: Return an empty environment string list.
(define (env-string-list-empty) : EnvStringList
  (EnvStringNil))

;: Prepend an owned string to an environment string list.
(define (env-string-list-cons [value : String] [rest : EnvStringList]) : EnvStringList
  (EnvStringCons value rest))

;: Reverse `items` onto `acc`, allocating a fresh active-arena list spine.
(define (env-string-list-reverse-onto
  [items : EnvStringList]
  [acc : EnvStringList]) : EnvStringList
  (match items
    [(EnvStringNil) acc]
    [(EnvStringCons head rest)
      (env-string-list-reverse-onto rest (EnvStringCons head acc))]))

;: Return `items` in reverse order.
(define (env-string-list-reverse [items : EnvStringList]) : EnvStringList
  (env-string-list-reverse-onto items (EnvStringNil)))

;: Return the current platform PATH-list separator as a one-byte String.
(define (env-path-list-separator) : String
  (env-path-separator))

;: Return the value of `name`, or `EnvNoString` when the variable is missing.
(define (env-get [name : (& name str)]) : EnvMaybeString
  (if (env-var-exists? name)
    (EnvSomeString (env-var-value name))
    (EnvNoString)))

;: Split a PATH-style string using the supplied one-byte separator string.
(define (env-path-split-with-separator
  [value : (& value str)]
  [separator : (& separator str)]) : EnvStringList
  (let
    [n : i64 (string-length value)]
    (if (= n 0)
      (EnvStringNil)
      (let
        [sep : char (string-ref separator 0)]
        [items : EnvStringList (EnvStringNil)]
        [start : i64 0]
        [i : i64 0]
        (begin
          (while (< i n)
            (if (char-eq (string-ref value i) sep)
              (begin
                (set!
                  items
                  (EnvStringCons (substring value start (- i start)) items))
                (set! start (+ i 1))
                (set! i (+ i 1)))
              (set! i (+ i 1))))
          (env-string-list-reverse
            (EnvStringCons (substring value start (- n start)) items)))))))

;: Split a PATH-style string using the current platform separator.
(define (env-path-split [value : (& value str)]) : EnvStringList
  (let
    [separator : String (env-path-list-separator)]
    (env-path-split-with-separator value (& separator))))

;: Read `name` and split it as a PATH-style list when present.
(define (env-path-list [name : (& name str)]) : EnvMaybeStringList
  (match (env-get name)
    [(EnvSomeString value) (EnvSomeStringList (env-path-split (& value)))]
    [(EnvNoString) (EnvNoStringList)]))

;: Append PATH-style `items` to `acc`, allocating joined string segments.
(define (env-path-join-tail
  [acc : String]
  [items : EnvStringList]
  [separator : (& separator str)]) : String
  (match items
    [(EnvStringNil) acc]
    [(EnvStringCons head rest)
      (env-path-join-tail
        (string-append (string-append acc separator) head)
        rest
        separator)]))

;: Join PATH-style items using the supplied separator.
(define (env-path-join-with-separator
  [items : EnvStringList]
  [separator : (& separator str)]) : String
  (match items
    [(EnvStringNil) ""]
    [(EnvStringCons head rest) (env-path-join-tail head rest separator)]))

;: Join PATH-style items using the current platform separator.
(define (env-path-join [items : EnvStringList]) : String
  (let
    [separator : String (env-path-list-separator)]
    (env-path-join-with-separator items (& separator))))