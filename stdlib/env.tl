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
          (env-c-string-length ptr))]
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
              (= (env-ascii-fold ec) (env-ascii-fold nc))
              (= ec nc))
              (set! i (+ i 1))
              (set! ok false))))
        (if (not ok)
          (ptr-null : (Ptr u8))
          (let
            [sep : u8
              (unsafe
                (ptr-read (ptr-offset entry n)))]
            (if (= sep (cast '=' : u8))
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
                    (env-match-entry name entry false))]
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
            (env-win-get-environment-strings))]
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
                    (env-match-entry name p true))]
                (if (ptr-null? value)
                  (set!
                    p
                    (unsafe
                      (ptr-offset
                        p
                        (+
                          (unsafe
                            (env-c-string-length p))
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
        (env-getenv-ptr-windows name))
      (unsafe
        (env-getenv-ptr-linux name)))))

;: Return true when `name` is present in the process environment.
(define (env-var-exists? [name : String]) : bool
  (not
    (ptr-null?
      (unsafe
        (env-getenv-ptr name)))))

;: Return the value of `name`, or an empty string when the variable is missing.
(define (env-var-value [name : String]) : String
  (let
    [value : (Ptr u8)
      (unsafe
        (env-getenv-ptr name))]
    (if (ptr-null? value)
      ""
      (unsafe
        (env-copy-c-string value)))))

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
  (EnvSomeStringVec vector.StringVec))

;: Return a present environment string result.
(define (env-some-string [value : String]) : EnvMaybeString
  (EnvSomeString value))

;: Return a present PATH-style string-list result.
(define (env-some-string-list [value : EnvStringList]) : EnvMaybeStringList
  (EnvSomeStringList value))

;: Return a present PATH-style string-vector result.
(define (env-some-string-vec [value : vector.StringVec]) : EnvMaybeStringVec
  (EnvSomeStringVec value))

;: Return an empty environment string list.
(define (env-string-list-empty) : EnvStringList
  EnvStringNil)

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
      (env-string-list-reverse-onto
        (box-get rest)
        (EnvStringCons head (box acc)))]))

;: Return `items` in reverse order.
(define (env-string-list-reverse [items : EnvStringList]) : EnvStringList
  (env-string-list-reverse-onto items EnvStringNil))

(import stdlib.string)
(import stdlib.vector)

;: Build an environment string list from `items`, preserving vector order.
(define (env-string-list-from-vec-from
  [items : vector.StringVec]
  [index : i64]
  [acc : EnvStringList]) : EnvStringList
  (if (< index 0)
    acc
    (env-string-list-from-vec-from
      items
      (- index 1)
      (env-string-list-cons (vector.string-vec-get items index "") acc))))

;: Build an environment string list from `items`, preserving vector order.
(define (env-string-list-from-vec [items : vector.StringVec]) : EnvStringList
  (env-string-list-from-vec-from
    items
    (- (vector.string-vec-len items) 1)
    EnvStringNil))

;: Copy `items` into `out`, preserving list order.
(define (env-string-list-to-vec-into
  [items : EnvStringList]
  [out : vector.StringVec]) : vector.StringVec
  (match items
    [(EnvStringNil) out]
    [(EnvStringCons head rest)
      (env-string-list-to-vec-into
        (box-get rest)
        (vector.string-vec-push out head))]))

;: Copy `items` into a fresh `StringVec`, preserving list order.
(define (env-string-list-to-vec [items : EnvStringList]) : vector.StringVec
  (env-string-list-to-vec-into items (vector.string-vec-new)))

;: Return the current platform PATH-list separator as a one-byte String.
(define (env-path-list-separator) : String
  (env-path-separator))

;: Return the value of `name`, or `EnvNoString` when the variable is missing.
(define (env-get [name : (& name str)]) : EnvMaybeString
  (let
    [owned-name : String (string.string-copy-borrowed name)]
    (if (env-var-exists? owned-name)
      (env-some-string (env-var-value owned-name))
      EnvNoString)))

;: Split a PATH-style string using the supplied one-byte separator string.
(define (env-path-split-with-separator-vec
  [value : (& value str)]
  [separator : (& separator str)]) : vector.StringVec
  (let
    [n : i64 (string-length value)]
    (if (= n 0)
      (vector.string-vec-new)
      (let
        [sep : char (string-ref separator 0)]
        [items : vector.StringVec (vector.string-vec-new)]
        [start : i64 0]
        [i : i64 0]
        (begin
          (while (< i n)
            (if (string.char-eq (string-ref value i) sep)
              (begin
                (set!
                  items
                  (vector.string-vec-push
                    items
                    (string.substring-borrowed value start (- i start))))
                (set! start (+ i 1))
                (set! i (+ i 1)))
              (set! i (+ i 1))))
          (vector.string-vec-push
            items
            (string.substring-borrowed value start (- n start))))))))

;: Split a PATH-style string using the supplied one-byte separator string.
(define (env-path-split-with-separator
  [value : (& value str)]
  [separator : (& separator str)]) : EnvStringList
  (env-string-list-from-vec (env-path-split-with-separator-vec value separator)))

;: Split a PATH-style string using the current platform separator.
(define (env-path-split-vec [value : (& value str)]) : vector.StringVec
  (let
    [separator : String (env-path-list-separator)]
    (env-path-split-with-separator-vec value (& separator))))

;: Split a PATH-style string using the current platform separator.
(define (env-path-split [value : (& value str)]) : EnvStringList
  (env-string-list-from-vec (env-path-split-vec value)))

;: Read `name` and split it as a PATH-style list when present.
(define (env-path-list-vec [name : (& name str)]) : EnvMaybeStringVec
  (match (env-get name)
    [(EnvSomeString value) (env-some-string-vec (env-path-split-vec (& value)))]
    [(EnvNoString) EnvNoStringVec]))

;: Read `name` and split it as a PATH-style list when present.
(define (env-path-list [name : (& name str)]) : EnvMaybeStringList
  (match (env-path-list-vec name)
    [(EnvSomeStringVec value)
      (env-some-string-list (env-string-list-from-vec value))]
    [(EnvNoStringVec) EnvNoStringList]))

;: Append PATH-style `items` to `acc`, allocating joined string segments.
(define (env-path-join-tail
  [acc : String]
  [items : EnvStringList]
  [separator : (& separator str)]) : String
  (match items
    [(EnvStringNil) acc]
    [(EnvStringCons head rest)
      (env-path-join-tail
        (let
          [acc-with-separator : String
            (string.string-append-borrowed (& acc) separator)]
          (string.string-append acc-with-separator head))
        (box-get rest)
        separator)]))

;: Join PATH-style items using the supplied separator.
(define (env-path-join-vec-tail
  [acc : String]
  [items : vector.StringVec]
  [index : i64]
  [separator : (& separator str)]) : String
  (if (>= index (vector.string-vec-len items))
    acc
    (env-path-join-vec-tail
      (let
        [acc-with-separator : String
          (string.string-append-borrowed (& acc) separator)]
        (string.string-append
          acc-with-separator
          (vector.string-vec-get items index "")))
      items
      (+ index 1)
      separator)))

;: Join PATH-style items using the supplied separator.
(define (env-path-join-vec-with-separator
  [items : vector.StringVec]
  [separator : (& separator str)]) : String
  (if (<= (vector.string-vec-len items) 0)
    ""
    (env-path-join-vec-tail
      (vector.string-vec-get items 0 "")
      items
      1
      separator)))

;: Join PATH-style items using the current platform separator.
(define (env-path-join-vec [items : vector.StringVec]) : String
  (let
    [separator : String (env-path-list-separator)]
    (env-path-join-vec-with-separator items (& separator))))

;: Join PATH-style items using the supplied separator.
(define (env-path-join-with-separator
  [items : EnvStringList]
  [separator : (& separator str)]) : String
  (env-path-join-vec-with-separator (env-string-list-to-vec items) separator))

;: Join PATH-style items using the current platform separator.
(define (env-path-join [items : EnvStringList]) : String
  (env-path-join-vec (env-string-list-to-vec items)))

;: Inline test helper that forces a test failure without importing `io.tl`.
(define (env-test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test assertion for boolean predicates.
(define (env-test-assert-true [condition : bool] [_message : String]) : unit
  (if condition
    unit
    (env-test-fail)))

;: Inline test assertion for `i64` equality.
(define (env-test-assert-i64-eq
  [actual : i64]
  [expected : i64]
  [message : String]) : unit
  (env-test-assert-true (= actual expected) message))

;: Inline test assertion for owned string equality.
(define (env-test-assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (env-test-assert-true (string.string-eq actual expected) message))

;: Assert that an environment lookup is missing.
(define (env-test-assert-none [value : EnvMaybeString] [_message : String]) : unit
  (match value
    [(EnvNoString) unit]
    [(EnvSomeString _) (env-test-fail)]))

;: Assert that an environment lookup is present with `expected`.
(define (env-test-assert-some
  [value : EnvMaybeString]
  [expected : String]
  [message : String]) : unit
  (match value
    [(EnvSomeString actual)
      (env-test-assert-owned-string-eq actual expected message)]
    [(EnvNoString) (env-test-fail)]))

;: Assert that an environment path-list lookup is missing.
(define (env-test-assert-path-none
  [value : EnvMaybeStringList]
  [_message : String]) : unit
  (match value
    [(EnvNoStringList) unit]
    [(EnvSomeStringList _) (env-test-fail)]))

;: Assert that an environment path-vector lookup is missing.
(define (env-test-assert-path-vec-none
  [value : EnvMaybeStringVec]
  [_message : String]) : unit
  (match value
    [(EnvNoStringVec) unit]
    [(EnvSomeStringVec _) (env-test-fail)]))

;: Assert that an environment path-list lookup returns an empty list.
(define (env-test-assert-path-empty
  [value : EnvMaybeStringList]
  [_message : String]) : unit
  (match value
    [(EnvSomeStringList items)
      (match items
        [(EnvStringNil) unit]
        [_ (env-test-fail)])]
    [(EnvNoStringList) (env-test-fail)]))

;: Assert that an environment path-vector lookup returns an empty vector.
(define (env-test-assert-path-vec-empty
  [value : EnvMaybeStringVec]
  [message : String]) : unit
  (match value
    [(EnvSomeStringVec items)
      (env-test-assert-i64-eq (vector.string-vec-len items) 0 message)]
    [(EnvNoStringVec) (env-test-fail)]))

;: Assert that an environment string list contains exactly three strings.
(define (env-test-assert-list3
  [items : EnvStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match items
    [(EnvStringCons a rest)
      (match (box-get rest)
        [(EnvStringCons b tail)
          (match (box-get tail)
            [(EnvStringCons c end)
              (match (box-get end)
                [(EnvStringNil)
                  (begin
                    (env-test-assert-owned-string-eq a first message)
                    (env-test-assert-owned-string-eq b second message)
                    (env-test-assert-owned-string-eq c third message))]
                [_ (env-test-fail)])]
            [_ (env-test-fail)])]
        [_ (env-test-fail)])]
    [_ (env-test-fail)]))

;: Assert that an environment string list contains exactly five strings.
(define (env-test-assert-list5
  [items : EnvStringList]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [fifth : String]
  [message : String]) : unit
  (match items
    [(EnvStringCons a rest)
      (match (box-get rest)
        [(EnvStringCons b rest2)
          (match (box-get rest2)
            [(EnvStringCons c rest3)
              (match (box-get rest3)
                [(EnvStringCons d rest4)
                  (match (box-get rest4)
                    [(EnvStringCons e end)
                      (match (box-get end)
                        [(EnvStringNil)
                          (begin
                            (env-test-assert-owned-string-eq a first message)
                            (env-test-assert-owned-string-eq b second message)
                            (env-test-assert-owned-string-eq c third message)
                            (env-test-assert-owned-string-eq d fourth message)
                            (env-test-assert-owned-string-eq e fifth message))]
                        [_ (env-test-fail)])]
                    [_ (env-test-fail)])]
                [_ (env-test-fail)])]
            [_ (env-test-fail)])]
        [_ (env-test-fail)])]
    [_ (env-test-fail)]))

;: Assert that a string vector contains exactly three strings.
(define (env-test-assert-vec3
  [items : vector.StringVec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (begin
    (env-test-assert-i64-eq (vector.string-vec-len items) 3 message)
    (env-test-assert-owned-string-eq
      (vector.string-vec-get items 0 "missing")
      first
      message)
    (env-test-assert-owned-string-eq
      (vector.string-vec-get items 1 "missing")
      second
      message)
    (env-test-assert-owned-string-eq
      (vector.string-vec-get items 2 "missing")
      third
      message)))

;: Assert that a string vector contains exactly five strings.
(define (env-test-assert-vec5
  [items : vector.StringVec]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [fifth : String]
  [message : String]) : unit
  (begin
    (env-test-assert-i64-eq (vector.string-vec-len items) 5 message)
    (env-test-assert-owned-string-eq
      (vector.string-vec-get items 0 "missing")
      first
      message)
    (env-test-assert-owned-string-eq
      (vector.string-vec-get items 1 "missing")
      second
      message)
    (env-test-assert-owned-string-eq
      (vector.string-vec-get items 2 "missing")
      third
      message)
    (env-test-assert-owned-string-eq
      (vector.string-vec-get items 3 "missing")
      fourth
      message)
    (env-test-assert-owned-string-eq
      (vector.string-vec-get items 4 "missing")
      fifth
      message)))

;: Assert that a present path-list lookup contains exactly three strings.
(define (env-test-assert-path3
  [value : EnvMaybeStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match value
    [(EnvSomeStringList items)
      (env-test-assert-list3 items first second third message)]
    [(EnvNoStringList) (env-test-fail)]))

;: Assert that a present path-vector lookup contains exactly three strings.
(define (env-test-assert-path-vec3
  [value : EnvMaybeStringVec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match value
    [(EnvSomeStringVec items)
      (env-test-assert-vec3 items first second third message)]
    [(EnvNoStringVec) (env-test-fail)]))

(export
  (value env-ascii-fold)
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