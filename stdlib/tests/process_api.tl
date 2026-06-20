(import stdlib.process)
(import stdlib.io)
(import stdlib.test)
(import stdlib.vector)

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
  (let
    [a : process.ProcessStringStep (process.process-string-step items)]
    (if (not (process.process-string-step-present? a))
      (io.panic message)
      (let
        [b : process.ProcessStringStep
          (process.process-string-step (process.process-string-step-rest a))]
        (if (not (process.process-string-step-present? b))
          (io.panic message)
          (let
            [tail : process.ProcessStringStep
              (process.process-string-step (process.process-string-step-rest b))]
            (if (process.process-string-step-present? tail)
              (io.panic message)
              (begin
                (assert-owned-string-eq
                  (process.process-string-step-value a)
                  first
                  message)
                (assert-owned-string-eq
                  (process.process-string-step-value b)
                  second
                  message)))))))))

(define (assert-process-string-empty
  [items : process.ProcessStringList]
  [message : String]) : unit
  (if (process.process-string-step-present? (process.process-string-step items))
    (io.panic message)
    unit))

(define (assert-process-string-list1
  [items : process.ProcessStringList]
  [first : String]
  [message : String]) : unit
  (let
    [a : process.ProcessStringStep (process.process-string-step items)]
    (if (not (process.process-string-step-present? a))
      (io.panic message)
      (let
        [tail : process.ProcessStringStep
          (process.process-string-step (process.process-string-step-rest a))]
        (if (process.process-string-step-present? tail)
          (io.panic message)
          (assert-owned-string-eq
            (process.process-string-step-value a)
            first
            message))))))

(define (assert-process-string-list3
  [items : process.ProcessStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (let
    [a : process.ProcessStringStep (process.process-string-step items)]
    (if (not (process.process-string-step-present? a))
      (io.panic message)
      (let
        [b : process.ProcessStringStep
          (process.process-string-step (process.process-string-step-rest a))]
        (if (not (process.process-string-step-present? b))
          (io.panic message)
          (let
            [c : process.ProcessStringStep
              (process.process-string-step (process.process-string-step-rest b))]
            (if (not (process.process-string-step-present? c))
              (io.panic message)
              (let
                [tail : process.ProcessStringStep
                  (process.process-string-step
                    (process.process-string-step-rest c))]
                (if (process.process-string-step-present? tail)
                  (io.panic message)
                  (begin
                    (assert-owned-string-eq
                      (process.process-string-step-value a)
                      first
                      message)
                    (assert-owned-string-eq
                      (process.process-string-step-value b)
                      second
                      message)
                    (assert-owned-string-eq
                      (process.process-string-step-value c)
                      third
                      message)))))))))))

(define (assert-process-some-string
  [value : process.ProcessMaybeString]
  [expected : String]
  [message : String]) : unit
  (let
    [info : process.ProcessMaybeStringInfo
      (process.process-maybe-string-info value)]
    (if (process.process-maybe-string-info-present? info)
      (assert-owned-string-eq
        (process.process-maybe-string-info-value info)
        expected
        message)
      (io.panic message))))

(define (assert-process-no-string
  [value : process.ProcessMaybeString]
  [message : String]) : unit
  (if (process.process-maybe-string-info-present?
    (process.process-maybe-string-info value))
    (io.panic message)
    unit))

(define (assert-process-env-head
  [env : process.ProcessEnvList]
  [expected-name : String]
  [expected-value : String]
  [message : String]) : unit
  (let
    [step : process.ProcessEnvStep (process.process-env-step env)]
    (if (not (process.process-env-step-present? step))
      (io.panic message)
      (begin
        (assert-owned-string-eq
          (process.process-env-step-name step)
          expected-name
          message)
        (assert-owned-string-eq
          (process.process-env-step-value step)
          expected-value
          message)))))

(define (assert-process-env-list2
  [env : process.ProcessEnvList]
  [first-name : String]
  [first-value : String]
  [second-name : String]
  [second-value : String]
  [message : String]) : unit
  (let
    [first : process.ProcessEnvStep (process.process-env-step env)]
    (if (not (process.process-env-step-present? first))
      (io.panic message)
      (let
        [second : process.ProcessEnvStep
          (process.process-env-step (process.process-env-step-rest first))]
        (if (not (process.process-env-step-present? second))
          (io.panic message)
          (let
            [tail : process.ProcessEnvStep
              (process.process-env-step (process.process-env-step-rest second))]
            (if (process.process-env-step-present? tail)
              (io.panic message)
              (begin
                (assert-owned-string-eq
                  (process.process-env-step-name first)
                  first-name
                  message)
                (assert-owned-string-eq
                  (process.process-env-step-value first)
                  first-value
                  message)
                (assert-owned-string-eq
                  (process.process-env-step-name second)
                  second-name
                  message)
                (assert-owned-string-eq
                  (process.process-env-step-value second)
                  second-value
                  message)))))))))

(define (assert-process-env-validation
  [value : process.ProcessMaybeString]
  [expected : String]
  [message : String]) : unit
  (assert-process-some-string value expected message))

(define (assert-process-invalid-command
  [result : process.ResultProcessOutput]
  [message : String]) : unit
  (begin
    (test.assert-true (process.process-result-invalid-command? result) message)
    (assert-owned-string-eq
      (process.process-result-error-message-or result "ok")
      message
      message)))

(define (assert-process-child-invalid-command
  [result : process.ResultProcessChild]
  [message : String]) : unit
  (begin
    (test.assert-true
      (process.process-child-result-invalid-command? result)
      message)
    (assert-owned-string-eq
      (process.process-child-result-error-message-or result "ok")
      message
      message)))

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
            (process.process-command-with-cwd
              (process.process-command "echo" args)
              "target")
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
      (assert-process-string-empty
        (process.process-args-from-string-vec (vector.string-vec-new))
        "process argv vec empty")
      (assert-process-string-list1
        (process.process-args-from-string-vec
          (vector.string-vec-push (vector.string-vec-new) "solo"))
        "solo"
        "process argv vec single")
      (assert-process-string-list3
        (process.process-args-from-string-vec
          (vector.string-vec-push
            (vector.string-vec-push
              (vector.string-vec-push
                (vector.string-vec-with-capacity 3)
                "hello")
              "world")
            "!"))
        "hello"
        "world"
        "!"
        "process argv vec multi")
      (assert-process-string-empty
        (process.process-command-argv
          (process.process-command-from-argv-vec "echo" (vector.string-vec-new)))
        "process command argv vec empty")
      (assert-process-string-list1
        (process.process-command-argv
          (process.process-command-from-argv-vec
            "echo"
            (vector.string-vec-push (vector.string-vec-new) "solo")))
        "solo"
        "process command argv vec single")
      (assert-process-string-list3
        (process.process-command-argv
          (process.process-command-from-argv-vec
            "echo"
            (vector.string-vec-push
              (vector.string-vec-push
                (vector.string-vec-push
                  (vector.string-vec-with-capacity 3)
                  "hello")
                "world")
              "!")))
        "hello"
        "world"
        "!"
        "process command argv vec multi")
      (assert-process-string-list3
        (process.process-command-argv
          (process.process-command-with-argv-vec
            command
            (vector.string-vec-push
              (vector.string-vec-push
                (vector.string-vec-push
                  (vector.string-vec-with-capacity 3)
                  "vec")
                "replace")
              "argv")))
        "vec"
        "replace"
        "argv"
        "process command argv vec replace")
      (assert-process-string-list3
        (process.process-command-argv
          (process.process-command-with-args-vec
            (process.process-command
              "echo"
              (process.process-args-single "base"))
            (vector.string-vec-push
              (vector.string-vec-push (vector.string-vec-with-capacity 2) "vec")
              "tail")))
        "base"
        "vec"
        "tail"
        "process command argv vec append")
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
            (process.process-env-cons
              "TL_REPLACED"
              "yes"
              (process.process-env-empty))))
        "TL_REPLACED"
        "yes"
        "process env list")
      (let
        [env-vec-empty : process.ProcessEnvVec (process.process-env-vec-new)]
        [env-vec : process.ProcessEnvVec
          (process.process-env-vec-append
            (process.process-env-vec-append
              (process.process-env-vec-new)
              "TL_FIRST"
              "one")
            "TL_SECOND"
            "two")]
        [env-dup : process.ProcessEnvVec
          (process.process-env-vec-append
            (process.process-env-vec-append
              (process.process-env-vec-new)
              "TL_DUP"
              "first")
            "TL_DUP"
            "second")]
        [bad-shape : process.ProcessEnvVec
          (process.ProcessEnvVec
            (vector.string-vec-push (vector.string-vec-new) "ONLY_NAME")
            (vector.string-vec-new))]
        (begin
          (test.assert-i64-eq
            (process.process-env-vec-count env-vec-empty)
            0
            "process env vec empty count")
          (test.assert-true
            (process.process-env-vec-valid? env-vec-empty)
            "process env vec empty valid")
          (test.assert-i64-eq
            (process.process-env-vec-count env-vec)
            2
            "process env vec count")
          (test.assert-true
            (process.process-env-vec-valid? env-vec)
            "process env vec valid")
          (assert-process-env-list2
            (process.process-env-vec-to-list env-vec)
            "TL_FIRST"
            "one"
            "TL_SECOND"
            "two"
            "process env vec order")
          (assert-process-env-list2
            (process.process-command-env
              (process.process-command-with-env-vec command env-vec))
            "TL_FIRST"
            "one"
            "TL_SECOND"
            "two"
            "process command env vec order")
          (assert-process-env-list2
            (process.process-env-vec-to-list env-dup)
            "TL_DUP"
            "first"
            "TL_DUP"
            "second"
            "process env vec duplicate order")
          (assert-process-env-validation
            (process.process-env-vec-validation-error
              (process.process-env-vec-append
                (process.process-env-vec-new)
                ""
                "bad"))
            "process: environment variable name is empty"
            "process env vec empty name")
          (assert-process-env-validation
            (process.process-env-vec-validation-error
              (process.process-env-vec-append
                (process.process-env-vec-new)
                "BAD=NAME"
                "bad"))
            "process: environment variable name contains '='"
            "process env vec bad name")
          (assert-process-env-validation
            (process.process-env-vec-validation-error bad-shape)
            "process: environment vector name/value counts differ"
            "process env vec shape")
          (assert-process-invalid-command
            (process.process-output
              (process.process-command-with-env-vec
                command
                (process.process-env-vec-append
                  (process.process-env-vec-new)
                  ""
                  "bad")))
            "process: environment variable name is empty")
          (assert-process-child-invalid-command
            (process.process-start
              (process.process-command-with-env-vec
                command
                (process.process-env-vec-append
                  (process.process-env-vec-new)
                  "BAD=NAME"
                  "bad")))
            "process: environment variable name contains '='")))
      (assert-process-no-string
        (process.process-command-cwd
          (process.process-command "echo" (process.process-args-empty)))
        "process default cwd")
      (assert-process-invalid-command
        (process.process-output
          (process.process-command "" (process.process-args-empty)))
        "process: executable path is empty")
      (assert-process-invalid-command
        (process.process-output (process.process-command-with-cwd command ""))
        "process: cwd path is empty")
      (assert-process-invalid-command
        (process.process-output
          (process.process-command-with-env command "" "1"))
        "process: environment variable name is empty")
      (assert-process-invalid-command
        (process.process-output
          (process.process-command-with-env command "BAD=NAME" "1"))
        "process: environment variable name contains '='")
      (assert-process-child-invalid-command
        (process.process-start
          (process.process-command "" (process.process-args-empty)))
        "process: executable path is empty")
      (assert-process-child-invalid-command
        (process.process-start (process.process-command-with-cwd command ""))
        "process: cwd path is empty")
      (assert-process-child-invalid-command
        (process.process-start
          (process.process-command-with-env command "" "1"))
        "process: environment variable name is empty")
      (assert-process-child-invalid-command
        (process.process-start
          (process.process-command-with-env command "BAD=NAME" "1"))
        "process: environment variable name contains '='")
      (test.assert-true
        (process.process-command-valid? command)
        "process valid command")
      (test.assert-false
        (process.process-command-valid?
          (process.process-command "" (process.process-args-empty)))
        "process invalid empty executable")
      (test.assert-true
        (process.process-result-success?
          (process.OkProcessOutput (process.ProcessOutput 0 "" "")))
        "process result success")
      (test.assert-false
        (process.process-result-success?
          (process.OkProcessOutput (process.ProcessOutput 7 "" "")))
        "process result nonzero")
      (test.assert-false
        (process.process-result-success?
          (process.ErrProcessOutput (process.ProcessSpawnFailed "spawn failed")))
        "process result error")
      (test.assert-true
        (process.process-error-spawn-failed?
          (process.ProcessSpawnFailed "spawn failed"))
        "process spawn predicate")
      (test.assert-true
        (process.process-error-wait-failed?
          (process.ProcessWaitFailed "wait failed"))
        "process wait predicate")
      (test.assert-true
        (process.process-child-started?
          (process.OkProcessChild (process.ProcessChild 1 2 3)))
        "process child started predicate")
      (test.assert-false
        (process.process-child-started?
          (process.ErrProcessChild (process.ProcessUnsupported "unsupported")))
        "process child unsupported predicate")
      42)))