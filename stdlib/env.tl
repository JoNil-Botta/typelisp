;# stdlib/env.tl - Environment variable helpers for TypeLisp.
;#
;# Provides recoverable environment lookup and PATH-style list helpers on top of
;# direct platform C library bindings:
;#
;# `var-exists?`, `var-value`, and `path-separator`. Public
;# list-returning PATH helpers remain for compatibility; vector-returning
;# variants avoid cons/reverse work for new internal callers.
;#
;# Usage: `(import stdlib.env)`
;#
;# ```typelisp
;# (import stdlib.env)
;# (define fallback : env.EnvMaybeString
;#   (let [name : String "TYPELISP_DOC_TEST_MISSING_ENV"] (env.get (& name))))
;# ```
(import stdlib.array)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

;: Windows kernel32 `GetEnvironmentStringsA` binding. Returns
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
  (define (c-string-length [ptr : (Ptr u8)]) : i64
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
  (define (copy-c-string [ptr : (Ptr u8)]) : String
    (let
      [n : i64
        (unsafe
          (c-string-length ptr))]
      [buf : (Array u8) (array.make-array u8 n)]
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
(define (ascii-fold [b : u8]) : u8
  (if (and (>= (cast b : i64) 65) (<= (cast b : i64) 90))
    (cast (+ (cast b : i64) 32) : u8)
    b))

;: True when `name` is the variable name of the C env entry `entry` (a
;: `NAME=VALUE` string). When matched, returns a pointer to the value (just past
;: the `=`); otherwise null. `fold` enables case-insensitive comparison (Windows).
(unsafe
  (define (match-entry [name : String] [entry : (Ptr u8)] [fold : bool]) : (Ptr
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
              (= (ascii-fold ec) (ascii-fold nc))
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
  (define (getenv-ptr-linux [name : String]) : (Ptr u8)
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
                    (match-entry name entry false))]
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
                    (match-entry name p true))]
                (if (ptr-null? value)
                  (set!
                    p
                    (unsafe
                      (ptr-offset
                        p
                        (+
                          (unsafe
                            (c-string-length p))
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
  (define (getenv-ptr [name : String]) : (Ptr u8)
    (cfg
      windows
      (unsafe
        (env-getenv-ptr-windows name))
      (unsafe
        (getenv-ptr-linux name)))))

;: Return true when `name` is present in the process environment.
(define (var-exists? [name : String]) : bool
  (not
    (ptr-null?
      (unsafe
        (getenv-ptr name)))))

;: Return the value of `name`, or an empty string when the variable is missing.
(define (var-value [name : String]) : String
  (let
    [value : (Ptr u8)
      (unsafe
        (getenv-ptr name))]
    (if (ptr-null? value)
      ""
      (unsafe
        (copy-c-string value)))))

;: Return the target platform PATH-list separator as a one-byte String.
(define (path-separator) : String
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
;: present empty variables use `EnvSomeStringVec` with an empty generated string
;: vector.
(defenum EnvMaybeStringVec
  (EnvNoStringVec)
  (EnvSomeStringVec svec.Vec))

;: Return a present environment string result.
(define (some-string [value : String]) : EnvMaybeString
  (EnvSomeString value))

;: Return a present PATH-style string-list result.
(define (some-string-list [value : EnvStringList]) : EnvMaybeStringList
  (EnvSomeStringList value))

;: Return a present PATH-style string-vector result.
(define (some-string-vec [value : svec.Vec]) : EnvMaybeStringVec
  (EnvSomeStringVec value))

;: Return an empty environment string list.
(define (string-list-empty) : EnvStringList
  EnvStringNil)

;: Prepend an owned string to an environment string list.
(define (string-list-cons [value : String] [rest : EnvStringList]) : EnvStringList
  (EnvStringCons value (box rest)))

;: Reverse `items` onto `acc`, allocating a fresh active-arena list spine.
(define (string-list-reverse-onto [items : EnvStringList] [acc : EnvStringList]) : EnvStringList
  (match items
    [(EnvStringNil) acc]
    [(EnvStringCons head rest)
      (string-list-reverse-onto (box-get rest) (EnvStringCons head (box acc)))]))

;: Return `items` in reverse order.
(define (string-list-reverse [items : EnvStringList]) : EnvStringList
  (string-list-reverse-onto items EnvStringNil))

;: Build an environment string list from `items`, preserving vector order.
(define (string-list-from-vec-from
  [items : (& items svec.Vec)]
  [index : i64]
  [acc : EnvStringList]) : EnvStringList
  (if (< index 0)
    acc
    (string-list-from-vec-from
      items
      (- index 1)
      (string-list-cons (svec.get items index "") acc))))

;: Build an environment string list from `items`, preserving vector order.
(define (string-list-from-vec [items : svec.Vec]) : EnvStringList
  (string-list-from-vec-from (& items) (- (svec.len (& items)) 1) EnvStringNil))

;: Copy `items` into `out`, preserving list order.
(define (string-list-to-vec-into
  [items : EnvStringList]
  [out : (&mut out svec.Vec)]) : unit
  (match items
    [(EnvStringNil) unit]
    [(EnvStringCons head rest)
      (begin
        (svec.push-ref! out head)
        (string-list-to-vec-into (box-get rest) out))]))

;: Copy `items` into a fresh generated string vector, preserving list order.
(define (string-list-to-vec [items : EnvStringList]) : svec.Vec
  (let
    [out : svec.Vec (svec.new)]
    (begin
      (string-list-to-vec-into items (&mut out))
      out)))

;: Return the current platform PATH-list separator as a one-byte String.
(define (path-list-separator) : String
  (path-separator))

;: Return the value of `name`, or `EnvNoString` when the variable is missing.
(define (get [name : (& name str)]) : EnvMaybeString
  (let
    [owned-name : String (string.copy name)]
    (if (var-exists? owned-name)
      (some-string (var-value owned-name))
      EnvNoString)))

;: Split a PATH-style string using the supplied one-byte separator string.
(define (path-split-with-separator-vec
  [value : (& value str)]
  [separator : (& separator str)]) : svec.Vec
  (let
    [n : i64 (string-length value)]
    (if (= n 0)
      (svec.new)
      (let
        [sep : char (string-ref separator 0)]
        [items : svec.Vec (svec.new)]
        [start : i64 0]
        [i : i64 0]
        (begin
          (while (< i n)
            (if (string.char-eq (string-ref value i) sep)
              (begin
                (svec.push! items (string.substring value start (- i start)))
                (set! start (+ i 1))
                (set! i (+ i 1)))
              (set! i (+ i 1))))
          (svec.push! items (string.substring value start (- n start)))
          items)))))

;: Split a PATH-style string using the supplied one-byte separator string.
(define (path-split-with-separator
  [value : (& value str)]
  [separator : (& separator str)]) : EnvStringList
  (string-list-from-vec (path-split-with-separator-vec value separator)))

;: Split a PATH-style string using the current platform separator.
(define (path-split-vec [value : (& value str)]) : svec.Vec
  (let
    [separator : String (path-list-separator)]
    (path-split-with-separator-vec value (& separator))))

;: Split a PATH-style string using the current platform separator.
(define (path-split [value : (& value str)]) : EnvStringList
  (string-list-from-vec (path-split-vec value)))

;: Read `name` and split it as a PATH-style list when present.
(define (path-list-vec [name : (& name str)]) : EnvMaybeStringVec
  (match (get name)
    [(EnvSomeString value) (some-string-vec (path-split-vec (& value)))]
    [(EnvNoString) EnvNoStringVec]))

;: Read `name` and split it as a PATH-style list when present.
(define (path-list [name : (& name str)]) : EnvMaybeStringList
  (match (path-list-vec name)
    [(EnvSomeStringVec value) (some-string-list (string-list-from-vec value))]
    [(EnvNoStringVec) EnvNoStringList]))

;: Append PATH-style `items` to `acc`, allocating joined string segments.
(define (path-join-tail
  [acc : String]
  [items : EnvStringList]
  [separator : (& separator str)]) : String
  (match items
    [(EnvStringNil) acc]
    [(EnvStringCons head rest)
      (path-join-tail
        (let
          [acc-with-separator : String (string.append (& acc) separator)]
          (string.append acc-with-separator head))
        (box-get rest)
        separator)]))

;: Join PATH-style items using the supplied separator.
(define (path-join-vec-tail
  [acc : String]
  [items : (& items svec.Vec)]
  [index : i64]
  [separator : (& separator str)]) : String
  (if (>= index (svec.len items))
    acc
    (path-join-vec-tail
      (let
        [acc-with-separator : String (string.append (& acc) separator)]
        (string.append acc-with-separator (svec.get items index "")))
      items
      (+ index 1)
      separator)))

;: Join PATH-style items using the supplied separator.
(define (path-join-vec-with-separator
  [items : svec.Vec]
  [separator : (& separator str)]) : String
  (if (<= (svec.len (& items)) 0)
    ""
    (path-join-vec-tail (svec.get (& items) 0 "") (& items) 1 separator)))

;: Join PATH-style items using the current platform separator.
(define (path-join-vec [items : svec.Vec]) : String
  (let
    [separator : String (path-list-separator)]
    (path-join-vec-with-separator items (& separator))))

;: Join PATH-style items using the supplied separator.
(define (path-join-with-separator
  [items : EnvStringList]
  [separator : (& separator str)]) : String
  (path-join-vec-with-separator (string-list-to-vec items) separator))

;: Join PATH-style items using the current platform separator.
(define (path-join [items : EnvStringList]) : String
  (path-join-vec (string-list-to-vec items)))

;: Inline test helper that forces a test failure without importing `io.tl`.
(define (test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test assertion for boolean predicates.
(define (test-assert-true [condition : bool] [_message : String]) : unit
  (if condition
    unit
    (test-fail)))

;: Inline test assertion for `i64` equality.
(define (test-assert-i64-eq [actual : i64] [expected : i64] [message : String]) : unit
  (test-assert-true (= actual expected) message))

;: Inline test assertion for owned string equality.
(define (test-assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test-assert-true (string.eq actual expected) message))

;: Assert that an environment lookup is missing.
(define (test-assert-none [value : EnvMaybeString] [_message : String]) : unit
  (match value
    [(EnvNoString) unit]
    [(EnvSomeString _) (test-fail)]))

;: Assert that an environment lookup is present with `expected`.
(define (test-assert-some
  [value : EnvMaybeString]
  [expected : String]
  [message : String]) : unit
  (match value
    [(EnvSomeString actual)
      (test-assert-owned-string-eq actual expected message)]
    [(EnvNoString) (test-fail)]))

;: Assert that an environment path-list lookup is missing.
(define (test-assert-path-none [value : EnvMaybeStringList] [_message : String]) : unit
  (match value
    [(EnvNoStringList) unit]
    [(EnvSomeStringList _) (test-fail)]))

;: Assert that an environment path-vector lookup is missing.
(define (test-assert-path-vec-none
  [value : EnvMaybeStringVec]
  [_message : String]) : unit
  (match value
    [(EnvNoStringVec) unit]
    [(EnvSomeStringVec _) (test-fail)]))

;: Assert that an environment path-list lookup returns an empty list.
(define (test-assert-path-empty
  [value : EnvMaybeStringList]
  [_message : String]) : unit
  (match value
    [(EnvSomeStringList items)
      (match items
        [(EnvStringNil) unit]
        [_ (test-fail)])]
    [(EnvNoStringList) (test-fail)]))

;: Assert that an environment path-vector lookup returns an empty vector.
(define (test-assert-path-vec-empty
  [value : EnvMaybeStringVec]
  [message : String]) : unit
  (match value
    [(EnvSomeStringVec items)
      (test-assert-i64-eq (svec.len (& items)) 0 message)]
    [(EnvNoStringVec) (test-fail)]))

;: Assert that an environment string list contains exactly three strings.
(define (test-assert-list3
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
                    (test-assert-owned-string-eq a first message)
                    (test-assert-owned-string-eq b second message)
                    (test-assert-owned-string-eq c third message))]
                [_ (test-fail)])]
            [_ (test-fail)])]
        [_ (test-fail)])]
    [_ (test-fail)]))

;: Assert that an environment string list contains exactly five strings.
(define (test-assert-list5
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
                            (test-assert-owned-string-eq a first message)
                            (test-assert-owned-string-eq b second message)
                            (test-assert-owned-string-eq c third message)
                            (test-assert-owned-string-eq d fourth message)
                            (test-assert-owned-string-eq e fifth message))]
                        [_ (test-fail)])]
                    [_ (test-fail)])]
                [_ (test-fail)])]
            [_ (test-fail)])]
        [_ (test-fail)])]
    [_ (test-fail)]))

;: Assert that a string vector contains exactly three strings.
(define (test-assert-vec3
  [items : svec.Vec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (begin
    (test-assert-i64-eq (svec.len (& items)) 3 message)
    (test-assert-owned-string-eq (svec.get (& items) 0 "missing") first message)
    (test-assert-owned-string-eq
      (svec.get (& items) 1 "missing")
      second
      message)
    (test-assert-owned-string-eq (svec.get (& items) 2 "missing") third message)))

;: Assert that a string vector contains exactly five strings.
(define (test-assert-vec5
  [items : svec.Vec]
  [first : String]
  [second : String]
  [third : String]
  [fourth : String]
  [fifth : String]
  [message : String]) : unit
  (begin
    (test-assert-i64-eq (svec.len (& items)) 5 message)
    (test-assert-owned-string-eq (svec.get (& items) 0 "missing") first message)
    (test-assert-owned-string-eq
      (svec.get (& items) 1 "missing")
      second
      message)
    (test-assert-owned-string-eq (svec.get (& items) 2 "missing") third message)
    (test-assert-owned-string-eq
      (svec.get (& items) 3 "missing")
      fourth
      message)
    (test-assert-owned-string-eq (svec.get (& items) 4 "missing") fifth message)))

;: Assert that a present path-list lookup contains exactly three strings.
(define (test-assert-path3
  [value : EnvMaybeStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match value
    [(EnvSomeStringList items)
      (test-assert-list3 items first second third message)]
    [(EnvNoStringList) (test-fail)]))

;: Assert that a present path-vector lookup contains exactly three strings.
(define (test-assert-path-vec3
  [value : EnvMaybeStringVec]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match value
    [(EnvSomeStringVec items)
      (test-assert-vec3 items first second third message)]
    [(EnvNoStringVec) (test-fail)]))