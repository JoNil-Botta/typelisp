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

;: Windows kernel32 `GetEnvironmentStringsA` binding (#2142 follow-up). Returns
;: the process environment block: NUL-separated `NAME=VALUE` entries terminated
;: by an empty entry (a trailing double NUL). Replaces the former backend-emitted
;: `getenv` libc shim on Windows; the Linux side walks the SysV stack-captured
;: environment directly. The block is intentionally not freed: the returned value
;: pointer is copied by the caller before any further allocation, and these CLI
;: tools are short-lived.
(cfg
  windows
  (extern env-win-get-environment-strings (:symbol "GetEnvironmentStringsA") : (->
    (Ptr u8))))

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
                  (EnvStringCons
                    (substring-borrowed value start (- i start))
                    (box items)))
                (set! start (+ i 1))
                (set! i (+ i 1)))
              (set! i (+ i 1))))
          (env-string-list-reverse
            (EnvStringCons
              (substring-borrowed value start (- n start))
              (box items))))))))

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
        (let
          [acc-with-separator : String
            (string-append-borrowed (& acc) separator)]
          (string-append acc-with-separator head))
        (box-get rest)
        separator)]))

;: Join PATH-style items using the supplied separator.
(define (env-path-join-with-separator
  [items : EnvStringList]
  [separator : (& separator str)]) : String
  (match items
    [(EnvStringNil) ""]
    [(EnvStringCons head rest)
      (env-path-join-tail head (box-get rest) separator)]))

;: Join PATH-style items using the current platform separator.
(define (env-path-join [items : EnvStringList]) : String
  (let
    [separator : String (env-path-list-separator)]
    (env-path-join-with-separator items (& separator))))