;# stdlib/env.tl - Environment variable helpers for TypeLisp (#854).
;#
;# Provides recoverable environment lookup and PATH-style list helpers on top of
;# direct platform C library bindings:
;#
;# `env-var-exists?`, `env-var-value`, and `env-path-separator`. Public
;# list-returning PATH helpers remain for compatibility; vector-returning
;# variants avoid cons/reverse work for new internal callers.
;#
;# Usage: `(import "stdlib/env.tl")`
;#
;# ```typelisp
;# (import "stdlib/env.tl")
;# (define fallback : EnvMaybeString
;#   (let [name : String "TYPELISP_DOC_TEST_MISSING_ENV"] (env-get (& name))))
;# ```
(import "string.tl")
(import "vector.tl")

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
  (EnvSomeStringVec StringVec))

;: Return an empty environment string list.
(define (env-string-list-empty) : EnvStringList
  (EnvStringNil))

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
  (env-string-list-reverse-onto items (EnvStringNil)))

;: Build an environment string list from `items`, preserving vector order.
(define (env-string-list-from-vec-from
  [items : StringVec]
  [index : i64]
  [acc : EnvStringList]) : EnvStringList
  (if (< index 0)
    acc
    (env-string-list-from-vec-from
      items
      (- index 1)
      (EnvStringCons (string-vec-get items index "") (box acc)))))

;: Build an environment string list from `items`, preserving vector order.
(define (env-string-list-from-vec [items : StringVec]) : EnvStringList
  (env-string-list-from-vec-from
    items
    (- (string-vec-len items) 1)
    (EnvStringNil)))

;: Copy `items` into `out`, preserving list order.
(define (env-string-list-to-vec-into [items : EnvStringList] [out : StringVec]) : StringVec
  (match items
    [(EnvStringNil) out]
    [(EnvStringCons head rest)
      (env-string-list-to-vec-into (box-get rest) (string-vec-push out head))]))

;: Copy `items` into a fresh `StringVec`, preserving list order.
(define (env-string-list-to-vec [items : EnvStringList]) : StringVec
  (env-string-list-to-vec-into items (string-vec-new)))

;: Return the current platform PATH-list separator as a one-byte String.
(define (env-path-list-separator) : String
  (env-path-separator))

;: Return the value of `name`, or `EnvNoString` when the variable is missing.
(define (env-get [name : (& name str)]) : EnvMaybeString
  (let
    [owned-name : String (string-copy-borrowed name)]
    (if (env-var-exists? owned-name)
      (EnvSomeString (env-var-value owned-name))
      (EnvNoString))))

;: Split a PATH-style string using the supplied one-byte separator string.
(define (env-path-split-with-separator-vec
  [value : (& value str)]
  [separator : (& separator str)]) : StringVec
  (let
    [n : i64 (string-length value)]
    (if (= n 0)
      (string-vec-new)
      (let
        [sep : char (string-ref separator 0)]
        [items : StringVec (string-vec-new)]
        [start : i64 0]
        [i : i64 0]
        (begin
          (while (< i n)
            (if (char-eq (string-ref value i) sep)
              (begin
                (set!
                  items
                  (string-vec-push
                    items
                    (substring-borrowed value start (- i start))))
                (set! start (+ i 1))
                (set! i (+ i 1)))
              (set! i (+ i 1))))
          (string-vec-push items (substring-borrowed value start (- n start))))))))

;: Split a PATH-style string using the supplied one-byte separator string.
(define (env-path-split-with-separator
  [value : (& value str)]
  [separator : (& separator str)]) : EnvStringList
  (env-string-list-from-vec (env-path-split-with-separator-vec value separator)))

;: Split a PATH-style string using the current platform separator.
(define (env-path-split-vec [value : (& value str)]) : StringVec
  (let
    [separator : String (env-path-list-separator)]
    (env-path-split-with-separator-vec value (& separator))))

;: Split a PATH-style string using the current platform separator.
(define (env-path-split [value : (& value str)]) : EnvStringList
  (env-string-list-from-vec (env-path-split-vec value)))

;: Read `name` and split it as a PATH-style list when present.
(define (env-path-list-vec [name : (& name str)]) : EnvMaybeStringVec
  (match (env-get name)
    [(EnvSomeString value) (EnvSomeStringVec (env-path-split-vec (& value)))]
    [(EnvNoString) (EnvNoStringVec)]))

;: Read `name` and split it as a PATH-style list when present.
(define (env-path-list [name : (& name str)]) : EnvMaybeStringList
  (match (env-path-list-vec name)
    [(EnvSomeStringVec value)
      (EnvSomeStringList (env-string-list-from-vec value))]
    [(EnvNoStringVec) (EnvNoStringList)]))

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
            (string-append-borrowed (& acc) separator)]
          (string-append acc-with-separator head))
        (box-get rest)
        separator)]))

;: Join PATH-style items using the supplied separator.
(define (env-path-join-vec-tail
  [acc : String]
  [items : StringVec]
  [index : i64]
  [separator : (& separator str)]) : String
  (if (>= index (string-vec-len items))
    acc
    (env-path-join-vec-tail
      (let
        [acc-with-separator : String (string-append-borrowed (& acc) separator)]
        (string-append acc-with-separator (string-vec-get items index "")))
      items
      (+ index 1)
      separator)))

;: Join PATH-style items using the supplied separator.
(define (env-path-join-vec-with-separator
  [items : StringVec]
  [separator : (& separator str)]) : String
  (if (<= (string-vec-len items) 0)
    ""
    (env-path-join-vec-tail (string-vec-get items 0 "") items 1 separator)))

;: Join PATH-style items using the current platform separator.
(define (env-path-join-vec [items : StringVec]) : String
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
(define (env-test-assert-true [condition : bool] [message : String]) : unit
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
  (env-test-assert-true (string-eq actual expected) message))

;: Assert that an environment lookup is missing.
(define (env-test-assert-none [value : EnvMaybeString] [message : String]) : unit
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
  [message : String]) : unit
  (match value
    [(EnvNoStringList) unit]
    [(EnvSomeStringList _) (env-test-fail)]))

;: Assert that an environment path-vector lookup is missing.
(define (env-test-assert-path-vec-none
  [value : EnvMaybeStringVec]
  [message : String]) : unit
  (match value
    [(EnvNoStringVec) unit]
    [(EnvSomeStringVec _) (env-test-fail)]))

;: Assert that an environment path-list lookup returns an empty list.
(define (env-test-assert-path-empty
  [value : EnvMaybeStringList]
  [message : String]) : unit
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
      (env-test-assert-i64-eq (string-vec-len items) 0 message)]
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
  [items : StringVec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (begin
    (env-test-assert-i64-eq (string-vec-len items) 3 message)
    (env-test-assert-owned-string-eq
      (string-vec-get items 0 "missing")
      first
      message)
    (env-test-assert-owned-string-eq
      (string-vec-get items 1 "missing")
      second
      message)
    (env-test-assert-owned-string-eq
      (string-vec-get items 2 "missing")
      third
      message)))

;: Assert that a string vector contains exactly five strings.
(define (env-test-assert-vec5
  [items : StringVec]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [fifth : String]
  [message : String]) : unit
  (begin
    (env-test-assert-i64-eq (string-vec-len items) 5 message)
    (env-test-assert-owned-string-eq
      (string-vec-get items 0 "missing")
      first
      message)
    (env-test-assert-owned-string-eq
      (string-vec-get items 1 "missing")
      second
      message)
    (env-test-assert-owned-string-eq
      (string-vec-get items 2 "missing")
      third
      message)
    (env-test-assert-owned-string-eq
      (string-vec-get items 3 "missing")
      fourth
      message)
    (env-test-assert-owned-string-eq
      (string-vec-get items 4 "missing")
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

(test
  env-api
  (begin
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (env-test-assert-none (env-get (& name)) "env missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_EMPTY"]
      (match (env-get (& name))
        [(EnvSomeString actual)
          (begin
            (env-test-assert-owned-string-eq actual "" "env empty")
            (env-test-assert-path-empty
              (env-path-list (& name))
              "env path empty")
            (env-test-assert-path-vec-empty
              (env-path-list-vec (& name))
              "env path vec empty"))]
        [(EnvNoString) unit]))
    (let
      [name : String "TYPELISP_STDLIB_TEST_VALUE"]
      (env-test-assert-some (env-get (& name)) "env-value-854" "env value"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (env-test-assert-path-none (env-path-list (& name)) "env path missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_MISSING_854"]
      (env-test-assert-path-vec-none
        (env-path-list-vec (& name))
        "env path vec missing"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_PATH"]
      (env-test-assert-path3
        (env-path-list (& name))
        "one"
        "two"
        "three"
        "env path list"))
    (let
      [name : String "TYPELISP_STDLIB_TEST_PATH"]
      (env-test-assert-path-vec3
        (env-path-list-vec (& name))
        "one"
        "two"
        "three"
        "env path vec"))
    (let
      [value : String (env-var-value "TYPELISP_STDLIB_TEST_PATH")]
      (env-test-assert-owned-string-eq
        (env-path-join (env-path-split (& value)))
        value
        "env path join"))
    (let
      [value : String (env-var-value "TYPELISP_STDLIB_TEST_PATH")]
      (env-test-assert-owned-string-eq
        (env-path-join-vec (env-path-split-vec (& value)))
        value
        "env path vec join"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (env-test-assert-list5
        (env-path-split-with-separator (& value) (& separator))
        "a"
        "b"
        ""
        "c"
        ""
        "env semicolon split"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (env-test-assert-vec5
        (env-path-split-with-separator-vec (& value) (& separator))
        "a"
        "b"
        ""
        "c"
        ""
        "env semicolon split vec"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (env-test-assert-owned-string-eq
        (env-path-join-with-separator
          (env-path-split-with-separator (& value) (& separator))
          (& separator))
        value
        "env semicolon join"))
    (let
      [value : String "a;b;;c;"]
      [separator : String ";"]
      (env-test-assert-owned-string-eq
        (env-path-join-vec-with-separator
          (env-path-split-with-separator-vec (& value) (& separator))
          (& separator))
        value
        "env semicolon join vec"))
    unit))