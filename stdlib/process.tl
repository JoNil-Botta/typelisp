;# Process command API surface for TypeLisp.
;#
;# Defines the canonical process command/output/error data model for selfhost
;# tools. Runtime process execution is provided by `process_runtime.tl` through
;# `tl_process_output`, `tl_process_inherit`, `tl_process_start`, and
;# `tl_process_wait`;
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
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)

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
;: parallel generated string-vector buffers with the invariant that their live
;: lengths are equal. Runtime execution still consumes `ProcessEnvList`;
;: converting this representation preserves vector order and keeps duplicate
;: names.
(defstruct ProcessEnvVec
  (names svec.Vec)
  (values svec.Vec))

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
;: to `wait` rather than inspecting or constructing handles directly.
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
(define (string-step [args : ProcessStringList]) : ProcessStringStep
  (match args
    [(ProcessStringNil) (ProcessStringStep false "" (ProcessStringNil))]
    [(ProcessStringCons value rest)
      (ProcessStringStep true value (box-get rest))]))

;: Return whether a destructured argv step contains an item.
(define (string-step-present? [step : ProcessStringStep]) : bool
  (struct-get step present))

;: Return the argv value from a destructured step, or the empty string.
(define (string-step-value [step : ProcessStringStep]) : String
  (struct-get step value))

;: Return the argv tail from a destructured step.
(define (string-step-rest [step : ProcessStringStep]) : ProcessStringList
  (struct-get step rest))

;: Return a destructured step from an environment override list.
(define (env-step [env : ProcessEnvList]) : ProcessEnvStep
  (match env
    [(ProcessEnvNil) (ProcessEnvStep false "" "" (ProcessEnvNil))]
    [(ProcessEnvCons name value rest)
      (ProcessEnvStep true name value (box-get rest))]))

;: Return whether a destructured env step contains an item.
(define (env-step-present? [step : ProcessEnvStep]) : bool
  (struct-get step present))

;: Return the env name from a destructured step, or the empty string.
(define (env-step-name [step : ProcessEnvStep]) : String
  (struct-get step name))

;: Return the env value from a destructured step, or the empty string.
(define (env-step-value [step : ProcessEnvStep]) : String
  (struct-get step value))

;: Return the env tail from a destructured step.
(define (env-step-rest [step : ProcessEnvStep]) : ProcessEnvList
  (struct-get step rest))

;: Return a destructured optional string.
(define (maybe-string-info [value : ProcessMaybeString]) : ProcessMaybeStringInfo
  (match value
    [(ProcessNoString) (ProcessMaybeStringInfo false "")]
    [(ProcessSomeString text) (ProcessMaybeStringInfo true text)]))

;: Return whether a destructured optional string is present.
(define (maybe-string-info-present? [info : ProcessMaybeStringInfo]) : bool
  (struct-get info present))

;: Return the string from a destructured optional string, or the empty string.
(define (maybe-string-info-value [info : ProcessMaybeStringInfo]) : String
  (struct-get info value))

;: Return an empty argument list.
(define (args-empty) : ProcessStringList
  (ProcessStringNil))

;: Return the number of argv entries in `args`.
(define (args-count [args : ProcessStringList]) : i64
  (match args
    [(ProcessStringNil) 0]
    [(ProcessStringCons _ rest) (+ 1 (args-count (box-get rest)))]))

;: Prepend an owned argument string to an argv list.
(define (args-cons [value : String] [rest : ProcessStringList]) : ProcessStringList
  (ProcessStringCons value (box rest)))

;: Return a one-element argument list backed by an owned string.
(define (args-single [value : String]) : ProcessStringList
  (ProcessStringCons value (box (ProcessStringNil))))

;: Concatenate two argument lists while preserving argv order.
(define (args-append [left : ProcessStringList] [right : ProcessStringList]) : ProcessStringList
  (match left
    [(ProcessStringNil) right]
    [(ProcessStringCons value rest)
      (ProcessStringCons value (box (args-append (box-get rest) right)))]))

;: Convert a generated string-vector argv buffer to the list representation
;: consumed by `ProcessCommand`, preserving vector order.
(define (args-from-string-vec-from
  [args : (& args svec.Vec)]
  [index : i64]
  [out : ProcessStringList]) : ProcessStringList
  (if (< index 0)
    out
    (args-from-string-vec-from
      args
      (- index 1)
      (args-cons (svec.get args index "") out))))

;: Convert a generated string-vector argv buffer to the list representation
;: consumed by `ProcessCommand`, preserving vector order.
(define (args-from-string-vec [args : (& args svec.Vec)]) : ProcessStringList
  (args-from-string-vec-from args (- (svec.len args) 1) (ProcessStringNil)))

;: Return an empty environment override list.
(define (env-empty) : ProcessEnvList
  (ProcessEnvNil))

;: Return the number of env overrides in `env`.
(define (env-count [env : ProcessEnvList]) : i64
  (match env
    [(ProcessEnvNil) 0]
    [(ProcessEnvCons _ _ rest) (+ 1 (env-count (box-get rest)))]))

;: Prepend owned environment override strings to an env list.
(define (env-cons [name : String] [value : String] [rest : ProcessEnvList]) : ProcessEnvList
  (ProcessEnvCons name value (box rest)))

;: Return true when `text` contains `needle`.
(define (string-contains-char? [text : (& text str)] [needle : char]) : bool
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
(define (env-vec-names [env : (& env ProcessEnvVec)]) : (& env svec.Vec)
  (& (struct-get env names)))

;: Return the value buffer from a vector-backed env override set.
(define (env-vec-values [env : (& env ProcessEnvVec)]) : (& env svec.Vec)
  (& (struct-get env values)))

;: Create an empty vector-backed env override set with at least `capacity`
;: backing slots in each parallel buffer.
(define (env-vec-with-capacity [capacity : i64]) : ProcessEnvVec
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (ProcessEnvVec (svec.with-capacity cap) (svec.with-capacity cap))))

;: Create an empty vector-backed env override set.
(define (env-vec-new) : ProcessEnvVec
  (env-vec-with-capacity 4))

;: Return the number of vector-backed env overrides. Helper-created values keep
;: this equal to the live length of both buffers; manually constructed values
;: should be checked with `env-vec-validation-error`.
(define (env-vec-count [env : (& env ProcessEnvVec)]) : i64
  (svec.len (env-vec-names env)))

;: Append one owned environment override at the end of the vector-backed set.
;: Duplicate names are preserved in append order.
(define (env-vec-append
  [env : (&mut env ProcessEnvVec)]
  [name : String]
  [value : String]) : unit
  (begin
    (svec.push! (struct-get env names) name)
    (svec.push! (struct-get env values) value)))

;: Convert vector-backed env overrides to a list, preserving vector order at
;: the existing runtime boundary.
(define (env-vec-to-list-from
  [env : (& env ProcessEnvVec)]
  [index : i64]
  [out : ProcessEnvList]) : ProcessEnvList
  (if (< index 0)
    out
    (env-vec-to-list-from
      env
      (- index 1)
      (ProcessEnvCons
        (svec.get (env-vec-names env) index "")
        (svec.get (env-vec-values env) index "")
        (box out)))))

;: Convert vector-backed env overrides to the list representation consumed by
;: `ProcessCommand` and the process runtime.
(define (env-vec-to-list [env : (& env ProcessEnvVec)]) : ProcessEnvList
  (env-vec-to-list-from env (- (env-vec-count env) 1) (ProcessEnvNil)))

;: Return the first vector-backed env validation error, or `ProcessNoString`.
(define (env-vec-validation-error-from
  [env : (& env ProcessEnvVec)]
  [index : i64]) : ProcessMaybeString
  (if (>= index (env-vec-count env))
    (ProcessNoString)
    (let
      [name : String (svec.get (env-vec-names env) index "")]
      (if (string.eq name "")
        (ProcessSomeString "process: environment variable name is empty")
        (if (string-contains-char? (& name) '=')
          (ProcessSomeString "process: environment variable name contains '='")
          (env-vec-validation-error-from env (+ index 1)))))))

;: Return the first vector-backed env validation error, or `ProcessNoString`.
;: The inherited environment is filtered by names that appear in the override
;: set, then override entries are emitted in vector order. Duplicate override
;: names are preserved in vector order.
(define (env-vec-validation-error [env : (& env ProcessEnvVec)]) : ProcessMaybeString
  (if (not (= (svec.len (env-vec-names env)) (svec.len (env-vec-values env))))
    (ProcessSomeString "process: environment vector name/value counts differ")
    (env-vec-validation-error-from env 0)))

;: Return true when vector-backed env overrides satisfy the public invariant and
;: all override names are valid.
(define (env-vec-valid? [env : (& env ProcessEnvVec)]) : bool
  (match (env-vec-validation-error env)
    [(ProcessNoString) true]
    [(ProcessSomeString _) false]))

;: Return a command stdin value that provides no input.
(define (no-stdin) : ProcessMaybeString
  (ProcessNoString))

;: Return a command stdin value backed by an owned string.
(define (stdin-string [value : String]) : ProcessMaybeString
  (ProcessSomeString value))

;: Return a cwd value that inherits the current working directory.
(define (no-cwd) : ProcessMaybeString
  (ProcessNoString))

;: Return a cwd value that runs the command under an owned path string.
(define (cwd [value : String]) : ProcessMaybeString
  (ProcessSomeString value))

;: Construct a process command with owned executable storage and default cwd,
;: env, and stdin settings.
(define (command [executable : String] [argv : ProcessStringList]) : ProcessCommand
  (ProcessCommand
    executable
    argv
    (ProcessNoString)
    (ProcessEnvNil)
    (ProcessNoString)))

;: Construct a process command from an executable and a vector-backed argv
;: buffer. The command keeps the existing list-backed ABI after one conversion.
(define (command-from-argv-vec [executable : String] [argv : (& argv svec.Vec)]) : ProcessCommand
  (command executable (args-from-string-vec argv)))

;: Return a copy of `command` with `arg` appended after existing argv entries.
(define (command-with-arg [command : ProcessCommand] [arg : String]) : ProcessCommand
  (ProcessCommand
    (command-executable command)
    (args-append (command-argv command) (args-single arg))
    (command-cwd command)
    (command-env command)
    (command-stdin command)))

;: Return a copy of `command` with `args` appended after existing argv entries.
(define (command-with-args
  [command : ProcessCommand]
  [args : ProcessStringList]) : ProcessCommand
  (ProcessCommand
    (command-executable command)
    (args-append (command-argv command) args)
    (command-cwd command)
    (command-env command)
    (command-stdin command)))

;: Return a copy of `command` with the full argv list replaced by a
;: vector-backed argv buffer converted once at the compatibility boundary.
(define (command-with-argv-vec
  [command : ProcessCommand]
  [argv : (& argv svec.Vec)]) : ProcessCommand
  (ProcessCommand
    (command-executable command)
    (args-from-string-vec argv)
    (command-cwd command)
    (command-env command)
    (command-stdin command)))

;: Return a copy of `command` with vector-backed args appended after existing
;: argv entries through one list conversion and one list append.
(define (command-with-args-vec
  [command : ProcessCommand]
  [args : (& args svec.Vec)]) : ProcessCommand
  (command-with-args command (args-from-string-vec args)))

;: Construct a process command with every owned-storage field supplied
;: explicitly.
(define (command-full
  [executable : String]
  [argv : ProcessStringList]
  [cwd : ProcessMaybeString]
  [env : ProcessEnvList]
  [stdin : ProcessMaybeString]) : ProcessCommand
  (ProcessCommand executable argv cwd env stdin))

;: Return a copy of `command` with cwd set to `cwd`.
(define (command-with-cwd [command : ProcessCommand] [cwd : String]) : ProcessCommand
  (ProcessCommand
    (command-executable command)
    (command-argv command)
    (ProcessSomeString cwd)
    (command-env command)
    (command-stdin command)))

;: Return a copy of `command` with an additional env override.
(define (command-with-env
  [command : ProcessCommand]
  [name : String]
  [value : String]) : ProcessCommand
  (ProcessCommand
    (command-executable command)
    (command-argv command)
    (command-cwd command)
    (ProcessEnvCons name value (box (command-env command)))
    (command-stdin command)))

;: Return a copy of `command` with the full env override list replaced.
(define (command-with-env-list
  [command : ProcessCommand]
  [env : ProcessEnvList]) : ProcessCommand
  (ProcessCommand
    (command-executable command)
    (command-argv command)
    (command-cwd command)
    env
    (command-stdin command)))

;: Return a copy of `command` with env overrides replaced by vector-backed
;: storage converted to the existing list-backed runtime boundary.
(define (command-with-env-vec
  [command : ProcessCommand]
  [env : (& env ProcessEnvVec)]) : ProcessCommand
  (command-with-env-list command (env-vec-to-list env)))

;: Return a copy of `command` with stdin set to `stdin`.
(define (command-with-stdin [command : ProcessCommand] [stdin : String]) : ProcessCommand
  (ProcessCommand
    (command-executable command)
    (command-argv command)
    (command-cwd command)
    (command-env command)
    (ProcessSomeString stdin)))

;: Return the executable path from `command`.
(define (command-executable [command : ProcessCommand]) : String
  (struct-get command executable))

;: Return the argv list from `command`.
(define (command-argv [command : ProcessCommand]) : ProcessStringList
  (struct-get command argv))

;: Return the cwd setting from `command`.
(define (command-cwd [command : ProcessCommand]) : ProcessMaybeString
  (struct-get command cwd))

;: Return the env override list from `command`.
(define (command-env [command : ProcessCommand]) : ProcessEnvList
  (struct-get command env))

;: Return the stdin setting from `command`.
(define (command-stdin [command : ProcessCommand]) : ProcessMaybeString
  (struct-get command stdin))

;: Return the process exit status.
(define (output-status [output : ProcessOutput]) : i64
  (struct-get output status))

;: Return captured stdout from `output`.
(define (output-stdout [output : ProcessOutput]) : String
  (struct-get output stdout))

;: Return captured stderr from `output`.
(define (output-stderr [output : ProcessOutput]) : String
  (struct-get output stderr))

;: Return true when the process exit status is zero.
(define (success? [output : ProcessOutput]) : bool
  (= (output-status output) 0))

;: Return `result` through the aggregate return path so stage0 can match it in
;: modules that import other modules.
(define (result-output-normalize [result : ResultProcessOutput]) : ResultProcessOutput
  result)

;: Return `result` through the aggregate return path so stage0 can match it in
;: modules that import other modules.
(define (result-child-normalize [result : ResultProcessChild]) : ResultProcessChild
  result)

;: Return true when `result` is a successful zero-exit process output.
(define (result-success? [result : ResultProcessOutput]) : bool
  (match (result-output-normalize result)
    [(OkProcessOutput output) (success? output)]
    [(ErrProcessOutput _) false]))

;: Return true when `result` is a started child handle.
(define (child-started? [result : ResultProcessChild]) : bool
  (match (result-child-normalize result)
    [(OkProcessChild _) true]
    [(ErrProcessChild _) false]))

;: Destructure a child result in one pass.
(define (child-result-info [result : ResultProcessChild]) : ProcessChildInfo
  (match result
    [(OkProcessChild child)
      (ProcessChildInfo
        true
        (struct-get child pid)
        (struct-get child stdout-handle)
        (struct-get child stderr-handle))]
    [(ErrProcessChild _) (ProcessChildInfo false (- 0 1) (- 0 1) (- 0 1))]))

;: Return true when `info` describes a started child.
(define (child-info-ok? [info : ProcessChildInfo]) : bool
  (struct-get info ok))

;: Return the child pid from `info`, or -1 when it is not ok.
(define (child-info-pid [info : ProcessChildInfo]) : i64
  (struct-get info pid))

;: Return the child stdout handle from `info`, or -1 when it is not ok.
(define (child-info-stdout-handle [info : ProcessChildInfo]) : i64
  (struct-get info stdout-handle))

;: Return the child stderr handle from `info`, or -1 when it is not ok.
(define (child-info-stderr-handle [info : ProcessChildInfo]) : i64
  (struct-get info stderr-handle))

;: Return the output status, or `fallback` when `result` is an error.
(define (result-status-or [result : ResultProcessOutput] [fallback : i64]) : i64
  (match (result-output-normalize result)
    [(OkProcessOutput output) (output-status output)]
    [(ErrProcessOutput _) fallback]))

;: Return true when `result` is an `Ok` output matching all expected fields.
(define (result-output-eq?
  [result : ResultProcessOutput]
  [expected-status : i64]
  [expected-stdout : String]
  [expected-stderr : String]) : bool
  (match result
    [(OkProcessOutput output)
      (if (= (output-status output) expected-status)
        (if (string.eq (output-stdout output) expected-stdout)
          (string.eq (output-stderr output) expected-stderr)
          false)
        false)]
    [(ErrProcessOutput _) false]))

;: Return true when `result` is an `Ok` output with empty stdout and nonempty stderr.
(define (result-stderr-nonempty?
  [result : ResultProcessOutput]
  [expected-status : i64]) : bool
  (match result
    [(OkProcessOutput output)
      (if (= (output-status output) expected-status)
        (if (= (string-length (output-stdout output)) 0)
          (> (string-length (output-stderr output)) 0)
          false)
        false)]
    [(ErrProcessOutput _) false]))

;: Return the child pid, or `fallback` when `result` is an error.
(define (child-result-pid-or [result : ResultProcessChild] [fallback : i64]) : i64
  (match (result-child-normalize result)
    [(OkProcessChild child) (struct-get child pid)]
    [(ErrProcessChild _) fallback]))

;: Return true when an output result carries an invalid-command error.
(define (result-invalid-command? [result : ResultProcessOutput]) : bool
  (match (result-output-normalize result)
    [(ErrProcessOutput error) (error-invalid-command? error)]
    [(OkProcessOutput _) false]))

;: Return an output result error message, or `fallback` when it is ok.
(define (result-error-message-or
  [result : ResultProcessOutput]
  [fallback : String]) : String
  (match (result-output-normalize result)
    [(ErrProcessOutput error) (error-message error)]
    [(OkProcessOutput _) fallback]))

;: Return true when a child result carries an invalid-command error.
(define (child-result-invalid-command? [result : ResultProcessChild]) : bool
  (match (result-child-normalize result)
    [(ErrProcessChild error) (error-invalid-command? error)]
    [(OkProcessChild _) false]))

;: Return a child result error message, or `fallback` when it is ok.
(define (child-result-error-message-or
  [result : ResultProcessChild]
  [fallback : String]) : String
  (match (result-child-normalize result)
    [(ErrProcessChild error) (error-message error)]
    [(OkProcessChild _) fallback]))

;: Return `error` through the aggregate return path so stage0 can match it in
;: modules that import other modules.
(define (error-normalize [error : ProcessError]) : ProcessError
  error)

;: Return the diagnostic message stored in `error`.
(define (error-message [error : ProcessError]) : String
  (match (error-normalize error)
    [(ProcessInvalidCommand message) message]
    [(ProcessSpawnFailed message) message]
    [(ProcessWaitFailed message) message]
    [(ProcessUnsupported message) message]))

;: Return true when `error` is a command validation diagnostic.
(define (error-invalid-command? [error : ProcessError]) : bool
  (match (error-normalize error)
    [(ProcessInvalidCommand _) true]
    [_ false]))

;: Return true when `error` is a spawn failure diagnostic.
(define (error-spawn-failed? [error : ProcessError]) : bool
  (match (error-normalize error)
    [(ProcessSpawnFailed _) true]
    [_ false]))

;: Return true when `error` is a wait failure diagnostic.
(define (error-wait-failed? [error : ProcessError]) : bool
  (match (error-normalize error)
    [(ProcessWaitFailed _) true]
    [_ false]))

;: Return true when `error` is an unsupported runtime/platform diagnostic.
(define (error-unsupported? [error : ProcessError]) : bool
  (match (error-normalize error)
    [(ProcessUnsupported _) true]
    [_ false]))

;: Return the first env validation error, or `ProcessNoString`.
(define (env-validation-error [env : ProcessEnvList]) : ProcessMaybeString
  (match env
    [(ProcessEnvNil) (ProcessNoString)]
    [(ProcessEnvCons name _ rest)
      (if (string.eq name "")
        (ProcessSomeString "process: environment variable name is empty")
        (if (string-contains-char? (& name) '=')
          (ProcessSomeString "process: environment variable name contains '='")
          (env-validation-error (box-get rest))))]))

;: Return the first command validation error, or `ProcessNoString`.
(define (command-validation-error [command : ProcessCommand]) : ProcessMaybeString
  (if (string.eq (command-executable command) "")
    (ProcessSomeString "process: executable path is empty")
    (match (command-cwd command)
      [(ProcessSomeString cwd)
        (if (string.eq cwd "")
          (ProcessSomeString "process: cwd path is empty")
          (env-validation-error (command-env command)))]
      [(ProcessNoString) (env-validation-error (command-env command))])))

;: Return true when `command` passes stdlib validation.
(define (command-valid? [command : ProcessCommand]) : bool
  (match (command-validation-error command)
    [(ProcessNoString) true]
    [(ProcessSomeString _) false]))

;: Construct a public captured-output success result.
(define (output-ok-public [status : i64] [stdout : String] [stderr : String]) : ResultProcessOutput
  (OkProcessOutput (ProcessOutput status stdout stderr)))

;: Construct a public captured-output error result.
(define (output-error-public [error : ProcessError]) : ResultProcessOutput
  (ErrProcessOutput error))

;: Construct a public child success result.
(define (child-ok-public
  [pid : i64]
  [stdout-handle : i64]
  [stderr-handle : i64]) : ResultProcessChild
  (OkProcessChild (ProcessChild pid stdout-handle stderr-handle)))

;: Construct a public child error result.
(define (child-error-public [error : ProcessError]) : ResultProcessChild
  (ErrProcessChild error))

;: Convert a runtime error kind code and message to the public error enum.
(define (error-from-runtime-kind [kind : i64] [message : String]) : ProcessError
  (cond
    [(= kind 1) (ProcessSpawnFailed message)]
    [(= kind 2) (ProcessWaitFailed message)]
    [(= kind 3) (ProcessUnsupported message)]
    [else (ProcessInvalidCommand message)]))

;: The process-execution runtime (`tl_process_output`, `tl_process_inherit`,
;: `tl_process_start`, `tl_process_wait`) is implemented in TypeLisp in
;: `process_runtime.tl`,
;: replacing the former backend assembly. The public wrappers
;: validate first, then call those functions. Keep this import after the shared
;: data model and validation helpers so the runtime sees a complete module.
(import stdlib.process_runtime)

;: Convert public argv storage to the runtime module's no-cycle representation.
(define (runtime-args [args : ProcessStringList]) : process_runtime.ProcessRuntimeStringList
  (let
    [step : ProcessStringStep (string-step args)]
    (if (string-step-present? step)
      (process_runtime.args-cons
        (string-step-value step)
        (runtime-args (string-step-rest step)))
      (process_runtime.args-empty))))

;: Convert public env storage to the runtime module's no-cycle representation.
(define (runtime-env [env : ProcessEnvList]) : process_runtime.ProcessRuntimeEnvList
  (let
    [step : ProcessEnvStep (env-step env)]
    (if (env-step-present? step)
      (process_runtime.env-cons
        (env-step-name step)
        (env-step-value step)
        (runtime-env (env-step-rest step)))
      (process_runtime.env-empty))))

;: Convert a public optional string to the runtime module's no-cycle representation.
(define (runtime-maybe-string [value : ProcessMaybeString]) : process_runtime.ProcessRuntimeMaybeString
  (let
    [info : ProcessMaybeStringInfo (maybe-string-info value)]
    (if (maybe-string-info-present? info)
      (process_runtime.some-string (maybe-string-info-value info))
      (process_runtime.no-string))))

;: Convert a public command to the runtime module's no-cycle representation.
(define (runtime-command [command : ProcessCommand]) : process_runtime.ProcessRuntimeCommand
  (process_runtime.command-full
    (command-executable command)
    (runtime-args (command-argv command))
    (runtime-maybe-string (command-cwd command))
    (runtime-env (command-env command))
    (runtime-maybe-string (command-stdin command))))

;: Convert a public child handle to the runtime module's no-cycle representation.
(define (runtime-child [child : ProcessChild]) : process_runtime.ProcessRuntimeChild
  (process_runtime.child
    (struct-get child pid)
    (struct-get child stdout-handle)
    (struct-get child stderr-handle)))

;: Convert a runtime captured-output result to the public result enum.
(define (output-from-runtime
  [result : process_runtime.ResultProcessRuntimeOutput]) : ResultProcessOutput
  (let
    [info : process_runtime.ProcessRuntimeOutputInfo
      (process_runtime.result-output-info result)]
    (if (struct-get info ok)
      (output-ok-public
        (struct-get info status)
        (struct-get info stdout)
        (struct-get info stderr))
      (output-error-public
        (error-from-runtime-kind
          (struct-get info kind)
          (struct-get info message))))))

;: Convert a runtime async-start result to the public result enum.
(define (child-from-runtime
  [result : process_runtime.ResultProcessRuntimeChild]) : ResultProcessChild
  (let
    [info : process_runtime.ProcessRuntimeChildInfo
      (process_runtime.result-child-info result)]
    (if (struct-get info ok)
      (child-ok-public
        (struct-get info pid)
        (struct-get info stdout-handle)
        (struct-get info stderr-handle))
      (child-error-public
        (error-from-runtime-kind
          (struct-get info kind)
          (struct-get info message))))))

;: Run a command and capture stdout, stderr, and exit status.
(define (output [command : ProcessCommand]) : ResultProcessOutput
  (let
    [validation : ProcessMaybeString (command-validation-error command)]
    [info : ProcessMaybeStringInfo (maybe-string-info validation)]
    (if (maybe-string-info-present? info)
      (output-error-public
        (error-from-runtime-kind 0 (maybe-string-info-value info)))
      (output-from-runtime
        (process_runtime.tl_process_output (runtime-command command))))))

;: Run a command while inheriting the caller's stdout and stderr streams.
;:
;: Child output is visible as it is written instead of being captured until
;: process exit. The successful result carries the exit status and empty
;: captured-output strings.
(define (inherit [command : ProcessCommand]) : ResultProcessOutput
  (let
    [validation : ProcessMaybeString (command-validation-error command)]
    [info : ProcessMaybeStringInfo (maybe-string-info validation)]
    (if (maybe-string-info-present? info)
      (output-error-public
        (error-from-runtime-kind 0 (maybe-string-info-value info)))
      (output-from-runtime
        (process_runtime.tl_process_inherit (runtime-command command))))))

;: Run a command using the same captured-output path as `output`.
(define (run [command : ProcessCommand]) : ResultProcessOutput
  (output command))

;: Start a command without waiting for process completion. The returned child
;: owns captured-output descriptors until it is passed to `wait`.
(define (start [command : ProcessCommand]) : ResultProcessChild
  (let
    [validation : ProcessMaybeString (command-validation-error command)]
    [info : ProcessMaybeStringInfo (maybe-string-info validation)]
    (if (maybe-string-info-present? info)
      (child-error-public
        (error-from-runtime-kind 0 (maybe-string-info-value info)))
      (child-from-runtime
        (process_runtime.tl_process_start (runtime-command command))))))

;: Wait for a child started by `start`, collect its captured output, and
;: release the child handle resources. Do not wait on the same child twice.
(define (wait [child : ProcessChild]) : ResultProcessOutput
  (output-from-runtime (process_runtime.tl_process_wait (runtime-child child))))

;: Inline test failure helper.
(define (test-fail) : unit
  (begin
    (/ 1 0)
    unit))

;: Inline test boolean assertion.
(define (test-assert [ok : bool]) : unit
  (if ok
    unit
    (test-fail)))

;: Inline test integer assertion.
(define (test-assert-i64-eq [actual : i64] [expected : i64]) : unit
  (test-assert (= actual expected)))

;: Inline test owned string assertion.
(define (test-assert-string-eq [actual : String] [expected : String]) : unit
  (test-assert (string.eq actual expected)))

;: Inline test assertion for an empty process string list.
(define (test-assert-string-empty [items : ProcessStringList]) : unit
  (match items
    [(ProcessStringNil) unit]
    [(ProcessStringCons _ _) (test-fail)]))

;: Inline test assertion for a one-item process string list.
(define (test-assert-string-list1 [items : ProcessStringList] [first : String]) : unit
  (match items
    [(ProcessStringCons a rest)
      (match (box-get rest)
        [(ProcessStringNil) (test-assert-string-eq a first)]
        [_ (test-fail)])]
    [_ (test-fail)]))

;: Inline test assertion for a two-item process string list.
(define (test-assert-string-list2
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
                (test-assert-string-eq a first)
                (test-assert-string-eq b second))]
            [_ (test-fail)])]
        [_ (test-fail)])]
    [_ (test-fail)]))

;: Inline test assertion for a three-item process string list.
(define (test-assert-string-list3
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
                    (test-assert-string-eq a first)
                    (test-assert-string-eq b second)
                    (test-assert-string-eq c third))]
                [_ (test-fail)])]
            [_ (test-fail)])]
        [_ (test-fail)])]
    [_ (test-fail)]))

;: Inline test assertion for a present optional process string.
(define (test-assert-some-string
  [value : ProcessMaybeString]
  [expected : String]) : unit
  (match value
    [(ProcessSomeString actual) (test-assert-string-eq actual expected)]
    [(ProcessNoString) (test-fail)]))

;: Inline test assertion for an absent optional process string.
(define (test-assert-no-string [value : ProcessMaybeString]) : unit
  (match value
    [(ProcessNoString) unit]
    [(ProcessSomeString _) (test-fail)]))

;: Inline test assertion for the head of a process environment list.
(define (test-assert-env-head
  [env : ProcessEnvList]
  [expected-name : String]
  [expected-value : String]) : unit
  (match env
    [(ProcessEnvCons name value _)
      (begin
        (test-assert-string-eq name expected-name)
        (test-assert-string-eq value expected-value))]
    [(ProcessEnvNil) (test-fail)]))

;: Inline test assertion for a two-entry process environment list.
(define (test-assert-env-list2
  [env : ProcessEnvList]
  [first-name : String]
  [first-value : String]
  [second-name : String]
  [second-value : String]) : unit
  (match env
    [(ProcessEnvCons name value rest)
      (begin
        (test-assert-string-eq name first-name)
        (test-assert-string-eq value first-value)
        (match (box-get rest)
          [(ProcessEnvCons next-name next-value tail)
            (begin
              (test-assert-string-eq next-name second-name)
              (test-assert-string-eq next-value second-value)
              (match (box-get tail)
                [(ProcessEnvNil) unit]
                [_ (test-fail)]))]
          [(ProcessEnvNil) (test-fail)]))]
    [(ProcessEnvNil) (test-fail)]))

;: Inline test assertion for process validation diagnostics.
(define (test-assert-validation
  [value : ProcessMaybeString]
  [expected : String]) : unit
  (match value
    [(ProcessSomeString actual) (test-assert-string-eq actual expected)]
    [(ProcessNoString) (test-fail)]))

;: Inline test helper for generated string-vector argv buffers.
(define (test-string-vec0) : svec.Vec
  (svec.new))

;: Inline test helper for generated string-vector argv buffers.
(define (test-string-vec1 [a : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.new)]
    (begin
      (svec.push! items a)
      items)))

;: Inline test helper for generated string-vector argv buffers.
(define (test-string-vec2 [a : String] [b : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.with-capacity 2)]
    (begin
      (svec.push! items a)
      (svec.push! items b)
      items)))

;: Inline test helper for generated string-vector argv buffers.
(define (test-string-vec3 [a : String] [b : String] [c : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.with-capacity 3)]
    (begin
      (svec.push! items a)
      (svec.push! items b)
      (svec.push! items c)
      items)))

;: Inline test helper for vector-backed environment overrides.
(define (test-env-vec1 [name : String] [value : String]) : ProcessEnvVec
  (let
    [env : ProcessEnvVec (env-vec-new)]
    (begin
      (env-vec-append (&mut env) name value)
      env)))

;: Inline test helper for vector-backed environment overrides.
(define (test-env-vec2
  [name-a : String]
  [value-a : String]
  [name-b : String]
  [value-b : String]) : ProcessEnvVec
  (let
    [env : ProcessEnvVec (env-vec-new)]
    (begin
      (env-vec-append (&mut env) name-a value-a)
      (env-vec-append (&mut env) name-b value-b)
      env)))

;: Inline test helper for malformed vector-backed environment overrides.
(define (test-env-vec-bad-shape) : ProcessEnvVec
  (let
    [names : svec.Vec (svec.new)]
    [values : svec.Vec (svec.new)]
    (begin
      (svec.push! names "ONLY_NAME")
      (ProcessEnvVec names values))))

;: Inline test body for command and argv helpers.
(define (test-command-api) : unit
  (let
    [args : ProcessStringList
      (args-cons "hello" (args-cons "world" (args-empty)))]
    [cmd : ProcessCommand
      (command-with-arg
        (command-with-env
          (command-with-stdin
            (command-with-cwd (command "echo" args) "target")
            "stdin")
          "TL_TEST"
          "1")
        "!")]
    (begin
      (test-assert-string-eq (command-executable cmd) "echo")
      (test-assert-string-list2 args "hello" "world")
      (test-assert-string-list3 (command-argv cmd) "hello" "world" "!")
      (test-assert-i64-eq (args-count (command-argv cmd)) 3)
      (test-assert-string-list3
        (args-append args (args-single "again"))
        "hello"
        "world"
        "again")
      (let
        [empty-argv : svec.Vec (test-string-vec0)]
        [solo-argv : svec.Vec (test-string-vec1 "solo")]
        [multi-argv : svec.Vec (test-string-vec3 "hello" "world" "!")]
        [replace-argv : svec.Vec (test-string-vec3 "vec" "replace" "argv")]
        [tail-argv : svec.Vec (test-string-vec2 "vec" "tail")]
        (begin
          (test-assert-string-empty (args-from-string-vec (& empty-argv)))
          (test-assert-string-list1 (args-from-string-vec (& solo-argv)) "solo")
          (test-assert-string-list3
            (args-from-string-vec (& multi-argv))
            "hello"
            "world"
            "!")
          (test-assert-string-empty
            (command-argv (command-from-argv-vec "echo" (& empty-argv))))
          (test-assert-string-list1
            (command-argv (command-from-argv-vec "echo" (& solo-argv)))
            "solo")
          (test-assert-string-list3
            (command-argv (command-from-argv-vec "echo" (& multi-argv)))
            "hello"
            "world"
            "!")
          (test-assert-string-list3
            (command-argv (command-with-argv-vec cmd (& replace-argv)))
            "vec"
            "replace"
            "argv")
          (test-assert-string-list3
            (command-argv
              (command-with-args-vec
                (command "echo" (args-single "base"))
                (& tail-argv)))
            "base"
            "vec"
            "tail")))
      (test-assert-some-string (command-cwd cmd) "target")
      (test-assert-some-string (command-stdin cmd) "stdin")
      (test-assert-env-head (command-env cmd) "TL_TEST" "1")
      (test-assert-i64-eq (env-count (command-env cmd)) 1)
      (test-assert-env-head
        (command-env
          (command-with-env-list cmd (env-cons "TL_REPLACED" "yes" (env-empty))))
        "TL_REPLACED"
        "yes")
      (test-assert-no-string (command-cwd (command "echo" (args-empty)))))))

;: Inline test body for vector-backed environment helpers.
(define (test-env-vec-api [cmd : ProcessCommand]) : unit
  (let
    [env-vec-empty : ProcessEnvVec (env-vec-new)]
    [env-vec : ProcessEnvVec (test-env-vec2 "TL_FIRST" "one" "TL_SECOND" "two")]
    [env-dup : ProcessEnvVec (test-env-vec2 "TL_DUP" "first" "TL_DUP" "second")]
    [bad-empty : ProcessEnvVec (test-env-vec1 "" "bad")]
    [bad-name : ProcessEnvVec (test-env-vec1 "BAD=NAME" "bad")]
    [bad-shape : ProcessEnvVec (test-env-vec-bad-shape)]
    (begin
      (test-assert-i64-eq (env-vec-count (& env-vec-empty)) 0)
      (test-assert (env-vec-valid? (& env-vec-empty)))
      (test-assert-i64-eq (env-vec-count (& env-vec)) 2)
      (test-assert (env-vec-valid? (& env-vec)))
      (test-assert-env-list2
        (env-vec-to-list (& env-vec))
        "TL_FIRST"
        "one"
        "TL_SECOND"
        "two")
      (test-assert-env-list2
        (command-env (command-with-env-vec cmd (& env-vec)))
        "TL_FIRST"
        "one"
        "TL_SECOND"
        "two")
      (test-assert-env-list2
        (env-vec-to-list (& env-dup))
        "TL_DUP"
        "first"
        "TL_DUP"
        "second")
      (test-assert-validation
        (env-vec-validation-error (& bad-empty))
        "process: environment variable name is empty")
      (test-assert-validation
        (env-vec-validation-error (& bad-name))
        "process: environment variable name contains '='")
      (test-assert-validation
        (env-vec-validation-error (& bad-shape))
        "process: environment vector name/value counts differ"))))

;: Inline test body for validation and result helpers.
(define (test-validation-api) : unit
  (let
    [cmd : ProcessCommand
      (command-with-env
        (command-with-cwd (command "echo" (args-empty)) "target")
        "TL_TEST"
        "1")]
    (begin
      (test-env-vec-api cmd)
      (test-assert-validation
        (command-validation-error (command "" (args-empty)))
        "process: executable path is empty")
      (test-assert-validation
        (command-validation-error (command-with-cwd cmd ""))
        "process: cwd path is empty")
      (test-assert-validation
        (command-validation-error (command-with-env cmd "" "1"))
        "process: environment variable name is empty")
      (test-assert-validation
        (command-validation-error (command-with-env cmd "BAD=NAME" "1"))
        "process: environment variable name contains '='")
      (test-assert (command-valid? cmd))
      (test-assert (not (command-valid? (command "" (args-empty)))))
      (test-assert (result-success? (OkProcessOutput (ProcessOutput 0 "" ""))))
      (test-assert
        (not (result-success? (OkProcessOutput (ProcessOutput 7 "" "")))))
      (test-assert
        (result-stderr-nonempty?
          (OkProcessOutput (ProcessOutput 7 "" "stderr"))
          7))
      (test-assert
        (not
          (result-stderr-nonempty?
            (OkProcessOutput (ProcessOutput 7 "stdout" "stderr"))
            7)))
      (test-assert
        (not
          (result-success?
            (ErrProcessOutput (ProcessSpawnFailed "spawn failed")))))
      (test-assert
        (error-invalid-command? (ProcessInvalidCommand "invalid command")))
      (test-assert (error-spawn-failed? (ProcessSpawnFailed "spawn failed")))
      (test-assert (error-wait-failed? (ProcessWaitFailed "wait failed")))
      (test-assert (error-unsupported? (ProcessUnsupported "unsupported")))
      (test-assert (child-started? (OkProcessChild (ProcessChild 1 2 3))))
      (test-assert
        (not
          (child-started? (ErrProcessChild (ProcessUnsupported "unsupported"))))))))