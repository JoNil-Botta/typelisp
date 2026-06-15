;# stdlib/env.tl - Environment variable helpers for TypeLisp (#854).
;#
;# Provides recoverable environment lookup and PATH-style list helpers on top of
;# direct platform C library bindings:
;#
;# `env-var-exists?`, `env-var-value`, and `env-path-separator`. Public
;# list-returning PATH helpers remain for compatibility; vector-returning
;# variants avoid cons/reverse work for new internal callers.
;#
;# Usage: `(import stdlib.env)`
;#
;# ```typelisp
;# (import stdlib.env)
;# (define fallback : env.EnvMaybeString
;#   (let [name : String "TYPELISP_DOC_TEST_MISSING_ENV"] (env.env-get (& name))))
;# ```
(module stdlib.env)

(import stdlib.string as string_mod)

(import stdlib.vector as vector_mod)

;: Windows kernel32 `GetEnvironmentStringsA` binding (#2142 follow-up). Returns
;: the process environment block: NUL-separated `NAME=VALUE` entries terminated
;: by an empty entry (a trailing double NUL). Replaces the former backend-emitted
;: `getenv` libc shim on Windows; the Linux side walks the SysV stack-captured
;: environment directly. The block is intentionally not freed: the returned value
;: pointer is copied by the caller before any further allocation, and these CLI
;: tools are short-lived.
(cfg
  windows
  (extern (env-win-get-environment-strings) : (Ptr u8) (:symbol "GetEnvironmentStringsA")))

;: Length of the NUL-terminated C string at `ptr` (a freestanding `strlen`).
(unsafe
  (define (env-c-string-length [ptr : (Ptr u8)]) : i64
    (let
      [n : i64 0]
      (begin
        (while (not
          (=
            (unsafe
              (ptr-read (ptr-offset ptr n)))
            (cast 0 : u8)))
          (set! n (+ n 1)))
        n))))

;: Copy a NUL-terminated C string into an owned TypeLisp String.
(unsafe
  (define (env-copy-c-string [ptr : (Ptr u8)]) : String
    (let
      [n : i64
        (unsafe
          (stdlib.env.env-c-string-length ptr))]
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
          (string-from-bytes (ptr-cast (array-data buf) : (Ptr u8)) n))))))

;: Lowercase an ASCII byte (A-Z -> a-z); other bytes pass through. Used for the
;: case-insensitive environment-name match on Windows.
(define (env-ascii-fold [b : u8]) : u8
  (if (and (>= (cast b : i64) 65) (<= (cast b : i64) 90))
    (cast (+ (cast b : i64) 32) : u8)
    b))

;: True when `name` is the variable name of the C env entry `entry` (a
;: `NAME=VALUE` string). When matched, returns a pointer to the value (just past
;: the `=`); otherwise null. `fold` enables case-insensitive comparison (Windows).
(unsafe
  (define (env-match-entry [name : String] [entry : (Ptr u8)] [fold : bool]) : (Ptr
      u8)
    (let
      [n : i64 (string-length name)]
      [i : i64 0]
      [ok : bool true]
      (begin
        (while (and ok (< i n))
          (let
            [ec : u8
              (unsafe
                (ptr-read (ptr-offset entry i)))]
            [nc : u8 (cast (string-ref name i) : u8)]
            (if (if fold
              (= (stdlib.env.env-ascii-fold ec) (stdlib.env.env-ascii-fold nc))
              (= ec nc))
              (set! i (+ i 1))
              (set! ok false))))
        (if (not ok)
          (ptr-null : (Ptr u8))
          (let
            [sep : u8
              (unsafe
                (ptr-read (ptr-offset entry n)))]
            (if (= sep (cast #=' : u8))
              (unsafe
                (ptr-offset entry (+ n 1)))
              (ptr-null : (Ptr u8)))))))))

;: Linux `getenv`: walk the SysV stack-captured environment. The kernel lays out
;: argc, argv[0..], a NULL, then envp[0..] on the initial stack, so envp is
;: `&argv[argc + 1]` (computed from the `program-argv`/`program-argc` builtins,
;: matching `stdlib/process_runtime.tl`; no new backend symbol). Returns a
;: pointer to the value of `name`, or null when missing.
(unsafe
  (define (env-getenv-ptr-linux [name : String]) : (Ptr u8)
    (let
      [envp : (Ptr (Ptr u8))
        (unsafe
          (ptr-offset (program-argv) (+ (program-argc) 1)))]
      [idx : i64 0]
      [result : (Ptr u8) (ptr-null : (Ptr u8))]
      [stop : bool false]
      (begin
        (while (not stop)
          (let
            [entry : (Ptr u8)
              (unsafe
                (ptr-read (ptr-offset envp idx)))]
            (if (ptr-null? entry)
              (set! stop true)
              (let
                [value : (Ptr u8)
                  (unsafe
                    (stdlib.env.env-match-entry name entry false))]
                (if (ptr-null? value)
                  (set! idx (+ idx 1))
                  (begin
                    (set! result value)
                    (set! stop true)))))))
        result))))

;: Windows `getenv`: walk the GetEnvironmentStringsA block (case-insensitive,
;: matching the platform's environment semantics). Returns a pointer to the value
;: of `name`, or null when missing.
(cfg
  windows
  (unsafe
    (define (env-getenv-ptr-windows [name : String]) : (Ptr u8)
      (let
        [p : (Ptr u8)
          (unsafe
            (stdlib.env.env-win-get-environment-strings))]
        [result : (Ptr u8) (ptr-null : (Ptr u8))]
        [stop : bool false]
        (begin
          (while (not stop)
            (if (=
              (unsafe
                (ptr-read p))
              (cast 0 : u8))
              (set! stop true)
              (let
                [value : (Ptr u8)
                  (unsafe
                    (stdlib.env.env-match-entry name p true))]
                (if (ptr-null? value)
                  (set!
                    p
                    (unsafe
                      (ptr-offset
                        p
                        (+
                          (unsafe
                            (stdlib.env.env-c-string-length p))
                          1))))
                  (begin
                    (set! result value)
                    (set! stop true))))))
          result)))))

;: Return the value pointer for `name`, or null when missing. `env.tl` is
;: imported by the compiler loader while stdlib roots are being discovered, so
;: this avoids depending on another stdlib module: it uses only builtins, its own
;: helpers, and (on Windows) a direct kernel32 binding.
(unsafe
  (define (env-getenv-ptr [name : String]) : (Ptr u8)
    (cfg
      windows
      (unsafe
        (stdlib.env.env-getenv-ptr-windows name))
      (unsafe
        (stdlib.env.env-getenv-ptr-linux name)))))

;: Return true when `name` is present in the process environment.
(define (env-var-exists? [name : String]) : bool
  (not
    (ptr-null?
      (unsafe
        (stdlib.env.env-getenv-ptr name)))))

;: Return the value of `name`, or an empty string when the variable is missing.
(define (env-var-value [name : String]) : String
  (let
    [value : (Ptr u8)
      (unsafe
        (stdlib.env.env-getenv-ptr name))]
    (if (ptr-null? value)
      ""
      (unsafe
        (stdlib.env.env-copy-c-string value)))))

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
  (EnvStringCons String (Box EnvStringList)))

;: Optional PATH-style list result. Missing variables use `EnvNoStringList`;
;: present empty variables use `EnvSomeStringList EnvStringNil`.
(defenum EnvMaybeStringList
  (EnvNoStringList)
  (EnvSomeStringList EnvStringList))

;: Optional PATH-style vector result. Missing variables use `EnvNoStringVec`;
;: present empty variables use `EnvSomeStringVec` with an empty `StringVec`.
(defenum EnvMaybeStringVec
  (EnvNoStringVec)
  (EnvSomeStringVec vector_mod.StringVec))

;: Return an empty environment string list.
(define (env-string-list-empty) : EnvStringList
  stdlib.env.EnvStringNil)

;: Prepend an owned string to an environment string list.
(define (env-string-list-cons [value : String] [rest : EnvStringList]) : EnvStringList
  (EnvStringCons value (box rest)))

;: Reverse `items` onto `acc`, allocating a fresh active-arena list spine.
(define (env-string-list-reverse-onto
  [items : EnvStringList]
  [acc : EnvStringList]) : EnvStringList
  (match items
    [(EnvStringNil) acc]
    [(EnvStringCons head rest)
      (stdlib.env.env-string-list-reverse-onto
        (box-get rest)
        (EnvStringCons head (box acc)))]))

;: Return `items` in reverse order.
(define (env-string-list-reverse [items : EnvStringList]) : EnvStringList
  (stdlib.env.env-string-list-reverse-onto items stdlib.env.EnvStringNil))

;: Build an environment string list from `items`, preserving vector order.
(define (env-string-list-from-vec-from
  [items : vector_mod.StringVec]
  [index : i64]
  [acc : EnvStringList]) : EnvStringList
  (if (< index 0)
    acc
    (stdlib.env.env-string-list-from-vec-from
      items
      (- index 1)
      (EnvStringCons (vector_mod.string-vec-get items index "") (box acc)))))

;: Build an environment string list from `items`, preserving vector order.
(define (env-string-list-from-vec [items : vector_mod.StringVec]) : EnvStringList
  (stdlib.env.env-string-list-from-vec-from
    items
    (- (vector_mod.string-vec-len items) 1)
    stdlib.env.EnvStringNil))

;: Copy `items` into `out`, preserving list order.
(define (env-string-list-to-vec-into
  [items : EnvStringList]
  [out : vector_mod.StringVec]) : vector_mod.StringVec
  (match items
    [(EnvStringNil) out]
    [(EnvStringCons head rest)
      (stdlib.env.env-string-list-to-vec-into
        (box-get rest)
        (vector_mod.string-vec-push out head))]))

;: Copy `items` into a fresh `StringVec`, preserving list order.
(define (env-string-list-to-vec [items : EnvStringList]) : vector_mod.StringVec
  (stdlib.env.env-string-list-to-vec-into items (vector_mod.string-vec-new)))

;: Return the current platform PATH-list separator as a one-byte String.
(define (env-path-list-separator) : String
  (stdlib.env.env-path-separator))

;: Return the value of `name`, or `EnvNoString` when the variable is missing.
(define (env-get [name : (& name str)]) : EnvMaybeString
  (let
    [owned-name : String (string_mod.string-copy-borrowed name)]
    (if (stdlib.env.env-var-exists? owned-name)
      (EnvSomeString (stdlib.env.env-var-value owned-name))
      stdlib.env.EnvNoString)))

;: Split a PATH-style string using the supplied one-byte separator string.
(define (env-path-split-with-separator-vec
  [value : (& value str)]
  [separator : (& separator str)]) : vector_mod.StringVec
  (let
    [n : i64 (string-length value)]
    (if (= n 0)
      (vector_mod.string-vec-new)
      (let
        [sep : char (string-ref separator 0)]
        [items : vector_mod.StringVec (vector_mod.string-vec-new)]
        [start : i64 0]
        [i : i64 0]
        (begin
          (while (< i n)
            (if (string_mod.char-eq (string-ref value i) sep)
              (begin
                (set!
                  items
                  (vector_mod.string-vec-push
                    items
                    (string_mod.substring-borrowed value start (- i start))))
                (set! start (+ i 1))
                (set! i (+ i 1)))
              (set! i (+ i 1))))
          (vector_mod.string-vec-push
            items
            (string_mod.substring-borrowed value start (- n start))))))))

;: Split a PATH-style string using the supplied one-byte separator string.
(define (env-path-split-with-separator
  [value : (& value str)]
  [separator : (& separator str)]) : EnvStringList
  (stdlib.env.env-string-list-from-vec
    (stdlib.env.env-path-split-with-separator-vec value separator)))

;: Split a PATH-style string using the current platform separator.
(define (env-path-split-vec [value : (& value str)]) : vector_mod.StringVec
  (let
    [separator : String (stdlib.env.env-path-list-separator)]
    (stdlib.env.env-path-split-with-separator-vec value (& separator))))

;: Split a PATH-style string using the current platform separator.
(define (env-path-split [value : (& value str)]) : EnvStringList
  (stdlib.env.env-string-list-from-vec (stdlib.env.env-path-split-vec value)))

;: Read `name` and split it as a PATH-style list when present.
(define (env-path-list-vec [name : (& name str)]) : EnvMaybeStringVec
  (match (stdlib.env.env-get name)
    [(EnvSomeString value)
      (EnvSomeStringVec (stdlib.env.env-path-split-vec (& value)))]
    [(EnvNoString) stdlib.env.EnvNoStringVec]))

;: Read `name` and split it as a PATH-style list when present.
(define (env-path-list [name : (& name str)]) : EnvMaybeStringList
  (match (stdlib.env.env-path-list-vec name)
    [(EnvSomeStringVec value)
      (EnvSomeStringList (stdlib.env.env-string-list-from-vec value))]
    [(EnvNoStringVec) stdlib.env.EnvNoStringList]))

;: Append PATH-style `items` to `acc`, allocating joined string segments.
(define (env-path-join-tail
  [acc : String]
  [items : EnvStringList]
  [separator : (& separator str)]) : String
  (match items
    [(EnvStringNil) acc]
    [(EnvStringCons head rest)
      (stdlib.env.env-path-join-tail
        (let
          [acc-with-separator : String
            (string_mod.string-append-borrowed (& acc) separator)]
          (string_mod.string-append acc-with-separator head))
        (box-get rest)
        separator)]))

;: Join PATH-style items using the supplied separator.
(define (env-path-join-vec-tail
  [acc : String]
  [items : vector_mod.StringVec]
  [index : i64]
  [separator : (& separator str)]) : String
  (if (>= index (vector_mod.string-vec-len items))
    acc
    (stdlib.env.env-path-join-vec-tail
      (let
        [acc-with-separator : String
          (string_mod.string-append-borrowed (& acc) separator)]
        (string_mod.string-append
          acc-with-separator
          (vector_mod.string-vec-get items index "")))
      items
      (+ index 1)
      separator)))

;: Join PATH-style items using the supplied separator.
(define (env-path-join-vec-with-separator
  [items : vector_mod.StringVec]
  [separator : (& separator str)]) : String
  (if (<= (vector_mod.string-vec-len items) 0)
    ""
    (stdlib.env.env-path-join-vec-tail
      (vector_mod.string-vec-get items 0 "")
      items
      1
      separator)))

;: Join PATH-style items using the current platform separator.
(define (env-path-join-vec [items : vector_mod.StringVec]) : String
  (let
    [separator : String (stdlib.env.env-path-list-separator)]
    (stdlib.env.env-path-join-vec-with-separator items (& separator))))

;: Join PATH-style items using the supplied separator.
(define (env-path-join-with-separator
  [items : EnvStringList]
  [separator : (& separator str)]) : String
  (stdlib.env.env-path-join-vec-with-separator
    (stdlib.env.env-string-list-to-vec items)
    separator))

;: Join PATH-style items using the current platform separator.
(define (env-path-join [items : EnvStringList]) : String
  (stdlib.env.env-path-join-vec (stdlib.env.env-string-list-to-vec items)))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value env-c-string-length)
  (value env-copy-c-string)
  (value env-ascii-fold)
  (value env-match-entry)
  (value env-getenv-ptr-linux)
  (value env-getenv-ptr)
  (value env-var-exists?)
  (value env-var-value)
  (value env-path-separator)
  (value env-string-list-empty)
  (value env-string-list-cons)
  (value env-string-list-reverse-onto)
  (value env-string-list-reverse)
  (value env-string-list-from-vec-from)
  (value env-string-list-from-vec)
  (value env-string-list-to-vec-into)
  (value env-string-list-to-vec)
  (value env-path-list-separator)
  (value env-get)
  (value env-path-split-with-separator-vec)
  (value env-path-split-with-separator)
  (value env-path-split-vec)
  (value env-path-split)
  (value env-path-list-vec)
  (value env-path-list)
  (value env-path-join-tail)
  (value env-path-join-vec-tail)
  (value env-path-join-vec-with-separator)
  (value env-path-join-vec)
  (value env-path-join-with-separator)
  (value env-path-join)
  (type EnvMaybeString)
  (type EnvStringList)
  (type EnvMaybeStringList)
  (type EnvMaybeStringVec)
  (variant EnvNoString)
  (variant EnvSomeString)
  (variant EnvStringNil)
  (variant EnvStringCons)
  (variant EnvNoStringList)
  (variant EnvSomeStringList)
  (variant EnvNoStringVec)
  (variant EnvSomeStringVec))

(cfg
  windows
  (export
    (value env-win-get-environment-strings)
    (value env-getenv-ptr-windows)))