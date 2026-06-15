(import stdlib.process)

(import stdlib.test)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (assert-process-string-list
  [items : process.ProcessStringList]
  [first : String]
  [second : String]
  [message : String]) : unit
  (match items
    [(process.ProcessStringCons a rest)
      (match (box-get rest)
        [(process.ProcessStringCons b tail)
          (match (box-get tail)
            [(process.ProcessStringNil)
              (begin
                (assert-owned-string-eq a first message)
                (assert-owned-string-eq b second message))]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-process-string-list3
  [items : process.ProcessStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (match items
    [(process.ProcessStringCons a rest)
      (match (box-get rest)
        [(process.ProcessStringCons b more)
          (match (box-get more)
            [(process.ProcessStringCons c tail)
              (match (box-get tail)
                [(process.ProcessStringNil)
                  (begin
                    (assert-owned-string-eq a first message)
                    (assert-owned-string-eq b second message)
                    (assert-owned-string-eq c third message))]
                [_ (panic message)])]
            [_ (panic message)])]
        [_ (panic message)])]
    [_ (panic message)]))

(define (assert-process-some-string
  [value : process.ProcessMaybeString]
  [expected : String]
  [message : String]) : unit
  (match value
    [(process.ProcessSomeString actual)
      (assert-owned-string-eq actual expected message)]
    [(process.ProcessNoString) (panic message)]))

(define (assert-process-no-string
  [value : process.ProcessMaybeString]
  [message : String]) : unit
  (match value
    [(process.ProcessNoString) unit]
    [(process.ProcessSomeString _) (panic message)]))

(define (assert-process-env-head
  [env : process.ProcessEnvList]
  [expected-name : String]
  [expected-value : String]
  [message : String]) : unit
  (match env
    [(process.ProcessEnvCons name value _)
      (begin
        (assert-owned-string-eq name expected-name message)
        (assert-owned-string-eq value expected-value message))]
    [(process.ProcessEnvNil) (panic message)]))

(define (assert-process-invalid-command
  [result : process.ResultProcessOutput]
  [message : String]) : unit
  (match result
    [(process.ErrProcessOutput error)
      (begin
        (test.assert-true (process.process-error-invalid-command? error) message)
        (assert-owned-string-eq (process.process-error-message error) message message))]
    [(process.OkProcessOutput _) (panic message)]))

(define (assert-process-child-invalid-command
  [result : process.ResultProcessChild]
  [message : String]) : unit
  (match result
    [(process.ErrProcessChild error)
      (begin
        (test.assert-true (process.process-error-invalid-command? error) message)
        (assert-owned-string-eq (process.process-error-message error) message message))]
    [(process.OkProcessChild _) (panic message)]))

(define (main) : i64
  (let
    [args : process.ProcessStringList
      (process.process-args-cons
        "hello"
        (process.process-args-cons "world" (process.process-args-empty)))]
    [command : process.ProcessCommand
      (process.process-command-with-arg
        (process.process-command-with-env
          (process.process-command-with-stdin
            (process.process-command-with-cwd (process.process-command "echo" args) "target")
            "stdin")
          "TL_TEST"
          "1")
        "!")]
    (begin
      (assert-owned-string-eq
        (process.process-command-executable command)
        "echo"
        "process executable")
      (assert-process-string-list args "hello" "world" "process argv")
      (assert-process-string-list3
        (process.process-command-argv command)
        "hello"
        "world"
        "!"
        "process argv append")
      (test.assert-i64-eq
        (process.process-args-count (process.process-command-argv command))
        3
        "process argv count")
      (assert-process-string-list3
        (process.process-args-append args (process.process-args-single "again"))
        "hello"
        "world"
        "again"
        "process args append")
      (assert-process-some-string
        (process.process-command-cwd command)
        "target"
        "process cwd")
      (assert-process-some-string
        (process.process-command-stdin command)
        "stdin"
        "process stdin")
      (assert-process-env-head
        (process.process-command-env command)
        "TL_TEST"
        "1"
        "process env")
      (test.assert-i64-eq
        (process.process-env-count (process.process-command-env command))
        1
        "process env count")
      (assert-process-env-head
        (process.process-command-env
          (process.process-command-with-env-list
            command
            (process.process-env-cons "TL_REPLACED" "yes" (process.process-env-empty))))
        "TL_REPLACED"
        "yes"
        "process env list")
      (assert-process-no-string
        (process.process-command-cwd (process.process-command "echo" (process.process-args-empty)))
        "process default cwd")
      (assert-process-invalid-command
        (process.process-output (process.process-command "" (process.process-args-empty)))
        "process: executable path is empty")
      (assert-process-invalid-command
        (process.process-output (process.process-command-with-cwd command ""))
        "process: cwd path is empty")
      (assert-process-invalid-command
        (process.process-output (process.process-command-with-env command "" "1"))
        "process: environment variable name is empty")
      (assert-process-invalid-command
        (process.process-output (process.process-command-with-env command "BAD=NAME" "1"))
        "process: environment variable name contains '='")
      (assert-process-child-invalid-command
        (process.process-start (process.process-command "" (process.process-args-empty)))
        "process: executable path is empty")
      (assert-process-child-invalid-command
        (process.process-start (process.process-command-with-cwd command ""))
        "process: cwd path is empty")
      (assert-process-child-invalid-command
        (process.process-start (process.process-command-with-env command "" "1"))
        "process: environment variable name is empty")
      (assert-process-child-invalid-command
        (process.process-start (process.process-command-with-env command "BAD=NAME" "1"))
        "process: environment variable name contains '='")
      (test.assert-true (process.process-command-valid? command) "process valid command")
      (test.assert-false
        (process.process-command-valid? (process.process-command "" (process.process-args-empty)))
        "process invalid empty executable")
      (test.assert-true
        (process.process-result-success? (process.OkProcessOutput (process.ProcessOutput 0 "" "")))
        "process result success")
      (test.assert-false
        (process.process-result-success? (process.OkProcessOutput (process.ProcessOutput 7 "" "")))
        "process result nonzero")
      (test.assert-false
        (process.process-result-success?
          (process.ErrProcessOutput (process.ProcessSpawnFailed "spawn failed")))
        "process result error")
      (test.assert-true
        (process.process-error-spawn-failed? (process.ProcessSpawnFailed "spawn failed"))
        "process spawn predicate")
      (test.assert-true
        (process.process-error-wait-failed? (process.ProcessWaitFailed "wait failed"))
        "process wait predicate")
      (test.assert-true
        (process.process-child-started? (process.OkProcessChild (process.ProcessChild 1 2 3)))
        "process child started predicate")
      (test.assert-false
        (process.process-child-started?
          (process.ErrProcessChild (process.ProcessUnsupported "unsupported")))
        "process child unsupported predicate")
      42)))