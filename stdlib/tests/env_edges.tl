(import "stdlib/env.tl")

(import "stdlib/test.tl")

(define (assert-env-some-string
  [value : EnvMaybeString]
  [expected : String]
  [message : String]) : unit
  (match value
    [(EnvSome actual) (assert-string-eq actual expected message)]
    [(EnvMissing) (panic message)]))

(define (assert-env-missing [value : EnvMaybeString] [message : String]) : unit
  (match value
    [(EnvMissing) unit]
    [(EnvSome _) (panic message)]))

(define (assert-env-path-list
  [result : EnvPathListResult]
  [expected-count : i64]
  [expected-joined : String]
  [message : String]) : unit
  (match result
    [(OkEnvPathList items)
      (begin
        (assert-i64-eq (env-path-list-count items) expected-count message)
        (assert-string-eq (env-path-join items) expected-joined message))]
    [(ErrEnvPathList _) (panic message)]))

(define (assert-env-path-list-missing
  [result : EnvPathListResult]
  [message : String]) : unit
  (match result
    [(ErrEnvPathList actual) (assert-string-eq actual message message)]
    [(OkEnvPathList _) (panic message)]))

(define (assert-env-process-override
  [command : ProcessCommand]
  [expected-name : String]
  [expected-value : String]
  [message : String]) : unit
  (match (process-command-env command)
    [(ProcessEnvCons name value _)
      (begin
        (assert-string-eq name expected-name message)
        (assert-string-eq value expected-value message))]
    [(ProcessEnvNil) (panic message)]))

(define (main) : i64
  (let (
    [path-list : String (env-get-or "TYPELISP_STDLIB_ENV_PATH_LIST" "missing")]
    [command : ProcessCommand
      (env-process-command-with
        (process-command "tool" (process-args-empty))
        "TYPELISP_STDLIB_ENV_PRESENT"
        (env-get-or "TYPELISP_STDLIB_ENV_PRESENT" "missing"))])
    (begin
      (assert-env-some-string
        (env-get "TYPELISP_STDLIB_ENV_PRESENT")
        "present-value"
        "present env var")
      (assert-env-some-string
        (env-get "TYPELISP_STDLIB_ENV_EMPTY")
        ""
        "empty env var")
      (assert-env-missing
        (env-get "TYPELISP_STDLIB_ENV_DOES_NOT_EXIST")
        "missing env var")
      (assert-true (env-present? "PATH") "PATH is present")
      (assert-string-eq
        (env-path-separator)
        (env-get-or "TYPELISP_STDLIB_ENV_SEPARATOR" "missing")
        "path separator")
      (assert-env-path-list
        (env-path-list "TYPELISP_STDLIB_ENV_PATH_LIST")
        5
        path-list
        "path list round trip")
      (assert-env-path-list
        (env-path-list "TYPELISP_STDLIB_ENV_EMPTY")
        0
        ""
        "empty path list")
      (assert-env-path-list-missing
        (env-path-list "TYPELISP_STDLIB_ENV_DOES_NOT_EXIST")
        "env: variable is not set")
      (assert-env-process-override
        command
        "TYPELISP_STDLIB_ENV_PRESENT"
        "present-value"
        "process env override")
      42)))