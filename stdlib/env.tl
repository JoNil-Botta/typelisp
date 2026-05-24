;;;; stdlib/env.tl - Environment helpers for TypeLisp selfhost tools (#854).

;;;;

;;;; Provides recoverable environment-variable lookup and PATH-style list

;;;; helpers on top of compiler/runtime primitives.

;;;;

;;;; Primitives required from the compiler/runtime:

;;;;   env-var-exists?, env-var-value, env-path-separator-raw,

;;;;   string-length, string-ref, substring, string-append, string-eq

;;;;

;;;; Usage: (import "stdlib/env.tl")

(import "stdlib/process.tl")

(defenum EnvMaybeString
  (EnvMissing)
  (EnvSome String))

(defenum EnvPathList
  (EnvPathNil)
  (EnvPathCons String EnvPathList))

(defenum EnvPathListResult
  (OkEnvPathList EnvPathList)
  (ErrEnvPathList String))

;;; Return true when `name` is present in the process environment.

(define (env-present? [name : String]) : bool
  (env-var-exists? name))

;;; Return the value of `name`, or `EnvMissing` when it is absent.

(define (env-get [name : String]) : EnvMaybeString
  (if (env-var-exists? name)
    (EnvSome (env-var-value name))
    (EnvMissing)))

;;; Return the value of `name`, or `fallback` when it is absent.

(define (env-get-or [name : String] [fallback : String]) : String
  (match (env-get name)
    [(EnvSome value) value]
    [(EnvMissing) fallback]))

;;; Return the host path-list separator as a one-byte String.

(define (env-path-separator) : String
  (env-path-separator-raw))

(define (env-path-list-empty) : EnvPathList
  (EnvPathNil))

(define (env-path-list-cons [value : String] [rest : EnvPathList]) : EnvPathList
  (EnvPathCons value rest))

(define (env-path-list-reverse-onto [items : EnvPathList] [acc : EnvPathList]) : EnvPathList
  (match items
    [(EnvPathNil) acc]
    [(EnvPathCons head rest)
      (env-path-list-reverse-onto rest (EnvPathCons head acc))]))

(define (env-path-list-reverse [items : EnvPathList]) : EnvPathList
  (env-path-list-reverse-onto items EnvPathNil))

(define (env-path-list-count [items : EnvPathList]) : i64
  (match items
    [(EnvPathNil) 0]
    [(EnvPathCons _ rest) (+ 1 (env-path-list-count rest))]))

;;; Split a PATH-style string using `separator`.

;;;

;;; Empty environment values produce an empty list. Empty interior or trailing

;;; segments are preserved so joining a non-empty split list round-trips exactly.

(define (env-split-path-list-with-separator
  [value : String]
  [separator : String]) : EnvPathList
  (let ([n : i64 (string-length value)])
    (if (= n 0)
      EnvPathNil
      (let ([sep : char (string-ref separator 0)]
        [start : i64 0]
        [i : i64 0]
        [items : EnvPathList EnvPathNil])
        (begin
          (while (<= i n)
            (if (= i n)
              (begin
                (set!
                  items
                  (EnvPathCons (substring value start (- i start)) items))
                (set! i (+ i 1)))
              (if (= (cast (string-ref value i) : i64) (cast sep : i64))
                (begin
                  (set!
                    items
                    (EnvPathCons (substring value start (- i start)) items))
                  (set! start (+ i 1))
                  (set! i (+ i 1)))
                (set! i (+ i 1)))))
          (env-path-list-reverse items))))))

;;; Split a PATH-style string using the current host separator.

(define (env-split-path-list [value : String]) : EnvPathList
  (env-split-path-list-with-separator value (env-path-separator)))

;;; Read and split the PATH-style variable `name`.

(define (env-path-list [name : String]) : EnvPathListResult
  (match (env-get name)
    [(EnvSome value) (OkEnvPathList (env-split-path-list value))]
    [(EnvMissing) (ErrEnvPathList "env: variable is not set")]))

;;; Join a list of path entries using `separator`.

(define (env-path-join-with-separator
  [items : EnvPathList]
  [separator : String]) : String
  (match items
    [(EnvPathNil) ""]
    [(EnvPathCons head rest)
      (match rest
        [(EnvPathNil) head]
        [(EnvPathCons _ _)
          (string-append
            head
            (string-append
              separator
              (env-path-join-with-separator rest separator)))])]))

;;; Join a list of path entries using the current host separator.

(define (env-path-join [items : EnvPathList]) : String
  (env-path-join-with-separator items (env-path-separator)))

;;; Add an environment override to a process command.

(define (env-process-command-with
  [command : ProcessCommand]
  [name : String]
  [value : String]) : ProcessCommand
  (process-command-with-env command name value))

;;; Add an environment override only when the value is present.

(define (env-process-command-with-maybe
  [command : ProcessCommand]
  [name : String]
  [value : EnvMaybeString]) : ProcessCommand
  (match value
    [(EnvSome text) (process-command-with-env command name text)]
    [(EnvMissing) command]))