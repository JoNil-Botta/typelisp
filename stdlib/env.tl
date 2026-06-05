;# stdlib/env.tl - Environment variable helpers for TypeLisp (#854).
;#
;# Provides recoverable environment lookup and PATH-style list helpers on top of
;# direct platform C library bindings:
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

;: C library `getenv` binding used by environment helpers.
(extern env-ffi-getenv (:symbol "getenv") : (-> (Ptr u8) (Ptr u8)))

;: C library `strlen` binding used to copy environment values.
(extern env-ffi-strlen (:symbol "strlen") : (-> (Ptr u8) i64))

;: Copy `text` into a NUL-terminated byte array for C library calls.
(define (env-c-string [text : String]) : (Array u8)
  (let
    [n : i64 (string-length text)]
    [buf : (Array u8) (make-array u8 (+ n 1))]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set! buf i (cast (string-ref text i) : u8))
          (set! i (+ i 1))))
      (array-set! buf n (cast #\nul' : u8))
      buf)))

;: Copy a NUL-terminated C string into an owned TypeLisp String.
(define (env-copy-c-string [ptr : (Ptr u8)]) : String
  (let
    [n : i64 (env-ffi-strlen ptr)]
    [buf : (Array u8) (make-array u8 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array-set!
            buf
            i
            (unsafe
              (ptr-read (ptr-offset ptr i))))
          (set! i (+ i 1))))
      (unsafe
        (string-from-bytes (ptr-cast (array-data buf) : (Ptr u8)) n)))))

;: Return the raw C getenv pointer for `name`, or null when missing.
(define (env-getenv-ptr [name : String]) : (Ptr u8)
  (let
    [name-bytes : (Array u8) (env-c-string name)]
    (env-ffi-getenv
      (unsafe
        (ptr-cast (array-data name-bytes) : (Ptr u8))))))

;: Return true when `name` is present in the process environment.
(define (env-var-exists? [name : String]) : bool
  (not (ptr-null? (env-getenv-ptr name))))

;: Return the value of `name`, or an empty string when the variable is missing.
(define (env-var-value [name : String]) : String
  (let
    [value : (Ptr u8) (env-getenv-ptr name)]
    (if (ptr-null? value)
      ""
      (env-copy-c-string value))))

;: Return the target platform PATH-list separator as a one-byte String.
(define (env-path-separator) : String
  (cfg windows ";" ":"))

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
  (let
    [empty : String ""]
    [owned-name : String (string-append name (& empty))]
    (if (env-var-exists? owned-name)
      (EnvSomeString (env-var-value owned-name))
      (EnvNoString))))

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