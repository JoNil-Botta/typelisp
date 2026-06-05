(import "stdlib/process.tl")

(import "stdlib/test.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (assert-process-string-list
  [items : ProcessStringList]
  [first : String]
  [second : String]
  [message : String]) : unit
  (match items
    [(ProcessStringCons a rest)
      (match rest
        [(ProcessStringCons b tail)
          (match tail
            [(ProcessStringNil)
              (begin
                (assert-owned-string-eq a first message)
                (assert-owned-string-eq b second message))]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-process-string-list3
  [items : ProcessStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match items
    [(ProcessStringCons a rest)
      (match rest
        [(ProcessStringCons b more)
          (match more
            [(ProcessStringCons c tail)
              (match tail
                [(ProcessStringNil)
                  (begin
                    (assert-owned-string-eq a first message)
                    (assert-owned-string-eq b second message)
                    (assert-owned-string-eq c third message))]
                [_ (panic message)])]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-process-some-string
  [value : ProcessMaybeString]
  [expected : String]
  [message : String]) : unit
  (match value
    [(ProcessSomeString actual)
      (assert-owned-string-eq actual expected message)]
    [(ProcessNoString) (panic message)]))

(define (assert-process-no-string
  [value : ProcessMaybeString]
  [message : String]) : unit
  (match value
    [(ProcessNoString) unit]
    [(ProcessSomeString _) (panic message)]))

(define (assert-process-env-head
  [env : ProcessEnvList]
  [expected-name : String]
  [expected-value : String]
  [message : String]) : unit
  (match env
    [(ProcessEnvCons name value _)
      (begin
        (assert-owned-string-eq name expected-name message)
        (assert-owned-string-eq value expected-value message))]
    [(ProcessEnvNil) (panic message)]))

(define (assert-process-invalid-command
  [result : ResultProcessOutput]
  [message : String]) : unit
  (match result
    [(ErrProcessOutput error)
      (begin
        (assert-true (process-error-invalid-command? error) message)
        (assert-owned-string-eq (process-error-message error) message message))]
    [(OkProcessOutput _) (panic message)]))

(define (assert-process-child-invalid-command
  [result : ResultProcessChild]
  [message : String]) : unit
  (match result
    [(ErrProcessChild error)
      (begin
        (assert-true (process-error-invalid-command? error) message)
        (assert-owned-string-eq (process-error-message error) message message))]
    [(OkProcessChild _) (panic message)]))

(define (assert-process-child-unsupported
  [result : ResultProcessChild]
  [message : String]) : unit
  (match result
    [(ErrProcessChild error)
      (begin
        (assert-true (process-error-unsupported? error) message)
        (assert-owned-string-eq (process-error-message error) message message))]
    [(OkProcessChild _) (panic message)]))

(define (assert-process-output-unsupported
  [result : ResultProcessOutput]
  [message : String]) : unit
  (match result
    [(ErrProcessOutput error)
      (begin
        (assert-true (process-error-unsupported? error) message)
        (assert-owned-string-eq (process-error-message error) message message))]
    [(OkProcessOutput _) (panic message)]))

(define (main) : i64
  (let
    [args : ProcessStringList
      (process-args-cons
        "hello"
        (process-args-cons "world" (process-args-empty)))]
    [command : ProcessCommand
      (process-command-with-arg
        (process-command-with-env
          (process-command-with-stdin
            (process-command-with-cwd (process-command "echo" args) "target")
            "stdin")
          "TL_TEST"
          "1")
        "!")]
    (begin
      (assert-owned-string-eq
        (process-command-executable command)
        "echo"
        "process executable")
      (assert-process-string-list args "hello" "world" "process argv")
      (assert-process-string-list3
        (process-command-argv command)
        "hello"
        "world"
        "!"
        "process argv append")
      (assert-i64-eq
        (process-args-count (process-command-argv command))
        3
        "process argv count")
      (assert-process-string-list3
        (process-args-append args (process-args-single "again"))
        "hello"
        "world"
        "again"
        "process args append")
      (assert-process-some-string
        (process-command-cwd command)
        "target"
        "process cwd")
      (assert-process-some-string
        (process-command-stdin command)
        "stdin"
        "process stdin")
      (assert-process-env-head
        (process-command-env command)
        "TL_TEST"
        "1"
        "process env")
      (assert-i64-eq
        (process-env-count (process-command-env command))
        1
        "process env count")
      (assert-process-env-head
        (process-command-env
          (process-command-with-env-list
            command
            (process-env-cons "TL_REPLACED" "yes" (process-env-empty))))
        "TL_REPLACED"
        "yes"
        "process env list")
      (assert-process-no-string
        (process-command-cwd (process-command "echo" (process-args-empty)))
        "process default cwd")
      (assert-process-invalid-command
        (process-output (process-command "" (process-args-empty)))
        "process: executable path is empty")
      (assert-process-invalid-command
        (process-output (process-command-with-cwd command ""))
        "process: cwd path is empty")
      (assert-process-invalid-command
        (process-output (process-command-with-env command "" "1"))
        "process: environment variable name is empty")
      (assert-process-invalid-command
        (process-output (process-command-with-env command "BAD=NAME" "1"))
        "process: environment variable name contains '='")
      (assert-process-child-invalid-command
        (process-start (process-command "" (process-args-empty)))
        "process: executable path is empty")
      (assert-process-child-invalid-command
        (process-start (process-command-with-cwd command ""))
        "process: cwd path is empty")
      (assert-process-child-invalid-command
        (process-start (process-command-with-env command "" "1"))
        "process: environment variable name is empty")
      (assert-process-child-invalid-command
        (process-start (process-command-with-env command "BAD=NAME" "1"))
        "process: environment variable name contains '='")
      (assert-true (process-command-valid? command) "process valid command")
      (assert-false
        (process-command-valid? (process-command "" (process-args-empty)))
        "process invalid empty executable")
      (assert-true
        (process-result-success? (OkProcessOutput (ProcessOutput 0 "" "")))
        "process result success")
      (assert-false
        (process-result-success? (OkProcessOutput (ProcessOutput 7 "" "")))
        "process result nonzero")
      (assert-false
        (process-result-success?
          (ErrProcessOutput (ProcessSpawnFailed "spawn failed")))
        "process result error")
      (assert-true
        (process-error-spawn-failed? (ProcessSpawnFailed "spawn failed"))
        "process spawn predicate")
      (assert-true
        (process-error-wait-failed? (ProcessWaitFailed "wait failed"))
        "process wait predicate")
      (assert-true
        (process-child-started? (OkProcessChild (ProcessChild 1 2 3)))
        "process child started predicate")
      (assert-false
        (process-child-started?
          (ErrProcessChild (ProcessUnsupported "unsupported")))
        "process child unsupported predicate")
      (assert-process-child-unsupported
        (process-start command)
        "process: async child handles are not supported by this runtime")
      (assert-process-output-unsupported
        (process-wait (ProcessChild 1 2 3))
        "process: async child handles are not supported by this runtime")
      42)))