;# Process command API surface for TypeLisp (#840).
;#
;# Defines the canonical process command/output/error data model for selfhost
;# tools. Runtime process execution is provided by `process_runtime.tl` through
;# `tl_process_output`, `tl_process_start`, and `tl_process_wait`;
;# unsupported target/runtime combinations return structured errors instead of
;# routing through Rust host actions or shell-tokenized command strings.
;# Linux execution preserves inherited environment entries except names
;# provided by `ProcessEnvList`, which are replaced by the override value.
;# `ProcessEnvVec` is a vector-backed companion that converts to the same
;# list-backed runtime boundary: inherited entries matching any override name
;# are removed, overrides are emitted in vector order, and duplicate override
;# names are preserved in vector order.
;#
;# Usage: `(import stdlib.process)`
;#
(module stdlib.process)

(import stdlib.string)
(import stdlib.vector)

;: Immutable list of process argument strings in argv order.
(defenum ProcessStringList
  (ProcessStringNil)
  (ProcessStringCons String (Box ProcessStringList)))

;: Optional string value used for cwd and stdin configuration.
(defenum ProcessMaybeString
  (ProcessNoString)
  (ProcessSomeString String))

;: Environment override list stored as name/value pairs.
(defenum ProcessEnvList
  (ProcessEnvNil)
  (ProcessEnvCons String String (Box ProcessEnvList)))

;: Vector-backed process environment overrides. `names` and `values` are
;: parallel `StringVec` buffers with the invariant that their live lengths are
;: equal. Runtime execution still consumes `ProcessEnvList`; converting this
;: representation preserves vector order and keeps duplicate names.
(defstruct ProcessEnvVec
  (names vector.StringVec)
  (values vector.StringVec))

;: Destructured view of one argument-list step for imported modules that cannot
;: pattern-match process variants directly.
(defstruct ProcessStringStep
  (present bool)
  (value String)
  (rest ProcessStringList))

;: Destructured view of one environment-list step for imported modules that
;: cannot pattern-match process variants directly.
(defstruct ProcessEnvStep
  (present bool)
  (name String)
  (value String)
  (rest ProcessEnvList))

;: Destructured optional string for imported modules that cannot pattern-match
;: process variants directly.
(defstruct ProcessMaybeStringInfo
  (present bool)
  (value String))

;: Single-pass destructured child result for imported callers.
(defstruct ProcessChildInfo
  (ok bool)
  (pid i64)
  (stdout-handle i64)
  (stderr-handle i64))

;: Process command data: executable path, argv, cwd, env, and stdin.
(defstruct ProcessCommand
  (executable String)
  (argv ProcessStringList)
  (cwd ProcessMaybeString)
  (env ProcessEnvList)
  (stdin ProcessMaybeString))

;: Captured process result data.
(defstruct ProcessOutput
  (status i64)
  (stdout String)
  (stderr String))

;: Runtime-owned asynchronous process handle data.
;:
;: The integer fields are opaque runtime handles. Callers should pass the value
;: to `process-wait` rather than inspecting or constructing handles directly.
(defstruct ProcessChild
  (pid i64)
  (stdout-handle i64)
  (stderr-handle i64))

;: Structured process failures returned instead of host-action panics.
(defenum ProcessError
  (ProcessInvalidCommand String)
  (ProcessSpawnFailed String)
  (ProcessWaitFailed String)
  (ProcessUnsupported String))

;: Result type for process execution APIs.
(defenum ResultProcessOutput
  (OkProcessOutput ProcessOutput)
  (ErrProcessOutput ProcessError))

;: Result type for asynchronous process start APIs.
(defenum ResultProcessChild
  (OkProcessChild ProcessChild)
  (ErrProcessChild ProcessError))

;: Return a destructured step from an argv list.
(define (process-string-step [args : ProcessStringList]) : ProcessStringStep
  (match args
    [(ProcessStringNil) (ProcessStringStep false "" (ProcessStringNil))]
    [(ProcessStringCons value rest)
      (ProcessStringStep true value (box-get rest))]))

;: Return whether a destructured argv step contains an item.
(define (process-string-step-present? [step : ProcessStringStep]) : bool
  (struct-get step present))

;: Return the argv value from a destructured step, or the empty string.
(define (process-string-step-value [step : ProcessStringStep]) : String
  (struct-get step value))

;: Return the argv tail from a destructured step.
(define (process-string-step-rest [step : ProcessStringStep]) : ProcessStringList
  (struct-get step rest))

;: Return a destructured step from an environment override list.
(define (process-env-step [env : ProcessEnvList]) : ProcessEnvStep
  (match env
    [(ProcessEnvNil) (ProcessEnvStep false "" "" (ProcessEnvNil))]
    [(ProcessEnvCons name value rest)
      (ProcessEnvStep true name value (box-get rest))]))

;: Return whether a destructured env step contains an item.
(define (process-env-step-present? [step : ProcessEnvStep]) : bool
  (struct-get step present))

;: Return the env name from a destructured step, or the empty string.
(define (process-env-step-name [step : ProcessEnvStep]) : String
  (struct-get step name))

;: Return the env value from a destructured step, or the empty string.
(define (process-env-step-value [step : ProcessEnvStep]) : String
  (struct-get step value))

;: Return the env tail from a destructured step.
(define (process-env-step-rest [step : ProcessEnvStep]) : ProcessEnvList
  (struct-get step rest))

;: Return a destructured optional string.
(define (process-maybe-string-info [value : ProcessMaybeString]) : ProcessMaybeStringInfo
  (match value
    [(ProcessNoString) (ProcessMaybeStringInfo false "")]
    [(ProcessSomeString text) (ProcessMaybeStringInfo true text)]))

;: Return whether a destructured optional string is present.
(define (process-maybe-string-info-present? [info : ProcessMaybeStringInfo]) : bool
  (struct-get info present))

;: Return the string from a destructured optional string, or the empty string.
(define (process-maybe-string-info-value [info : ProcessMaybeStringInfo]) : String
  (struct-get info value))

;: Return an empty argument list.
(define (process-args-empty) : ProcessStringList
  (ProcessStringNil))

;: Return the number of argv entries in `args`.
(define (process-args-count [args : ProcessStringList]) : i64
  (match args
    [(ProcessStringNil) 0]
    [(ProcessStringCons _ rest) (+ 1 (process-args-count (box-get rest)))]))

;: Prepend an owned argument string to an argv list.
(define (process-args-cons [value : String] [rest : ProcessStringList]) : ProcessStringList
  (ProcessStringCons value (box rest)))

;: Return a one-element argument list backed by an owned string.
(define (process-args-single [value : String]) : ProcessStringList
  (ProcessStringCons value (box (ProcessStringNil))))

;: Concatenate two argument lists while preserving argv order.
(define (process-args-append
  [left : ProcessStringList]
  [right : ProcessStringList]) : ProcessStringList
  (match left
    [(ProcessStringNil) right]
    [(ProcessStringCons value rest)
      (ProcessStringCons value (box (process-args-append (box-get rest) right)))]))

;: Convert a `StringVec` argv buffer to the list representation consumed by
;: `ProcessCommand`, preserving vector order.
(define (process-args-from-string-vec-from
  [args : vector.StringVec]
  [index : i64]
  [out : ProcessStringList]) : ProcessStringList
  (if (< index 0)
    out
    (process-args-from-string-vec-from
      args
      (- index 1)
      (process-args-cons (vector.string-vec-get args index "") out))))

;: Convert a `StringVec` argv buffer to the list representation consumed by
;: `ProcessCommand`, preserving vector order.
(define (process-args-from-string-vec [args : vector.StringVec]) : ProcessStringList
  (process-args-from-string-vec-from
    args
    (- (vector.string-vec-len args) 1)
    (ProcessStringNil)))

;: Return an empty environment override list.
(define (process-env-empty) : ProcessEnvList
  (ProcessEnvNil))

;: Return the number of env overrides in `env`.
(define (process-env-count [env : ProcessEnvList]) : i64
  (match env
    [(ProcessEnvNil) 0]
    [(ProcessEnvCons _ _ rest) (+ 1 (process-env-count (box-get rest)))]))

;: Prepend owned environment override strings to an env list.
(define (process-env-cons
  [name : String]
  [value : String]
  [rest : ProcessEnvList]) : ProcessEnvList
  (ProcessEnvCons name value (box rest)))

;: Return true when `text` contains `needle`.
(define (process-string-contains-char? [text : (& text str)] [needle : char]) : bool
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (< i n) (not found))
        (begin
          (if (= (string-ref text i) needle)
            (set! found true)
            unit)
          (set! i (+ i 1))))
      found)))

;: Return the name buffer from a vector-backed env override set.
(define (process-env-vec-names [env : ProcessEnvVec]) : vector.StringVec
  (struct-get env names))

;: Return the value buffer from a vector-backed env override set.
(define (process-env-vec-values [env : ProcessEnvVec]) : vector.StringVec
  (struct-get env values))

;: Create an empty vector-backed env override set with at least `capacity`
;: backing slots in each parallel buffer.
(define (process-env-vec-with-capacity [capacity : i64]) : ProcessEnvVec
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (ProcessEnvVec
      (vector.string-vec-with-capacity cap)
      (vector.string-vec-with-capacity cap))))

;: Create an empty vector-backed env override set.
(define (process-env-vec-new) : ProcessEnvVec
  (process-env-vec-with-capacity 4))

;: Return the number of vector-backed env overrides. Helper-created values keep
;: this equal to the live length of both buffers; manually constructed values
;: should be checked with `process-env-vec-validation-error`.
(define (process-env-vec-count [env : ProcessEnvVec]) : i64
  (vector.string-vec-len (process-env-vec-names env)))

;: Append one owned environment override at the end of the vector-backed set.
;: Duplicate names are preserved in append order.
(define (process-env-vec-append
  [env : ProcessEnvVec]
  [name : String]
  [value : String]) : ProcessEnvVec
  (ProcessEnvVec
    (vector.string-vec-push (process-env-vec-names env) name)
    (vector.string-vec-push (process-env-vec-values env) value)))

;: Convert vector-backed env overrides to a list, preserving vector order at
;: the existing runtime boundary.
(define (process-env-vec-to-list-from
  [env : ProcessEnvVec]
  [index : i64]
  [out : ProcessEnvList]) : ProcessEnvList
  (if (< index 0)
    out
    (process-env-vec-to-list-from
      env
      (- index 1)
      (ProcessEnvCons
        (vector.string-vec-get (process-env-vec-names env) index "")
        (vector.string-vec-get (process-env-vec-values env) index "")
        (box out)))))

;: Convert vector-backed env overrides to the list representation consumed by
;: `ProcessCommand` and the process runtime.
(define (process-env-vec-to-list [env : ProcessEnvVec]) : ProcessEnvList
  (process-env-vec-to-list-from
    env
    (- (process-env-vec-count env) 1)
    (ProcessEnvNil)))

;: Return the first vector-backed env validation error, or `ProcessNoString`.
(define (process-env-vec-validation-error-from
  [env : ProcessEnvVec]
  [index : i64]) : ProcessMaybeString
  (if (>= index (process-env-vec-count env))
    (ProcessNoString)
    (let
      [name : String
        (vector.string-vec-get (process-env-vec-names env) index "")]
      (if (string-eq name "")
        (ProcessSomeString "process: environment variable name is empty")
        (if (process-string-contains-char? (& name) '=')
          (ProcessSomeString "process: environment variable name contains '='")
          (process-env-vec-validation-error-from env (+ index 1)))))))

;: Return the first vector-backed env validation error, or `ProcessNoString`.
;: The inherited environment is filtered by names that appear in the override
;: set, then override entries are emitted in vector order. Duplicate override
;: names are preserved in vector order.
(define (process-env-vec-validation-error [env : ProcessEnvVec]) : ProcessMaybeString
  (if (not
    (=
      (vector.string-vec-len (process-env-vec-names env))
      (vector.string-vec-len (process-env-vec-values env))))
    (ProcessSomeString "process: environment vector name/value counts differ")
    (process-env-vec-validation-error-from env 0)))

;: Return true when vector-backed env overrides satisfy the public invariant and
;: all override names are valid.
(define (process-env-vec-valid? [env : ProcessEnvVec]) : bool
  (match (process-env-vec-validation-error env)
    [(ProcessNoString) true]
    [(ProcessSomeString _) false]))

;: Return a command stdin value that provides no input.
(define (process-no-stdin) : ProcessMaybeString
  (ProcessNoString))

;: Return a command stdin value backed by an owned string.
(define (process-stdin-string [value : String]) : ProcessMaybeString
  (ProcessSomeString value))

;: Return a cwd value that inherits the current working directory.
(define (process-no-cwd) : ProcessMaybeString
  (ProcessNoString))

;: Return a cwd value that runs the command under an owned path string.
(define (process-cwd [value : String]) : ProcessMaybeString
  (ProcessSomeString value))

;: Construct a process command with owned executable storage and default cwd,
;: env, and stdin settings.
(define (process-command [executable : String] [argv : ProcessStringList]) : ProcessCommand
  (ProcessCommand
    executable
    argv
    (ProcessNoString)
    (ProcessEnvNil)
    (ProcessNoString)))

;: Construct a process command from an executable and a vector-backed argv
;: buffer. The command keeps the existing list-backed ABI after one conversion.
(define (process-command-from-argv-vec
  [executable : String]
  [argv : vector.StringVec]) : ProcessCommand
  (process-command executable (process-args-from-string-vec argv)))

;: Return a copy of `command` with `arg` appended after existing argv entries.
(define (process-command-with-arg [command : ProcessCommand] [arg : String]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-args-append
      (process-command-argv command)
      (process-args-single arg))
    (process-command-cwd command)
    (process-command-env command)
    (process-command-stdin command)))

;: Return a copy of `command` with `args` appended after existing argv entries.
(define (process-command-with-args
  [command : ProcessCommand]
  [args : ProcessStringList]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-args-append (process-command-argv command) args)
    (process-command-cwd command)
    (process-command-env command)
    (process-command-stdin command)))

;: Return a copy of `command` with the full argv list replaced by a
;: vector-backed argv buffer converted once at the compatibility boundary.
(define (process-command-with-argv-vec
  [command : ProcessCommand]
  [argv : vector.StringVec]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-args-from-string-vec argv)
    (process-command-cwd command)
    (process-command-env command)
    (process-command-stdin command)))

;: Return a copy of `command` with vector-backed args appended after existing
;: argv entries through one list conversion and one list append.
(define (process-command-with-args-vec
  [command : ProcessCommand]
  [args : vector.StringVec]) : ProcessCommand
  (process-command-with-args command (process-args-from-string-vec args)))

;: Construct a process command with every owned-storage field supplied
;: explicitly.
(define (process-command-full
  [executable : String]
  [argv : ProcessStringList]
  [cwd : ProcessMaybeString]
  [env : ProcessEnvList]
  [stdin : ProcessMaybeString]) : ProcessCommand
  (ProcessCommand executable argv cwd env stdin))

;: Return a copy of `command` with cwd set to `cwd`.
(define (process-command-with-cwd [command : ProcessCommand] [cwd : String]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-command-argv command)
    (ProcessSomeString cwd)
    (process-command-env command)
    (process-command-stdin command)))

;: Return a copy of `command` with an additional env override.
(define (process-command-with-env
  [command : ProcessCommand]
  [name : String]
  [value : String]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-command-argv command)
    (process-command-cwd command)
    (ProcessEnvCons name value (box (process-command-env command)))
    (process-command-stdin command)))

;: Return a copy of `command` with the full env override list replaced.
(define (process-command-with-env-list
  [command : ProcessCommand]
  [env : ProcessEnvList]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-command-argv command)
    (process-command-cwd command)
    env
    (process-command-stdin command)))

;: Return a copy of `command` with env overrides replaced by vector-backed
;: storage converted to the existing list-backed runtime boundary.
(define (process-command-with-env-vec
  [command : ProcessCommand]
  [env : ProcessEnvVec]) : ProcessCommand
  (process-command-with-env-list command (process-env-vec-to-list env)))

;: Return a copy of `command` with stdin set to `stdin`.
(define (process-command-with-stdin [command : ProcessCommand] [stdin : String]) : ProcessCommand
  (ProcessCommand
    (process-command-executable command)
    (process-command-argv command)
    (process-command-cwd command)
    (process-command-env command)
    (ProcessSomeString stdin)))

;: Return the executable path from `command`.
(define (process-command-executable [command : ProcessCommand]) : String
  (struct-get command executable))

;: Return the argv list from `command`.
(define (process-command-argv [command : ProcessCommand]) : ProcessStringList
  (struct-get command argv))

;: Return the cwd setting from `command`.
(define (process-command-cwd [command : ProcessCommand]) : ProcessMaybeString
  (struct-get command cwd))

;: Return the env override list from `command`.
(define (process-command-env [command : ProcessCommand]) : ProcessEnvList
  (struct-get command env))

;: Return the stdin setting from `command`.
(define (process-command-stdin [command : ProcessCommand]) : ProcessMaybeString
  (struct-get command stdin))

;: Return the process exit status.
(define (process-output-status [output : ProcessOutput]) : i64
  (struct-get output status))

;: Return captured stdout from `output`.
(define (process-output-stdout [output : ProcessOutput]) : String
  (struct-get output stdout))

;: Return captured stderr from `output`.
(define (process-output-stderr [output : ProcessOutput]) : String
  (struct-get output stderr))

;: Return true when the process exit status is zero.
(define (process-success? [output : ProcessOutput]) : bool
  (= (process-output-status output) 0))

;: Return `result` through the aggregate return path so stage0 can match it in
;: modules that import other modules.
(define (process-result-output-normalize [result : ResultProcessOutput]) : ResultProcessOutput
  result)

;: Return `result` through the aggregate return path so stage0 can match it in
;: modules that import other modules.
(define (process-result-child-normalize [result : ResultProcessChild]) : ResultProcessChild
  result)

;: Return true when `result` is a successful zero-exit process output.
(define (process-result-success? [result : ResultProcessOutput]) : bool
  (match (process-result-output-normalize result)
    [(OkProcessOutput output) (process-success? output)]
    [(ErrProcessOutput _) false]))

;: Return true when `result` is a started child handle.
(define (process-child-started? [result : ResultProcessChild]) : bool
  (match (process-result-child-normalize result)
    [(OkProcessChild _) true]
    [(ErrProcessChild _) false]))

;: Destructure a child result in one pass.
(define (process-child-result-info [result : ResultProcessChild]) : ProcessChildInfo
  (match result
    [(OkProcessChild child)
      (ProcessChildInfo
        true
        (struct-get child pid)
        (struct-get child stdout-handle)
        (struct-get child stderr-handle))]
    [(ErrProcessChild _) (ProcessChildInfo false (- 0 1) (- 0 1) (- 0 1))]))

;: Return true when `info` describes a started child.
(define (process-child-info-ok? [info : ProcessChildInfo]) : bool
  (struct-get info ok))

;: Return the child pid from `info`, or -1 when it is not ok.
(define (process-child-info-pid [info : ProcessChildInfo]) : i64
  (struct-get info pid))

;: Return the child stdout handle from `info`, or -1 when it is not ok.
(define (process-child-info-stdout-handle [info : ProcessChildInfo]) : i64
  (struct-get info stdout-handle))

;: Return the child stderr handle from `info`, or -1 when it is not ok.
(define (process-child-info-stderr-handle [info : ProcessChildInfo]) : i64
  (struct-get info stderr-handle))

;: Return the output status, or `fallback` when `result` is an error.
(define (process-result-status-or
  [result : ResultProcessOutput]
  [fallback : i64]) : i64
  (match (process-result-output-normalize result)
    [(OkProcessOutput output) (process-output-status output)]
    [(ErrProcessOutput _) fallback]))

;: Return true when `result` is an `Ok` output matching all expected fields.
(define (process-result-output-eq?
  [result : ResultProcessOutput]
  [expected-status : i64]
  [expected-stdout : String]
  [expected-stderr : String]) : bool
  (match result
    [(OkProcessOutput output)
      (if (= (process-output-status output) expected-status)
        (if (string.string-eq (process-output-stdout output) expected-stdout)
          (string.string-eq (process-output-stderr output) expected-stderr)
          false)
        false)]
    [(ErrProcessOutput _) false]))

;: Return true when `result` is an `Ok` output with empty stdout and nonempty stderr.
(define (process-result-stderr-nonempty?
  [result : ResultProcessOutput]
  [expected-status : i64]) : bool
  (match result
    [(OkProcessOutput output)
      (if (= (process-output-status output) expected-status)
        (if (= (string-length (process-output-stdout output)) 0)
          (> (string-length (process-output-stderr output)) 0)
          false)
        false)]
    [(ErrProcessOutput _) false]))

;: Return the child pid, or `fallback` when `result` is an error.
(define (process-child-result-pid-or
  [result : ResultProcessChild]
  [fallback : i64]) : i64
  (match (process-result-child-normalize result)
    [(OkProcessChild child) (struct-get child pid)]
    [(ErrProcessChild _) fallback]))

;: Return true when an output result carries an invalid-command error.
(define (process-result-invalid-command? [result : ResultProcessOutput]) : bool
  (match (process-result-output-normalize result)
    [(ErrProcessOutput error) (process-error-invalid-command? error)]
    [(OkProcessOutput _) false]))

;: Return an output result error message, or `fallback` when it is ok.
(define (process-result-error-message-or
  [result : ResultProcessOutput]
  [fallback : String]) : String
  (match (process-result-output-normalize result)
    [(ErrProcessOutput error) (process-error-message error)]
    [(OkProcessOutput _) fallback]))

;: Return true when a child result carries an invalid-command error.
(define (process-child-result-invalid-command? [result : ResultProcessChild]) : bool
  (match (process-result-child-normalize result)
    [(ErrProcessChild error) (process-error-invalid-command? error)]
    [(OkProcessChild _) false]))

;: Return a child result error message, or `fallback` when it is ok.
(define (process-child-result-error-message-or
  [result : ResultProcessChild]
  [fallback : String]) : String
  (match (process-result-child-normalize result)
    [(ErrProcessChild error) (process-error-message error)]
    [(OkProcessChild _) fallback]))

;: Return `error` through the aggregate return path so stage0 can match it in
;: modules that import other modules.
(define (process-error-normalize [error : ProcessError]) : ProcessError
  error)

;: Return the diagnostic message stored in `error`.
(define (process-error-message [error : ProcessError]) : String
  (match (process-error-normalize error)
    [(ProcessInvalidCommand message) message]
    [(ProcessSpawnFailed message) message]
    [(ProcessWaitFailed message) message]
    [(ProcessUnsupported message) message]))

;: Return true when `error` is a command validation diagnostic.
(define (process-error-invalid-command? [error : ProcessError]) : bool
  (match (process-error-normalize error)
    [(ProcessInvalidCommand _) true]
    [_ false]))

;: Return true when `error` is a spawn failure diagnostic.
(define (process-error-spawn-failed? [error : ProcessError]) : bool
  (match (process-error-normalize error)
    [(ProcessSpawnFailed _) true]
    [_ false]))

;: Return true when `error` is a wait failure diagnostic.
(define (process-error-wait-failed? [error : ProcessError]) : bool
  (match (process-error-normalize error)
    [(ProcessWaitFailed _) true]
    [_ false]))

;: Return true when `error` is an unsupported runtime/platform diagnostic.
(define (process-error-unsupported? [error : ProcessError]) : bool
  (match (process-error-normalize error)
    [(ProcessUnsupported _) true]
    [_ false]))

;: Return the first env validation error, or `ProcessNoString`.
(define (process-env-validation-error [env : ProcessEnvList]) : ProcessMaybeString
  (match env
    [(ProcessEnvNil) (ProcessNoString)]
    [(ProcessEnvCons name _ rest)
      (if (string-eq name "")
        (ProcessSomeString "process: environment variable name is empty")
        (let
          [text : String name]
          (if (process-string-contains-char? (& text) '=')
            (ProcessSomeString
              "process: environment variable name contains '='")
            (process-env-validation-error (box-get rest)))))]))

;: Return the first command validation error, or `ProcessNoString`.
(define (process-command-validation-error [command : ProcessCommand]) : ProcessMaybeString
  (if (string-eq (process-command-executable command) "")
    (ProcessSomeString "process: executable path is empty")
    (match (process-command-cwd command)
      [(ProcessSomeString cwd)
        (if (string-eq cwd "")
          (ProcessSomeString "process: cwd path is empty")
          (process-env-validation-error (process-command-env command)))]
      [(ProcessNoString)
        (process-env-validation-error (process-command-env command))])))

;: Return true when `command` passes stdlib validation.
(define (process-command-valid? [command : ProcessCommand]) : bool
  (match (process-command-validation-error command)
    [(ProcessNoString) true]
    [(ProcessSomeString _) false]))

;: Construct a public captured-output success result.
(define (process-output-ok-public
  [status : i64]
  [stdout : String]
  [stderr : String]) : ResultProcessOutput
  (OkProcessOutput (ProcessOutput status stdout stderr)))

;: Construct a public captured-output error result.
(define (process-output-error-public [error : ProcessError]) : ResultProcessOutput
  (ErrProcessOutput error))

;: Construct a public child success result.
(define (process-child-ok-public
  [pid : i64]
  [stdout-handle : i64]
  [stderr-handle : i64]) : ResultProcessChild
  (OkProcessChild (ProcessChild pid stdout-handle stderr-handle)))

;: Construct a public child error result.
(define (process-child-error-public [error : ProcessError]) : ResultProcessChild
  (ErrProcessChild error))

;: Convert a runtime error kind code and message to the public error enum.
(define (process-error-from-runtime-kind [kind : i64] [message : String]) : ProcessError
  (if (= kind 1)
    (ProcessSpawnFailed message)
    (if (= kind 2)
      (ProcessWaitFailed message)
      (if (= kind 3)
        (ProcessUnsupported message)
        (ProcessInvalidCommand message)))))

;: The process-execution runtime (`tl_process_output`, `tl_process_start`,
;: `tl_process_wait`) is implemented in TypeLisp in `process_runtime.tl`
;: (#2142 slice 4), replacing the former backend assembly. The public wrappers
;: validate first, then call those functions. Keep this import after the shared
;: data model and validation helpers so the runtime sees a complete module.
(import stdlib.process_runtime)

;: Convert public argv storage to the runtime module's no-cycle representation.
(define (process-runtime-args [args : ProcessStringList]) : process_runtime.ProcessStringList
  (let
    [step : ProcessStringStep (process-string-step args)]
    (if (process-string-step-present? step)
      (process_runtime.process-args-cons
        (process-string-step-value step)
        (process-runtime-args (process-string-step-rest step)))
      (process_runtime.process-args-empty))))

;: Convert public env storage to the runtime module's no-cycle representation.
(define (process-runtime-env [env : ProcessEnvList]) : process_runtime.ProcessEnvList
  (let
    [step : ProcessEnvStep (process-env-step env)]
    (if (process-env-step-present? step)
      (process_runtime.process-env-cons
        (process-env-step-name step)
        (process-env-step-value step)
        (process-runtime-env (process-env-step-rest step)))
      (process_runtime.process-env-empty))))

;: Convert a public optional string to the runtime module's no-cycle representation.
(define (process-runtime-maybe-string [value : ProcessMaybeString]) : process_runtime.ProcessMaybeString
  (let
    [info : ProcessMaybeStringInfo (process-maybe-string-info value)]
    (if (process-maybe-string-info-present? info)
      (process_runtime.process-some-string
        (process-maybe-string-info-value info))
      (process_runtime.process-no-string))))

;: Convert a public command to the runtime module's no-cycle representation.
(define (process-runtime-command [command : ProcessCommand]) : process_runtime.ProcessCommand
  (process_runtime.process-command-full
    (process-command-executable command)
    (process-runtime-args (process-command-argv command))
    (process-runtime-maybe-string (process-command-cwd command))
    (process-runtime-env (process-command-env command))
    (process-runtime-maybe-string (process-command-stdin command))))

;: Convert a public child handle to the runtime module's no-cycle representation.
(define (process-runtime-child [child : ProcessChild]) : process_runtime.ProcessChild
  (process_runtime.process-child
    (struct-get child pid)
    (struct-get child stdout-handle)
    (struct-get child stderr-handle)))

;: Convert a runtime captured-output result to the public result enum.
(define (process-output-from-runtime
  [result : process_runtime.ResultProcessOutput]) : ResultProcessOutput
  (let
    [info : process_runtime.ProcessOutputInfo
      (process_runtime.process-result-output-info result)]
    (if (struct-get info ok)
      (process-output-ok-public
        (struct-get info status)
        (struct-get info stdout)
        (struct-get info stderr))
      (process-output-error-public
        (process-error-from-runtime-kind
          (struct-get info kind)
          (struct-get info message))))))

;: Convert a runtime async-start result to the public result enum.
(define (process-child-from-runtime
  [result : process_runtime.ResultProcessChild]) : ResultProcessChild
  (let
    [info : process_runtime.ProcessChildInfo
      (process_runtime.process-result-child-info result)]
    (if (struct-get info ok)
      (process-child-ok-public
        (struct-get info pid)
        (struct-get info stdout-handle)
        (struct-get info stderr-handle))
      (process-child-error-public
        (process-error-from-runtime-kind
          (struct-get info kind)
          (struct-get info message))))))

;: Run a command and capture stdout, stderr, and exit status.
(define (process-output [command : ProcessCommand]) : ResultProcessOutput
  (let
    [validation : ProcessMaybeString (process-command-validation-error command)]
    [info : ProcessMaybeStringInfo (process-maybe-string-info validation)]
    (if (process-maybe-string-info-present? info)
      (process-output-error-public
        (process-error-from-runtime-kind
          0
          (process-maybe-string-info-value info)))
      (process-output-from-runtime
        (process_runtime.tl_process_output (process-runtime-command command))))))

;: Run a command using the same captured-output path as `process-output`.
(define (process-run [command : ProcessCommand]) : ResultProcessOutput
  (process-output command))

;: Start a command without waiting for process completion. The returned child
;: owns captured-output descriptors until it is passed to `process-wait`.
(define (process-start [command : ProcessCommand]) : ResultProcessChild
  (let
    [validation : ProcessMaybeString (process-command-validation-error command)]
    [info : ProcessMaybeStringInfo (process-maybe-string-info validation)]
    (if (process-maybe-string-info-present? info)
      (process-child-error-public
        (process-error-from-runtime-kind
          0
          (process-maybe-string-info-value info)))
      (process-child-from-runtime
        (process_runtime.tl_process_start (process-runtime-command command))))))

;: Wait for a child started by `process-start`, collect its captured output, and
;: release the child handle resources. Do not wait on the same child twice.
(define (process-wait [child : ProcessChild]) : ResultProcessOutput
  (process-output-from-runtime
    (process_runtime.tl_process_wait (process-runtime-child child))))

;: Inline test failure helper.
(define (process-test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test boolean assertion.
(define (process-test-assert [ok : bool]) : unit
  (if ok
    unit
    (process-test-fail)))

;: Inline test integer assertion.
(define (process-test-assert-i64-eq [actual : i64] [expected : i64]) : unit
  (process-test-assert (= actual expected)))

;: Inline test owned string assertion.
(define (process-test-assert-string-eq [actual : String] [expected : String]) : unit
  (process-test-assert (string-eq actual expected)))

;: Inline test assertion for an empty process string list.
(define (process-test-assert-string-empty [items : ProcessStringList]) : unit
  (match items
    [(ProcessStringNil) unit]
    [(ProcessStringCons _ _) (process-test-fail)]))

;: Inline test assertion for a one-item process string list.
(define (process-test-assert-string-list1
  [items : ProcessStringList]
  [first : String]) : unit
  (match items
    [(ProcessStringCons a rest)
      (match (box-get rest)
        [(ProcessStringNil) (process-test-assert-string-eq a first)]
        [_ (process-test-fail)])]
    [_ (process-test-fail)]))

;: Inline test assertion for a two-item process string list.
(define (process-test-assert-string-list2
  [items : ProcessStringList]
  [first : String]
  [second : String]) : unit
  (match items
    [(ProcessStringCons a rest)
      (match (box-get rest)
        [(ProcessStringCons b tail)
          (match (box-get tail)
            [(ProcessStringNil)
              (begin
                (process-test-assert-string-eq a first)
                (process-test-assert-string-eq b second))]
            [_ (process-test-fail)])]
        [_ (process-test-fail)])]
    [_ (process-test-fail)]))

;: Inline test assertion for a three-item process string list.
(define (process-test-assert-string-list3
  [items : ProcessStringList]
  [first : String]
  [second : String]
  [third : String]) : unit
  (match items
    [(ProcessStringCons a rest)
      (match (box-get rest)
        [(ProcessStringCons b more)
          (match (box-get more)
            [(ProcessStringCons c tail)
              (match (box-get tail)
                [(ProcessStringNil)
                  (begin
                    (process-test-assert-string-eq a first)
                    (process-test-assert-string-eq b second)
                    (process-test-assert-string-eq c third))]
                [_ (process-test-fail)])]
            [_ (process-test-fail)])]
        [_ (process-test-fail)])]
    [_ (process-test-fail)]))

;: Inline test assertion for a present optional process string.
(define (process-test-assert-some-string
  [value : ProcessMaybeString]
  [expected : String]) : unit
  (match value
    [(ProcessSomeString actual) (process-test-assert-string-eq actual expected)]
    [(ProcessNoString) (process-test-fail)]))

;: Inline test assertion for an absent optional process string.
(define (process-test-assert-no-string [value : ProcessMaybeString]) : unit
  (match value
    [(ProcessNoString) unit]
    [(ProcessSomeString _) (process-test-fail)]))

;: Inline test assertion for the head of a process environment list.
(define (process-test-assert-env-head
  [env : ProcessEnvList]
  [expected-name : String]
  [expected-value : String]) : unit
  (match env
    [(ProcessEnvCons name value _)
      (begin
        (process-test-assert-string-eq name expected-name)
        (process-test-assert-string-eq value expected-value))]
    [(ProcessEnvNil) (process-test-fail)]))

;: Inline test assertion for a two-entry process environment list.
(define (process-test-assert-env-list2
  [env : ProcessEnvList]
  [first-name : String]
  [first-value : String]
  [second-name : String]
  [second-value : String]) : unit
  (match env
    [(ProcessEnvCons name value rest)
      (begin
        (process-test-assert-string-eq name first-name)
        (process-test-assert-string-eq value first-value)
        (match (box-get rest)
          [(ProcessEnvCons next-name next-value tail)
            (begin
              (process-test-assert-string-eq next-name second-name)
              (process-test-assert-string-eq next-value second-value)
              (match (box-get tail)
                [(ProcessEnvNil) unit]
                [_ (process-test-fail)]))]
          [(ProcessEnvNil) (process-test-fail)]))]
    [(ProcessEnvNil) (process-test-fail)]))

;: Inline test assertion for process validation diagnostics.
(define (process-test-assert-validation
  [value : ProcessMaybeString]
  [expected : String]) : unit
  (match value
    [(ProcessSomeString actual) (process-test-assert-string-eq actual expected)]
    [(ProcessNoString) (process-test-fail)]))

;: Inline test body for command and argv helpers.
(define (process-test-command-api) : unit
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
      (process-test-assert-string-eq
        (process-command-executable command)
        "echo")
      (process-test-assert-string-list2 args "hello" "world")
      (process-test-assert-string-list3
        (process-command-argv command)
        "hello"
        "world"
        "!")
      (process-test-assert-i64-eq
        (process-args-count (process-command-argv command))
        3)
      (process-test-assert-string-list3
        (process-args-append args (process-args-single "again"))
        "hello"
        "world"
        "again")
      (process-test-assert-string-empty
        (process-args-from-string-vec (vector.string-vec-new)))
      (process-test-assert-string-list1
        (process-args-from-string-vec
          (vector.string-vec-push (vector.string-vec-new) "solo"))
        "solo")
      (process-test-assert-string-list3
        (process-args-from-string-vec
          (vector.string-vec-push
            (vector.string-vec-push
              (vector.string-vec-push
                (vector.string-vec-with-capacity 3)
                "hello")
              "world")
            "!"))
        "hello"
        "world"
        "!")
      (process-test-assert-string-empty
        (process-command-argv
          (process-command-from-argv-vec "echo" (vector.string-vec-new))))
      (process-test-assert-string-list1
        (process-command-argv
          (process-command-from-argv-vec
            "echo"
            (vector.string-vec-push (vector.string-vec-new) "solo")))
        "solo")
      (process-test-assert-string-list3
        (process-command-argv
          (process-command-from-argv-vec
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
        "!")
      (process-test-assert-string-list3
        (process-command-argv
          (process-command-with-argv-vec
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
        "argv")
      (process-test-assert-string-list3
        (process-command-argv
          (process-command-with-args-vec
            (process-command "echo" (process-args-single "base"))
            (vector.string-vec-push
              (vector.string-vec-push (vector.string-vec-with-capacity 2) "vec")
              "tail")))
        "base"
        "vec"
        "tail")
      (process-test-assert-some-string (process-command-cwd command) "target")
      (process-test-assert-some-string (process-command-stdin command) "stdin")
      (process-test-assert-env-head (process-command-env command) "TL_TEST" "1")
      (process-test-assert-i64-eq
        (process-env-count (process-command-env command))
        1)
      (process-test-assert-env-head
        (process-command-env
          (process-command-with-env-list
            command
            (process-env-cons "TL_REPLACED" "yes" (process-env-empty))))
        "TL_REPLACED"
        "yes")
      (process-test-assert-no-string
        (process-command-cwd (process-command "echo" (process-args-empty)))))))

;: Inline test body for vector-backed environment helpers.
(define (process-test-env-vec-api [command : ProcessCommand]) : unit
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
        (vector.string-vec-push (vector.string-vec-new) "ONLY_NAME")
        (vector.string-vec-new))]
    (begin
      (process-test-assert-i64-eq (process-env-vec-count env-vec-empty) 0)
      (process-test-assert (process-env-vec-valid? env-vec-empty))
      (process-test-assert-i64-eq (process-env-vec-count env-vec) 2)
      (process-test-assert (process-env-vec-valid? env-vec))
      (process-test-assert-env-list2
        (process-env-vec-to-list env-vec)
        "TL_FIRST"
        "one"
        "TL_SECOND"
        "two")
      (process-test-assert-env-list2
        (process-command-env (process-command-with-env-vec command env-vec))
        "TL_FIRST"
        "one"
        "TL_SECOND"
        "two")
      (process-test-assert-env-list2
        (process-env-vec-to-list env-dup)
        "TL_DUP"
        "first"
        "TL_DUP"
        "second")
      (process-test-assert-validation
        (process-env-vec-validation-error
          (process-env-vec-append (process-env-vec-new) "" "bad"))
        "process: environment variable name is empty")
      (process-test-assert-validation
        (process-env-vec-validation-error
          (process-env-vec-append (process-env-vec-new) "BAD=NAME" "bad"))
        "process: environment variable name contains '='")
      (process-test-assert-validation
        (process-env-vec-validation-error bad-shape)
        "process: environment vector name/value counts differ"))))

;: Inline test body for validation and result helpers.
(define (process-test-validation-api) : unit
  (let
    [command : ProcessCommand
      (process-command-with-env
        (process-command-with-cwd
          (process-command "echo" (process-args-empty))
          "target")
        "TL_TEST"
        "1")]
    (begin
      (process-test-env-vec-api command)
      (process-test-assert-validation
        (process-command-validation-error
          (process-command "" (process-args-empty)))
        "process: executable path is empty")
      (process-test-assert-validation
        (process-command-validation-error (process-command-with-cwd command ""))
        "process: cwd path is empty")
      (process-test-assert-validation
        (process-command-validation-error
          (process-command-with-env command "" "1"))
        "process: environment variable name is empty")
      (process-test-assert-validation
        (process-command-validation-error
          (process-command-with-env command "BAD=NAME" "1"))
        "process: environment variable name contains '='")
      (process-test-assert (process-command-valid? command))
      (process-test-assert
        (not (process-command-valid? (process-command "" (process-args-empty)))))
      (process-test-assert
        (process-result-success? (OkProcessOutput (ProcessOutput 0 "" ""))))
      (process-test-assert
        (not
          (process-result-success? (OkProcessOutput (ProcessOutput 7 "" "")))))
      (process-test-assert
        (process-result-stderr-nonempty?
          (OkProcessOutput (ProcessOutput 7 "" "stderr"))
          7))
      (process-test-assert
        (not
          (process-result-stderr-nonempty?
            (OkProcessOutput (ProcessOutput 7 "stdout" "stderr"))
            7)))
      (process-test-assert
        (not
          (process-result-success?
            (ErrProcessOutput (ProcessSpawnFailed "spawn failed")))))
      (process-test-assert
        (process-error-invalid-command?
          (ProcessInvalidCommand "invalid command")))
      (process-test-assert
        (process-error-spawn-failed? (ProcessSpawnFailed "spawn failed")))
      (process-test-assert
        (process-error-wait-failed? (ProcessWaitFailed "wait failed")))
      (process-test-assert
        (process-error-unsupported? (ProcessUnsupported "unsupported")))
      (process-test-assert
        (process-child-started? (OkProcessChild (ProcessChild 1 2 3))))
      (process-test-assert
        (not
          (process-child-started?
            (ErrProcessChild (ProcessUnsupported "unsupported"))))))))

(test
  process-api
  (begin
    (process-test-command-api)
    (process-test-validation-api)))

(export
  (value process-args-empty)
  (value process-args-count)
  (value process-args-cons)
  (value process-args-single)
  (value process-args-append)
  (value process-string-step)
  (value process-string-step-present?)
  (value process-string-step-value)
  (value process-string-step-rest)
  (value process-args-from-string-vec-from)
  (value process-args-from-string-vec)
  (value process-env-empty)
  (value process-env-count)
  (value process-env-cons)
  (value process-env-step)
  (value process-env-step-present?)
  (value process-env-step-name)
  (value process-env-step-value)
  (value process-env-step-rest)
  (value process-maybe-string-info)
  (value process-maybe-string-info-present?)
  (value process-maybe-string-info-value)
  (value process-string-contains-char?)
  (value process-env-vec-names)
  (value process-env-vec-values)
  (value process-env-vec-with-capacity)
  (value process-env-vec-new)
  (value process-env-vec-count)
  (value process-env-vec-append)
  (value process-env-vec-to-list-from)
  (value process-env-vec-to-list)
  (value process-env-vec-validation-error-from)
  (value process-env-vec-validation-error)
  (value process-env-vec-valid?)
  (value process-no-stdin)
  (value process-stdin-string)
  (value process-no-cwd)
  (value process-cwd)
  (value process-command)
  (value process-command-from-argv-vec)
  (value process-command-with-arg)
  (value process-command-with-args)
  (value process-command-with-argv-vec)
  (value process-command-with-args-vec)
  (value process-command-full)
  (value process-command-with-cwd)
  (value process-command-with-env)
  (value process-command-with-env-list)
  (value process-command-with-env-vec)
  (value process-command-with-stdin)
  (value process-command-executable)
  (value process-command-argv)
  (value process-command-cwd)
  (value process-command-env)
  (value process-command-stdin)
  (value process-output-status)
  (value process-output-stdout)
  (value process-output-stderr)
  (value process-success?)
  (value process-result-success?)
  (value process-child-started?)
  (value process-child-result-info)
  (value process-child-info-ok?)
  (value process-child-info-pid)
  (value process-child-info-stdout-handle)
  (value process-child-info-stderr-handle)
  (value process-result-status-or)
  (value process-result-output-eq?)
  (value process-result-stderr-nonempty?)
  (value process-child-result-pid-or)
  (value process-result-invalid-command?)
  (value process-result-error-message-or)
  (value process-child-result-invalid-command?)
  (value process-child-result-error-message-or)
  (value process-error-message)
  (value process-error-invalid-command?)
  (value process-error-spawn-failed?)
  (value process-error-wait-failed?)
  (value process-error-unsupported?)
  (value process-env-validation-error)
  (value process-command-validation-error)
  (value process-command-valid?)
  (value process-output)
  (value process-run)
  (value process-start)
  (value process-wait)
  (type ProcessStringList)
  (type ProcessMaybeString)
  (type ProcessEnvList)
  (type ProcessEnvVec)
  (type ProcessStringStep)
  (type ProcessEnvStep)
  (type ProcessMaybeStringInfo)
  (type ProcessChildInfo)
  (type ProcessCommand)
  (type ProcessOutput)
  (type ProcessChild)
  (type ProcessError)
  (type ResultProcessOutput)
  (type ResultProcessChild)
  (constructor ProcessEnvVec)
  (constructor ProcessStringStep)
  (constructor ProcessEnvStep)
  (constructor ProcessMaybeStringInfo)
  (constructor ProcessChildInfo)
  (constructor ProcessCommand)
  (constructor ProcessOutput)
  (constructor ProcessChild)
  (field ProcessEnvVec names)
  (field ProcessEnvVec values)
  (field ProcessStringStep present)
  (field ProcessStringStep value)
  (field ProcessStringStep rest)
  (field ProcessEnvStep present)
  (field ProcessEnvStep name)
  (field ProcessEnvStep value)
  (field ProcessEnvStep rest)
  (field ProcessMaybeStringInfo present)
  (field ProcessMaybeStringInfo value)
  (field ProcessChildInfo ok)
  (field ProcessChildInfo pid)
  (field ProcessChildInfo stdout-handle)
  (field ProcessChildInfo stderr-handle)
  (field ProcessCommand executable)
  (field ProcessCommand argv)
  (field ProcessCommand cwd)
  (field ProcessCommand env)
  (field ProcessCommand stdin)
  (field ProcessOutput status)
  (field ProcessOutput stdout)
  (field ProcessOutput stderr)
  (field ProcessChild pid)
  (field ProcessChild stdout-handle)
  (field ProcessChild stderr-handle)
  (variant ProcessStringNil)
  (variant ProcessStringCons)
  (variant ProcessNoString)
  (variant ProcessSomeString)
  (variant ProcessEnvNil)
  (variant ProcessEnvCons)
  (variant ProcessInvalidCommand)
  (variant ProcessSpawnFailed)
  (variant ProcessWaitFailed)
  (variant ProcessUnsupported)
  (variant OkProcessOutput)
  (variant ErrProcessOutput)
  (variant OkProcessChild)
  (variant ErrProcessChild))