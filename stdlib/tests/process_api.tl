(import stdlib.process)
(import stdlib.io)
(import stdlib.test)
(import stdlib.vector)
(import (vector.vector String) as svec)

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
    [a : process.ProcessStringStep (process.string-step items)]
    (if (not (process.string-step-present? a))
      (io.panic message)
      (let
        [b : process.ProcessStringStep
          (process.string-step (process.string-step-rest a))]
        (if (not (process.string-step-present? b))
          (io.panic message)
          (let
            [tail : process.ProcessStringStep
              (process.string-step (process.string-step-rest b))]
            (if (process.string-step-present? tail)
              (io.panic message)
              (begin
                (assert-owned-string-eq
                  (process.string-step-value a)
                  first
                  message)
                (assert-owned-string-eq
                  (process.string-step-value b)
                  second
                  message)))))))))

(define (assert-process-string-empty
  [items : process.ProcessStringList]
  [message : String]) : unit
  (if (process.string-step-present? (process.string-step items))
    (io.panic message)
    unit))

(define (assert-process-string-list1
  [items : process.ProcessStringList]
  [first : String]
  [message : String]) : unit
  (let
    [a : process.ProcessStringStep (process.string-step items)]
    (if (not (process.string-step-present? a))
      (io.panic message)
      (let
        [tail : process.ProcessStringStep
          (process.string-step (process.string-step-rest a))]
        (if (process.string-step-present? tail)
          (io.panic message)
          (assert-owned-string-eq (process.string-step-value a) first message))))))

(define (assert-process-string-list3
  [items : process.ProcessStringList]
  [first : String]
  [second : String]
  [third : String]
  [message : String]) : unit
  (let
    [a : process.ProcessStringStep (process.string-step items)]
    (if (not (process.string-step-present? a))
      (io.panic message)
      (let
        [b : process.ProcessStringStep
          (process.string-step (process.string-step-rest a))]
        (if (not (process.string-step-present? b))
          (io.panic message)
          (let
            [c : process.ProcessStringStep
              (process.string-step (process.string-step-rest b))]
            (if (not (process.string-step-present? c))
              (io.panic message)
              (let
                [tail : process.ProcessStringStep
                  (process.string-step (process.string-step-rest c))]
                (if (process.string-step-present? tail)
                  (io.panic message)
                  (begin
                    (assert-owned-string-eq
                      (process.string-step-value a)
                      first
                      message)
                    (assert-owned-string-eq
                      (process.string-step-value b)
                      second
                      message)
                    (assert-owned-string-eq
                      (process.string-step-value c)
                      third
                      message)))))))))))

(define (assert-process-some-string
  [value : process.ProcessMaybeString]
  [expected : String]
  [message : String]) : unit
  (let
    [info : process.ProcessMaybeStringInfo (process.maybe-string-info value)]
    (if (process.maybe-string-info-present? info)
      (assert-owned-string-eq
        (process.maybe-string-info-value info)
        expected
        message)
      (io.panic message))))

(define (assert-process-no-string
  [value : process.ProcessMaybeString]
  [message : String]) : unit
  (if (process.maybe-string-info-present? (process.maybe-string-info value))
    (io.panic message)
    unit))

(define (assert-process-env-head
  [env : process.ProcessEnvList]
  [expected-name : String]
  [expected-value : String]
  [message : String]) : unit
  (let
    [step : process.ProcessEnvStep (process.env-step env)]
    (if (not (process.env-step-present? step))
      (io.panic message)
      (begin
        (assert-owned-string-eq
          (process.env-step-name step)
          expected-name
          message)
        (assert-owned-string-eq
          (process.env-step-value step)
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
    [first : process.ProcessEnvStep (process.env-step env)]
    (if (not (process.env-step-present? first))
      (io.panic message)
      (let
        [second : process.ProcessEnvStep
          (process.env-step (process.env-step-rest first))]
        (if (not (process.env-step-present? second))
          (io.panic message)
          (let
            [tail : process.ProcessEnvStep
              (process.env-step (process.env-step-rest second))]
            (if (process.env-step-present? tail)
              (io.panic message)
              (begin
                (assert-owned-string-eq
                  (process.env-step-name first)
                  first-name
                  message)
                (assert-owned-string-eq
                  (process.env-step-value first)
                  first-value
                  message)
                (assert-owned-string-eq
                  (process.env-step-name second)
                  second-name
                  message)
                (assert-owned-string-eq
                  (process.env-step-value second)
                  second-value
                  message)))))))))

(define (assert-process-env-validation
  [value : process.ProcessMaybeString]
  [expected : String]
  [message : String]) : unit
  (assert-process-some-string value expected message))

(define (process-api-string-vec0) : svec.Vec
  (svec.new))

(define (process-api-string-vec1 [a : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.new)]
    (begin
      (svec.push (&mut items) a)
      items)))

(define (process-api-string-vec2 [a : String] [b : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.with-capacity 2)]
    (begin
      (svec.push (&mut items) a)
      (svec.push (&mut items) b)
      items)))

(define (process-api-string-vec3 [a : String] [b : String] [c : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.with-capacity 3)]
    (begin
      (svec.push (&mut items) a)
      (svec.push (&mut items) b)
      (svec.push (&mut items) c)
      items)))

(define (process-api-env-vec1 [name : String] [value : String]) : process.ProcessEnvVec
  (let
    [env : process.ProcessEnvVec (process.env-vec-new)]
    (begin
      (process.env-vec-append (&mut env) name value)
      env)))

(define (process-api-env-vec2
  [name-a : String]
  [value-a : String]
  [name-b : String]
  [value-b : String]) : process.ProcessEnvVec
  (let
    [env : process.ProcessEnvVec (process.env-vec-new)]
    (begin
      (process.env-vec-append (&mut env) name-a value-a)
      (process.env-vec-append (&mut env) name-b value-b)
      env)))

(define (process-api-bad-shape-env-vec) : process.ProcessEnvVec
  (let
    [names : svec.Vec (svec.new)]
    [values : svec.Vec (svec.new)]
    (begin
      (svec.push (&mut names) "ONLY_NAME")
      (process.ProcessEnvVec names values))))

(define (assert-process-invalid-command
  [result : process.ResultProcessOutput]
  [message : String]) : unit
  (begin
    (test.assert-true (process.result-invalid-command? result) message)
    (assert-owned-string-eq
      (process.result-error-message-or result "ok")
      message
      message)))

(define (assert-process-child-invalid-command
  [result : process.ResultProcessChild]
  [message : String]) : unit
  (begin
    (test.assert-true (process.child-result-invalid-command? result) message)
    (assert-owned-string-eq
      (process.child-result-error-message-or result "ok")
      message
      message)))

(define (main) : i64
  (let
    [args : process.ProcessStringList
      (process.args-cons
        "hello"
        (process.args-cons "world" (process.args-empty)))]
    [command : process.ProcessCommand
      (process.command-with-arg
        (process.command-with-env
          (process.command-with-stdin
            (process.command-with-cwd (process.command "echo" args) "target")
            "stdin")
          "TL_TEST"
          "1")
        "!")]
    (begin
      (assert-owned-string-eq
        (process.command-executable command)
        "echo"
        "process executable")
      (assert-process-string-list args "hello" "world" "process argv")
      (assert-process-string-list3
        (process.command-argv command)
        "hello"
        "world"
        "!"
        "process argv append")
      (test.assert-i64-eq
        (process.args-count (process.command-argv command))
        3
        "process argv count")
      (assert-process-string-list3
        (process.args-append args (process.args-single "again"))
        "hello"
        "world"
        "again"
        "process args append")
      (let
        [empty-argv : svec.Vec (process-api-string-vec0)]
        [solo-argv : svec.Vec (process-api-string-vec1 "solo")]
        [multi-argv : svec.Vec (process-api-string-vec3 "hello" "world" "!")]
        [replace-argv : svec.Vec
          (process-api-string-vec3 "vec" "replace" "argv")]
        [tail-argv : svec.Vec (process-api-string-vec2 "vec" "tail")]
        (begin
          (assert-process-string-empty
            (process.args-from-string-vec (& empty-argv))
            "process argv vec empty")
          (assert-process-string-list1
            (process.args-from-string-vec (& solo-argv))
            "solo"
            "process argv vec single")
          (assert-process-string-list3
            (process.args-from-string-vec (& multi-argv))
            "hello"
            "world"
            "!"
            "process argv vec multi")
          (assert-process-string-empty
            (process.command-argv
              (process.command-from-argv-vec "echo" (& empty-argv)))
            "process command argv vec empty")
          (assert-process-string-list1
            (process.command-argv
              (process.command-from-argv-vec "echo" (& solo-argv)))
            "solo"
            "process command argv vec single")
          (assert-process-string-list3
            (process.command-argv
              (process.command-from-argv-vec "echo" (& multi-argv)))
            "hello"
            "world"
            "!"
            "process command argv vec multi")
          (assert-process-string-list3
            (process.command-argv
              (process.command-with-argv-vec command (& replace-argv)))
            "vec"
            "replace"
            "argv"
            "process command argv vec replace")
          (assert-process-string-list3
            (process.command-argv
              (process.command-with-args-vec
                (process.command "echo" (process.args-single "base"))
                (& tail-argv)))
            "base"
            "vec"
            "tail"
            "process command argv vec append")))
      (assert-process-some-string
        (process.command-cwd command)
        "target"
        "process cwd")
      (assert-process-some-string
        (process.command-stdin command)
        "stdin"
        "process stdin")
      (assert-process-env-head
        (process.command-env command)
        "TL_TEST"
        "1"
        "process env")
      (test.assert-i64-eq
        (process.env-count (process.command-env command))
        1
        "process env count")
      (assert-process-env-head
        (process.command-env
          (process.command-with-env-list
            command
            (process.env-cons "TL_REPLACED" "yes" (process.env-empty))))
        "TL_REPLACED"
        "yes"
        "process env list")
      (let
        [env-vec-empty : process.ProcessEnvVec (process.env-vec-new)]
        [env-vec : process.ProcessEnvVec
          (process-api-env-vec2 "TL_FIRST" "one" "TL_SECOND" "two")]
        [env-dup : process.ProcessEnvVec
          (process-api-env-vec2 "TL_DUP" "first" "TL_DUP" "second")]
        [bad-empty : process.ProcessEnvVec (process-api-env-vec1 "" "bad")]
        [bad-name : process.ProcessEnvVec
          (process-api-env-vec1 "BAD=NAME" "bad")]
        [bad-shape : process.ProcessEnvVec (process-api-bad-shape-env-vec)]
        (begin
          (test.assert-i64-eq
            (process.env-vec-count (& env-vec-empty))
            0
            "process env vec empty count")
          (test.assert-true
            (process.env-vec-valid? (& env-vec-empty))
            "process env vec empty valid")
          (test.assert-i64-eq
            (process.env-vec-count (& env-vec))
            2
            "process env vec count")
          (test.assert-true
            (process.env-vec-valid? (& env-vec))
            "process env vec valid")
          (assert-process-env-list2
            (process.env-vec-to-list (& env-vec))
            "TL_FIRST"
            "one"
            "TL_SECOND"
            "two"
            "process env vec order")
          (assert-process-env-list2
            (process.command-env
              (process.command-with-env-vec command (& env-vec)))
            "TL_FIRST"
            "one"
            "TL_SECOND"
            "two"
            "process command env vec order")
          (assert-process-env-list2
            (process.env-vec-to-list (& env-dup))
            "TL_DUP"
            "first"
            "TL_DUP"
            "second"
            "process env vec duplicate order")
          (assert-process-env-validation
            (process.env-vec-validation-error (& bad-empty))
            "process: environment variable name is empty"
            "process env vec empty name")
          (assert-process-env-validation
            (process.env-vec-validation-error (& bad-name))
            "process: environment variable name contains '='"
            "process env vec bad name")
          (assert-process-env-validation
            (process.env-vec-validation-error (& bad-shape))
            "process: environment vector name/value counts differ"
            "process env vec shape")
          (assert-process-invalid-command
            (process.output
              (process.command-with-env-vec command (& bad-empty)))
            "process: environment variable name is empty")
          (assert-process-child-invalid-command
            (process.start (process.command-with-env-vec command (& bad-name)))
            "process: environment variable name contains '='")))
      (assert-process-no-string
        (process.command-cwd (process.command "echo" (process.args-empty)))
        "process default cwd")
      (assert-process-invalid-command
        (process.output (process.command "" (process.args-empty)))
        "process: executable path is empty")
      (assert-process-invalid-command
        (process.output (process.command-with-cwd command ""))
        "process: cwd path is empty")
      (assert-process-invalid-command
        (process.output (process.command-with-env command "" "1"))
        "process: environment variable name is empty")
      (assert-process-invalid-command
        (process.output (process.command-with-env command "BAD=NAME" "1"))
        "process: environment variable name contains '='")
      (assert-process-child-invalid-command
        (process.start (process.command "" (process.args-empty)))
        "process: executable path is empty")
      (assert-process-child-invalid-command
        (process.start (process.command-with-cwd command ""))
        "process: cwd path is empty")
      (assert-process-child-invalid-command
        (process.start (process.command-with-env command "" "1"))
        "process: environment variable name is empty")
      (assert-process-child-invalid-command
        (process.start (process.command-with-env command "BAD=NAME" "1"))
        "process: environment variable name contains '='")
      (test.assert-true
        (process.command-valid? command)
        "process valid command")
      (test.assert-false
        (process.command-valid? (process.command "" (process.args-empty)))
        "process invalid empty executable")
      (test.assert-true
        (process.result-success?
          (process.OkProcessOutput (process.ProcessOutput 0 "" "")))
        "process result success")
      (test.assert-false
        (process.result-success?
          (process.OkProcessOutput (process.ProcessOutput 7 "" "")))
        "process result nonzero")
      (test.assert-false
        (process.result-success?
          (process.ErrProcessOutput (process.ProcessSpawnFailed "spawn failed")))
        "process result error")
      (test.assert-true
        (process.error-spawn-failed?
          (process.ProcessSpawnFailed "spawn failed"))
        "process spawn predicate")
      (test.assert-true
        (process.error-wait-failed? (process.ProcessWaitFailed "wait failed"))
        "process wait predicate")
      (test.assert-true
        (process.child-started?
          (process.OkProcessChild (process.ProcessChild 1 2 3)))
        "process child started predicate")
      (test.assert-false
        (process.child-started?
          (process.ErrProcessChild (process.ProcessUnsupported "unsupported")))
        "process child unsupported predicate")
      42)))