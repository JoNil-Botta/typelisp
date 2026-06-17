(import "stdlib/process.tl")
(import "stdlib/test.tl")
(import "stdlib/vector.tl")

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
      (match (box-get rest)
        [(ProcessStringCons b tail)
          (match (box-get tail)
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
      (match (box-get rest)
        [(ProcessStringCons b more)
          (match (box-get more)
            [(ProcessStringCons c tail)
              (match (box-get tail)
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

(define (assert-process-env-list2
  [env : ProcessEnvList]
  [first-name : String]
  [first-value : String]
  [second-name : String]
  [second-value : String]
  [message : String]) : unit
  (match env
    [(ProcessEnvCons name value rest)
      (begin
        (assert-owned-string-eq name first-name message)
        (assert-owned-string-eq value first-value message)
        (match (box-get rest)
          [(ProcessEnvCons next-name next-value tail)
            (begin
              (assert-owned-string-eq next-name second-name message)
              (assert-owned-string-eq next-value second-value message)
              (match (box-get tail)
                [(ProcessEnvNil) unit]
                [_ (panic message)]))]
          [(ProcessEnvNil) (panic message)]))]
    [(ProcessEnvNil) (panic message)]))

(define (assert-process-env-validation
  [value : ProcessMaybeString]
  [expected : String]
  [message : String]) : unit
  (match value
    [(ProcessSomeString actual)
      (assert-owned-string-eq actual expected message)]
    [(ProcessNoString) (panic message)]))

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
      (let
        [env-vec-empty : ProcessEnvVec (process-env-vec-new)]
        [env-vec : ProcessEnvVec
          (process-env-vec-append
            (process-env-vec-append (process-env-vec-new) "TL_FIRST" "one")
            "TL_SECOND"
            "two")]
        [env-dup : ProcessEnvVec
          (process-env-vec-append
            (process-env-vec-append (process-env-vec-new) "TL_DUP" "first")
            "TL_DUP"
            "second")]
        [bad-shape : ProcessEnvVec
          (ProcessEnvVec
            (string-vec-push (string-vec-new) "ONLY_NAME")
            (string-vec-new))]
        (begin
          (assert-i64-eq
            (process-env-vec-count env-vec-empty)
            0
            "process env vec empty count")
          (assert-true
            (process-env-vec-valid? env-vec-empty)
            "process env vec empty valid")
          (assert-i64-eq
            (process-env-vec-count env-vec)
            2
            "process env vec count")
          (assert-true (process-env-vec-valid? env-vec) "process env vec valid")
          (assert-process-env-list2
            (process-env-vec-to-list env-vec)
            "TL_FIRST"
            "one"
            "TL_SECOND"
            "two"
            "process env vec order")
          (assert-process-env-list2
            (process-command-env (process-command-with-env-vec command env-vec))
            "TL_FIRST"
            "one"
            "TL_SECOND"
            "two"
            "process command env vec order")
          (assert-process-env-list2
            (process-env-vec-to-list env-dup)
            "TL_DUP"
            "first"
            "TL_DUP"
            "second"
            "process env vec duplicate order")
          (assert-process-env-validation
            (process-env-vec-validation-error
              (process-env-vec-append (process-env-vec-new) "" "bad"))
            "process: environment variable name is empty"
            "process env vec empty name")
          (assert-process-env-validation
            (process-env-vec-validation-error
              (process-env-vec-append (process-env-vec-new) "BAD=NAME" "bad"))
            "process: environment variable name contains '='"
            "process env vec bad name")
          (assert-process-env-validation
            (process-env-vec-validation-error bad-shape)
            "process: environment vector name/value counts differ"
            "process env vec shape")
          (assert-process-invalid-command
            (process-output
              (process-command-with-env-vec
                command
                (process-env-vec-append (process-env-vec-new) "" "bad")))
            "process: environment variable name is empty")
          (assert-process-child-invalid-command
            (process-start
              (process-command-with-env-vec
                command
                (process-env-vec-append (process-env-vec-new) "BAD=NAME" "bad")))
            "process: environment variable name contains '='")))
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
      42)))