;# stdlib/process_runtime.tl - Process-execution runtime for TypeLisp.
;#
;# Pure-TypeLisp implementations of the `tl_process_output`,
;# `tl_process_inherit`, `tl_process_start`, and `tl_process_wait` runtime
;# helpers that the `tl` API surface calls.
;# These replace the former hand-written backend assembly
;# (`compiler-backend-runtime-process-output-functions` and
;# `compiler-backend-runtime-windows-process-output-functions`): the bodies below
;# issue the same OS calls directly, selecting per-target behavior with
;# `(cfg windows …)`.
;#
;# Linux uses raw syscalls (memfd-captured stdout/stderr, a pipe2 stdin feed, an
;# `execve` failure-marker pipe, vfork/execve, and wait4 exit-status decoding) and
;# fully supports the asynchronous `start`/`wait` pair. Windows uses kernel32
;# (CreateProcessA with temp-file stdout/stderr redirection) for the captured
;# `output` path and reports the asynchronous `start`/`wait` pair as unsupported,
;# matching the previous backend behavior.
;# `inherit` leaves a child attached to the caller's stdout/stderr streams while
;# still waiting for and returning its exit status.
;#
;# Usage: imported by `tl` (which provides the public wrappers).
(import stdlib.array)
(import stdlib.byte_buf_core)
(import stdlib.env)

;: Private runtime argv list. `tl` converts the public process model to
;: this no-cycle representation before invoking the OS runtime.
(defenum ProcessRuntimeStringList
  (ProcessRuntimeStringNil)
  (ProcessRuntimeStringCons String (Box ProcessRuntimeStringList)))

;: Private runtime optional string value.
(defstruct ProcessRuntimeMaybeString
  (present bool)
  (value String))

;: Private runtime environment override list.
(defenum ProcessRuntimeEnvList
  (ProcessRuntimeEnvNil)
  (ProcessRuntimeEnvCons String String (Box ProcessRuntimeEnvList)))

;: Private argv step used by the runtime's linear scans.
(defstruct ProcessRuntimeStringStep
  (present bool)
  (value String)
  (rest ProcessRuntimeStringList))

;: Private environment-list step used by the runtime's linear scans.
(defstruct ProcessRuntimeEnvStep
  (present bool)
  (name String)
  (value String)
  (rest ProcessRuntimeEnvList))

;: Private optional string view.
(defstruct ProcessRuntimeMaybeStringInfo
  (present bool)
  (value String))

;: Private runtime command data.
(defstruct ProcessRuntimeCommand
  (executable String)
  (argv ProcessRuntimeStringList)
  (cwd ProcessRuntimeMaybeString)
  (env ProcessRuntimeEnvList)
  (stdin ProcessRuntimeMaybeString))

;: Private captured output data.
(defstruct ProcessRuntimeOutput
  (status i64)
  (stdout String)
  (stderr String))

;: Private asynchronous process handle data.
(defstruct ProcessRuntimeChild
  (pid i64)
  (stdout-handle i64)
  (stderr-handle i64))

;: Private structured runtime failures.
(defenum ProcessRuntimeError
  (ProcessRuntimeInvalidCommand String)
  (ProcessRuntimeSpawnFailed String)
  (ProcessRuntimeWaitFailed String)
  (ProcessRuntimeUnsupported String))

;: Private runtime captured-output result.
(defenum ResultProcessRuntimeOutput
  (OkProcessRuntimeOutput ProcessRuntimeOutput)
  (ErrProcessRuntimeOutput ProcessRuntimeError))

;: Private runtime async-start result.
(defenum ResultProcessRuntimeChild
  (OkProcessRuntimeChild ProcessRuntimeChild)
  (ErrProcessRuntimeChild ProcessRuntimeError))

;: Single-pass destructured captured-output result for imported callers.
(defstruct ProcessRuntimeOutputInfo
  (ok bool)
  (kind i64)
  (status i64)
  (stdout String)
  (stderr String)
  (message String))

;: Single-pass destructured child result for imported callers.
(defstruct ProcessRuntimeChildInfo
  (ok bool)
  (kind i64)
  (pid i64)
  (stdout-handle i64)
  (stderr-handle i64)
  (message String))

;: Return an empty runtime argv list.
(define (args-empty) : ProcessRuntimeStringList
  ProcessRuntimeStringNil)

;: Prepend an owned argv string to a runtime argv list.
(define (args-cons [value : String] [rest : ProcessRuntimeStringList]) : ProcessRuntimeStringList
  (ProcessRuntimeStringCons value (box rest)))

;: Return an empty runtime environment override list.
(define (env-empty) : ProcessRuntimeEnvList
  ProcessRuntimeEnvNil)

;: Prepend an owned environment override to a runtime env list.
(define (env-cons
  [name : String]
  [value : String]
  [rest : ProcessRuntimeEnvList]) : ProcessRuntimeEnvList
  (ProcessRuntimeEnvCons name value (box rest)))

;: Return a missing runtime optional string.
(define (no-string) : ProcessRuntimeMaybeString
  (ProcessRuntimeMaybeString false ""))

;: Return a present runtime optional string.
(define (some-string [value : String]) : ProcessRuntimeMaybeString
  (ProcessRuntimeMaybeString true value))

;: Construct a private runtime command.
(define (command-full
  [executable : String]
  [argv : ProcessRuntimeStringList]
  [cwd : ProcessRuntimeMaybeString]
  [env : ProcessRuntimeEnvList]
  [stdin : ProcessRuntimeMaybeString]) : ProcessRuntimeCommand
  (ProcessRuntimeCommand executable argv cwd env stdin))

;: Construct a private runtime child handle.
(define (child [pid : i64] [stdout-handle : i64] [stderr-handle : i64]) : ProcessRuntimeChild
  (ProcessRuntimeChild pid stdout-handle stderr-handle))

;: Return a destructured argv step.
(define (string-step [args : ProcessRuntimeStringList]) : ProcessRuntimeStringStep
  (match args
    [(ProcessRuntimeStringNil)
      (ProcessRuntimeStringStep false "" ProcessRuntimeStringNil)]
    [(ProcessRuntimeStringCons value rest)
      (ProcessRuntimeStringStep true value (box-get rest))]))

;: Return whether a destructured argv step contains an item.
(define (string-step-present? [step : ProcessRuntimeStringStep]) : bool
  (struct-get step present))

;: Return the argv value from a destructured step.
(define (string-step-value [step : ProcessRuntimeStringStep]) : String
  (struct-get step value))

;: Return the argv tail from a destructured step.
(define (string-step-rest [step : ProcessRuntimeStringStep]) : ProcessRuntimeStringList
  (struct-get step rest))

;: Return the number of runtime argv entries.
(define (args-count [args : ProcessRuntimeStringList]) : i64
  (match args
    [(ProcessRuntimeStringNil) 0]
    [(ProcessRuntimeStringCons _ rest)
      (+ 1 (stdlib.process_runtime.args-count (box-get rest)))]))

;: Return a destructured environment step.
(define (env-step [env : ProcessRuntimeEnvList]) : ProcessRuntimeEnvStep
  (match env
    [(ProcessRuntimeEnvNil)
      (ProcessRuntimeEnvStep false "" "" ProcessRuntimeEnvNil)]
    [(ProcessRuntimeEnvCons name value rest)
      (ProcessRuntimeEnvStep true name value (box-get rest))]))

;: Return whether a destructured env step contains an item.
(define (env-step-present? [step : ProcessRuntimeEnvStep]) : bool
  (struct-get step present))

;: Return the env name from a destructured step.
(define (env-step-name [step : ProcessRuntimeEnvStep]) : String
  (struct-get step name))

;: Return the env value from a destructured step.
(define (env-step-value [step : ProcessRuntimeEnvStep]) : String
  (struct-get step value))

;: Return the env tail from a destructured step.
(define (env-step-rest [step : ProcessRuntimeEnvStep]) : ProcessRuntimeEnvList
  (struct-get step rest))

;: Return a destructured optional string.
(define (maybe-string-info [value : ProcessRuntimeMaybeString]) : ProcessRuntimeMaybeStringInfo
  (ProcessRuntimeMaybeStringInfo
    (struct-get value present)
    (struct-get value value)))

;: Return whether a destructured optional string is present.
(define (maybe-string-info-present? [info : ProcessRuntimeMaybeStringInfo]) : bool
  (struct-get info present))

;: Return the string from a destructured optional string.
(define (maybe-string-info-value [info : ProcessRuntimeMaybeStringInfo]) : String
  (struct-get info value))

;: Return the executable path from a runtime command.
(define (command-executable [command : ProcessRuntimeCommand]) : String
  (struct-get command executable))

;: Return the argv list from a runtime command.
(define (command-argv [command : ProcessRuntimeCommand]) : ProcessRuntimeStringList
  (struct-get command argv))

;: Return the cwd setting from a runtime command.
(define (command-cwd [command : ProcessRuntimeCommand]) : ProcessRuntimeMaybeString
  (struct-get command cwd))

;: Return the environment override list from a runtime command.
(define (command-env [command : ProcessRuntimeCommand]) : ProcessRuntimeEnvList
  (struct-get command env))

;: Return the stdin setting from a runtime command.
(define (command-stdin [command : ProcessRuntimeCommand]) : ProcessRuntimeMaybeString
  (struct-get command stdin))

;: Construct a successful captured-output runtime result.
(define (output-ok [status : i64] [stdout : String] [stderr : String]) : ResultProcessRuntimeOutput
  (OkProcessRuntimeOutput (ProcessRuntimeOutput status stdout stderr)))

;: Construct a successful child runtime result.
(define (child-ok [pid : i64] [stdout-handle : i64] [stderr-handle : i64]) : ResultProcessRuntimeChild
  (OkProcessRuntimeChild (ProcessRuntimeChild pid stdout-handle stderr-handle)))

;: Construct a runtime output error result.
(define (output-error [error : ProcessRuntimeError]) : ResultProcessRuntimeOutput
  (ErrProcessRuntimeOutput error))

;: Construct a runtime child error result.
(define (child-error [error : ProcessRuntimeError]) : ResultProcessRuntimeChild
  (ErrProcessRuntimeChild error))

;: Construct a spawn-failure runtime output result.
(define (output-spawn-failed [message : String]) : ResultProcessRuntimeOutput
  (ErrProcessRuntimeOutput (ProcessRuntimeSpawnFailed message)))

;: Construct a wait-failure runtime output result.
(define (output-wait-failed [message : String]) : ResultProcessRuntimeOutput
  (ErrProcessRuntimeOutput (ProcessRuntimeWaitFailed message)))

;: Construct an unsupported runtime output result.
(define (output-unsupported [message : String]) : ResultProcessRuntimeOutput
  (ErrProcessRuntimeOutput (ProcessRuntimeUnsupported message)))

;: Construct a spawn-failure runtime child result.
(define (child-spawn-failed [message : String]) : ResultProcessRuntimeChild
  (ErrProcessRuntimeChild (ProcessRuntimeSpawnFailed message)))

;: Construct a wait-failure runtime child result.
(define (child-wait-failed [message : String]) : ResultProcessRuntimeChild
  (ErrProcessRuntimeChild (ProcessRuntimeWaitFailed message)))

;: Construct an unsupported runtime child result.
(define (child-unsupported [message : String]) : ResultProcessRuntimeChild
  (ErrProcessRuntimeChild (ProcessRuntimeUnsupported message)))

;: Return true when a runtime output result is an `Ok`.
(define (result-output-ok? [result : ResultProcessRuntimeOutput]) : bool
  (match result
    [(OkProcessRuntimeOutput _) true]
    [(ErrProcessRuntimeOutput _) false]))

;: Return captured status, or `fallback` when `result` is an error.
(define (result-status-or
  [result : ResultProcessRuntimeOutput]
  [fallback : i64]) : i64
  (match result
    [(OkProcessRuntimeOutput output) (struct-get output status)]
    [(ErrProcessRuntimeOutput _) fallback]))

;: Return an error kind code, or `fallback` when `result` is ok.
(define (result-error-kind-or
  [result : ResultProcessRuntimeOutput]
  [fallback : i64]) : i64
  (match result
    [(OkProcessRuntimeOutput _) fallback]
    [(ErrProcessRuntimeOutput error)
      (match error
        [(ProcessRuntimeInvalidCommand _) 0]
        [(ProcessRuntimeSpawnFailed _) 1]
        [(ProcessRuntimeWaitFailed _) 2]
        [(ProcessRuntimeUnsupported _) 3])]))

;: Return an error message, or `fallback` when `result` is ok.
(define (result-error-message-or
  [result : ResultProcessRuntimeOutput]
  [fallback : String]) : String
  (match result
    [(OkProcessRuntimeOutput _) fallback]
    [(ErrProcessRuntimeOutput error)
      (match error
        [(ProcessRuntimeInvalidCommand message) message]
        [(ProcessRuntimeSpawnFailed message) message]
        [(ProcessRuntimeWaitFailed message) message]
        [(ProcessRuntimeUnsupported message) message])]))

;: Destructure a runtime captured-output result in one pass.
(define (result-output-info [result : ResultProcessRuntimeOutput]) : ProcessRuntimeOutputInfo
  (match result
    [(OkProcessRuntimeOutput output)
      (ProcessRuntimeOutputInfo
        true
        0
        (struct-get output status)
        (struct-get output stdout)
        (struct-get output stderr)
        "")]
    [(ErrProcessRuntimeOutput error)
      (match error
        [(ProcessRuntimeInvalidCommand message)
          (ProcessRuntimeOutputInfo false 0 (- 0 1) "" "" message)]
        [(ProcessRuntimeSpawnFailed message)
          (ProcessRuntimeOutputInfo false 1 (- 0 1) "" "" message)]
        [(ProcessRuntimeWaitFailed message)
          (ProcessRuntimeOutputInfo false 2 (- 0 1) "" "" message)]
        [(ProcessRuntimeUnsupported message)
          (ProcessRuntimeOutputInfo false 3 (- 0 1) "" "" message)])]))

;: Return true when a runtime child result is an `Ok`.
(define (result-child-ok? [result : ResultProcessRuntimeChild]) : bool
  (match result
    [(OkProcessRuntimeChild _) true]
    [(ErrProcessRuntimeChild _) false]))

;: Return the child pid, or `fallback` when `result` is an error.
(define (child-result-pid-or
  [result : ResultProcessRuntimeChild]
  [fallback : i64]) : i64
  (match result
    [(OkProcessRuntimeChild child) (struct-get child pid)]
    [(ErrProcessRuntimeChild _) fallback]))

;: Return a child-result error kind code, or `fallback` when `result` is ok.
(define (child-result-error-kind-or
  [result : ResultProcessRuntimeChild]
  [fallback : i64]) : i64
  (match result
    [(OkProcessRuntimeChild _) fallback]
    [(ErrProcessRuntimeChild error)
      (match error
        [(ProcessRuntimeInvalidCommand _) 0]
        [(ProcessRuntimeSpawnFailed _) 1]
        [(ProcessRuntimeWaitFailed _) 2]
        [(ProcessRuntimeUnsupported _) 3])]))

;: Return a child-result error message, or `fallback` when `result` is ok.
(define (child-result-error-message-or
  [result : ResultProcessRuntimeChild]
  [fallback : String]) : String
  (match result
    [(OkProcessRuntimeChild _) fallback]
    [(ErrProcessRuntimeChild error)
      (match error
        [(ProcessRuntimeInvalidCommand message) message]
        [(ProcessRuntimeSpawnFailed message) message]
        [(ProcessRuntimeWaitFailed message) message]
        [(ProcessRuntimeUnsupported message) message])]))

;: Destructure a runtime child result in one pass.
(define (result-child-info [result : ResultProcessRuntimeChild]) : ProcessRuntimeChildInfo
  (match result
    [(OkProcessRuntimeChild child)
      (ProcessRuntimeChildInfo
        true
        0
        (struct-get child pid)
        (struct-get child stdout-handle)
        (struct-get child stderr-handle)
        "")]
    [(ErrProcessRuntimeChild error)
      (match error
        [(ProcessRuntimeInvalidCommand message)
          (ProcessRuntimeChildInfo false 0 (- 0 1) (- 0 1) (- 0 1) message)]
        [(ProcessRuntimeSpawnFailed message)
          (ProcessRuntimeChildInfo false 1 (- 0 1) (- 0 1) (- 0 1) message)]
        [(ProcessRuntimeWaitFailed message)
          (ProcessRuntimeChildInfo false 2 (- 0 1) (- 0 1) (- 0 1) message)]
        [(ProcessRuntimeUnsupported message)
          (ProcessRuntimeChildInfo false 3 (- 0 1) (- 0 1) (- 0 1) message)])]))

(import stdlib.io)
(import stdlib.string)

;: Linux inherited environment array (NUL-terminated `char**`). On the freestanding
;: Linux entry the kernel lays out `argc`, `argv[0..]`, a NULL, then `envp[0..]`
;: on the initial stack, so `envp` is `&argv[argc + 1]`. Computed from the
;: `program-argv`/`program-argc` builtins (no new backend symbol — keeps the
;: seed bootstrap working).
(define (linux-envp) : (Ptr (Ptr u8))
  (unsafe
    (env.linux-environ)))

;: Windows kernel32 bindings used by the captured-output path. Referenced only
;: from the Windows branch.
(cfg
  windows
  (extern (win-get-environment-strings) : (Ptr u8) (:symbol "GetEnvironmentStringsA")))
(cfg
  windows
  (extern (win-get-temp-path [arg0 : i32] [arg1 : (MutPtr u8)]) : i32 (:symbol "GetTempPathA")))
(cfg
  windows
  (extern (win-get-temp-file-name
    [arg0 : (Ptr u8)]
    [arg1 : (Ptr u8)]
    [arg2 : i32]
    [arg3 : (MutPtr u8)]) : i32 (:symbol "GetTempFileNameA")))
(cfg
  windows
  (extern (win-create-process
    [arg0 : i64]
    [arg1 : i64]
    [arg2 : i64]
    [arg3 : i64]
    [arg4 : i32]
    [arg5 : i64]
    [arg6 : i64]
    [arg7 : i64]
    [arg8 : i64]
    [arg9 : i64]) : i32 (:symbol "CreateProcessA")))
(cfg
  windows
  (extern (win-wait-single [arg0 : i64] [arg1 : i32]) : i32 (:symbol "WaitForSingleObject")))
(cfg
  windows
  (extern (win-get-exit-code [arg0 : i64] [arg1 : (MutPtr i32)]) : i32 (:symbol "GetExitCodeProcess")))
(cfg
  windows
  (extern (win-create-file
    [arg0 : (Ptr u8)]
    [arg1 : i64]
    [arg2 : i64]
    [arg3 : i64]
    [arg4 : i64]
    [arg5 : i64]
    [arg6 : i64]) : i64 (:symbol "CreateFileA")))
(cfg
  windows
  (extern (win-read-file
    [arg0 : i64]
    [arg1 : (MutPtr u8)]
    [arg2 : i32]
    [arg3 : (MutPtr i32)]
    [arg4 : i64]) : i32 (:symbol "ReadFile")))
(cfg
  windows
  (extern (win-set-file-pointer-ex
    [arg0 : i64]
    [arg1 : i64]
    [arg2 : (MutPtr i64)]
    [arg3 : i32]) : i32 (:symbol "SetFilePointerEx")))
(cfg
  windows
  (extern (win-close-handle [arg0 : i64]) : i32 (:symbol "CloseHandle")))
(cfg
  windows
  (extern (win-get-std-handle [arg0 : i32]) : i64 (:symbol "GetStdHandle")))
(cfg
  windows
  (extern (win-get-current-process) : i64 (:symbol "GetCurrentProcess")))
(cfg
  windows
  (extern (win-duplicate-handle
    [source-process : i64]
    [source-handle : i64]
    [target-process : i64]
    [target-handle : (MutPtr i64)]
    [desired-access : i64]
    [inherit-handle : i32]
    [options : i32]) : i32 (:symbol "DuplicateHandle")))

;: Shared spawn-failure result for the captured-output path.
(define (spawn-error) : ResultProcessRuntimeOutput
  (stdlib.process_runtime.output-spawn-failed "process: spawn failed"))

;: Shared wait-failure result for the captured-output path.
(define (wait-error) : ResultProcessRuntimeOutput
  (stdlib.process_runtime.output-wait-failed "process: wait failed"))

;: Shared spawn-failure result for the asynchronous start path.
(define (spawn-error-child) : ResultProcessRuntimeChild
  (stdlib.process_runtime.child-spawn-failed "process: spawn failed"))

;: Shared wait-failure result for the asynchronous start path.
(define (wait-error-child) : ResultProcessRuntimeChild
  (stdlib.process_runtime.child-wait-failed "process: wait failed"))

;: Async-unsupported result for `start` on runtimes without child handles.
(define (async-unsupported-child) : ResultProcessRuntimeChild
  (stdlib.process_runtime.child-unsupported
    "process: async child handles are not supported by this runtime"))

;: Async-unsupported result for `wait` on runtimes without child handles.
(define (async-unsupported-output) : ResultProcessRuntimeOutput
  (stdlib.process_runtime.output-unsupported
    "process: async child handles are not supported by this runtime"))

;: Return the integer address of an `Array u8` backing buffer.
(define (array-u8-addr [buf : (Array u8)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data buf) : (Ptr u8))) : i64)))

;: Return the integer address of a byte-builder snapshot backing buffer.
(cfg
  windows
  (define (byte-builder-addr [buf : byte_buf_core.ByteBufBuilder]) : i64
    (let
      [bytes : (Array u8) (byte_buf_core.byte-buf-builder-finish-array (& buf))]
      (stdlib.process_runtime.array-u8-addr bytes))))

;: Return the integer address of an `Array u64` backing buffer.
(define (array-u64-addr [buf : (Array u64)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data buf) : (Ptr u8))) : i64)))

;: Return the integer address of an `Array i32` backing buffer.
(define (array-i32-addr [buf : (Array i32)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (array-data buf) : (Ptr u8))) : i64)))

;: Read the unsigned byte at `index` of a C string as an i64.
(define (byte-at [ptr : (Ptr u8)] [index : i64]) : i64
  (cast
    (unsafe
      (ptr-read (ptr-offset ptr index)))
    : i64))

;: Convert an integer address into a read-only byte pointer.
(define (addr->ptr [addr : i64]) : (Ptr u8)
  (unsafe
    (int->ptr (cast addr : u64) : (Ptr u8))))

;: Return true when inherited entry `entry` and override entry `override` (both
;: `NAME=VALUE` C strings) share the same NAME (compared up to the override `=`).
(define (cstr-name-matches? [entry : (Ptr u8)] [override : (Ptr u8)]) : bool
  (let
    [i : i64 0]
    [matched : bool false]
    [decided : bool false]
    (begin
      (while (not decided)
        (let
          [oc : i64 (stdlib.process_runtime.byte-at override i)]
          (if (= oc 61)
            (begin
              (set! matched (= (stdlib.process_runtime.byte-at entry i) 61))
              (set! decided true))
            (if (= (stdlib.process_runtime.byte-at entry i) oc)
              (set! i (+ i 1))
              (begin
                (set! matched false)
                (set! decided true))))))
      matched)))

;: Return true when inherited entry `entry` is overridden by any address in `ov`
;: (an array of override `NAME=VALUE` C string addresses).
(define (inherited-overridden? [entry : (Ptr u8)] [ov : (Array u64)]) : bool
  (let
    [n : i64 (array-length ov)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (if (stdlib.process_runtime.cstr-name-matches?
          entry
          (stdlib.process_runtime.addr->ptr (cast (array-ref ov i) : i64)))
          (set! found true)
          (set! i (+ i 1))))
      found)))

;: Build a NUL-terminated `NAME=VALUE` C string for an env override.
(define (env-cstring [name : String] [value : String]) : (Array u8)
  (let
    [nl : i64 (string-length name)]
    [vl : i64 (string-length value)]
    [buf : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity (+ (+ nl vl) 2))]
    [i : i64 0]
    (begin
      (while (< i nl)
        (begin
          (byte_buf_core.byte-buf-builder-push
            (&mut buf)
            (cast (string-ref name i) : u8))
          (set! i (+ i 1))))
      (byte_buf_core.byte-buf-builder-push (&mut buf) (cast 61 : u8))
      (set! i 0)
      (while (< i vl)
        (begin
          (byte_buf_core.byte-buf-builder-push
            (&mut buf)
            (cast (string-ref value i) : u8))
          (set! i (+ i 1))))
      (byte_buf_core.byte-buf-builder-push (&mut buf) (cast 0 : u8))
      (byte_buf_core.byte-buf-builder-finish-array (& buf)))))

;: Materialize the override list into an array of `NAME=VALUE` C string
;: addresses. The move-only `env` list is consumed exactly once here so the
;: resulting array can be scanned repeatedly without further moves.
(define (build-override-cstrings [env : ProcessRuntimeEnvList]) : (Array u64)
  (let
    [ov : (Array u64) (array.make-array u64 0)]
    [cur : ProcessRuntimeEnvList env]
    [continue : bool true]
    (begin
      (while continue
        (let
          [step : ProcessRuntimeEnvStep (stdlib.process_runtime.env-step cur)]
          (if (stdlib.process_runtime.env-step-present? step)
            (let
              [name : String (stdlib.process_runtime.env-step-name step)]
              [value : String (stdlib.process_runtime.env-step-value step)]
              [rest : ProcessRuntimeEnvList
                (stdlib.process_runtime.env-step-rest step)]
              (begin
                (array-push!
                  ov
                  (unsafe
                    (cast
                      (ptr->int
                        (io.array-const-ptr
                          (stdlib.process_runtime.env-cstring name value)))
                      : u64)))
                (set! cur rest)))
            (set! continue false))))
      ov)))

;: Return the integer address of an optional command path C string, or 0.
(define (maybe-cstring-addr [value : ProcessRuntimeMaybeString]) : i64
  (let
    [info : ProcessRuntimeMaybeStringInfo
      (stdlib.process_runtime.maybe-string-info value)]
    (if (stdlib.process_runtime.maybe-string-info-present? info)
      (stdlib.process_runtime.array-u8-addr
        (io.c-string (stdlib.process_runtime.maybe-string-info-value info)))
      0)))

;: Return true when an optional stdin value provides input.
(define (maybe-present? [value : ProcessRuntimeMaybeString]) : bool
  (stdlib.process_runtime.maybe-string-info-present?
    (stdlib.process_runtime.maybe-string-info value)))

;: Return the integer address of an optional stdin string's byte storage, or 0.
(define (maybe-data-addr [value : ProcessRuntimeMaybeString]) : i64
  (let
    [info : ProcessRuntimeMaybeStringInfo
      (stdlib.process_runtime.maybe-string-info value)]
    (if (stdlib.process_runtime.maybe-string-info-present? info)
      (let
        [text : String (stdlib.process_runtime.maybe-string-info-value info)]
        (unsafe
          (cast (ptr->int (string-data text)) : i64)))
      0)))

;: Return the byte length of an optional stdin string, or 0.
(define (maybe-len [value : ProcessRuntimeMaybeString]) : i64
  (let
    [info : ProcessRuntimeMaybeStringInfo
      (stdlib.process_runtime.maybe-string-info value)]
    (if (stdlib.process_runtime.maybe-string-info-present? info)
      (cfg
        feature-compiler-private-string-intrinsics
        (__tl_string_length
          (stdlib.process_runtime.maybe-string-info-value info))
        (string-length (stdlib.process_runtime.maybe-string-info-value info)))
      0)))

;; ---------------------------------------------------------------------------
;; Linux runtime (raw syscalls).
;; ---------------------------------------------------------------------------
;: Captured spawn state assembled before `fork` so the child does no allocation.
(defstruct ProcessLinuxSpawn
  (exec-addr i64)
  (argv-addr i64)
  (envp-addr i64)
  (cwd-addr i64)
  (marker-addr i64)
  (has-stdin bool)
  (stdin-data i64)
  (stdin-len i64)
  (stdin-r i64)
  (stdin-w i64)
  (stdout-fd i64)
  (stderr-fd i64)
  (exec-r i64)
  (exec-w i64)
  (failed bool))

;: Spawn state for a child that inherits the caller's stdout and stderr.
;: It omits capture descriptors while retaining the stdin and exec-failure
;: plumbing needed by the regular Linux process path.
(defstruct ProcessLinuxInheritedSpawn
  (exec-addr i64)
  (argv-addr i64)
  (envp-addr i64)
  (cwd-addr i64)
  (marker-addr i64)
  (has-stdin bool)
  (stdin-data i64)
  (stdin-len i64)
  (stdin-r i64)
  (stdin-w i64)
  (exec-r i64)
  (exec-w i64)
  (failed bool))

;: Close `fd` with the `close` syscall when it names an open descriptor.
(define (linux-close-if [fd : i64]) : unit
  (cfg
    windows
    unit
    (if (>= fd 0)
      (begin
        (unsafe
          (syscall 3 fd))
        unit)
      unit)))

;: Build a NUL-terminated `char**` argv (argv[0] = `exec-addr`) and return its
;: integer address.
(define (linux-build-argv [exec-addr : i64] [argv : ProcessRuntimeStringList]) : i64
  (let
    [argc : i64 (stdlib.process_runtime.args-count argv)]
    [arr : (Array u64) (array.make-array u64 (+ argc 2))]
    [w : i64 1]
    [cur : ProcessRuntimeStringList argv]
    [continue : bool true]
    (begin
      (array-set! arr 0 (cast exec-addr : u64))
      (while continue
        (let
          [step : ProcessRuntimeStringStep
            (stdlib.process_runtime.string-step cur)]
          (if (stdlib.process_runtime.string-step-present? step)
            (let
              [text : String (stdlib.process_runtime.string-step-value step)]
              [rest : ProcessRuntimeStringList
                (stdlib.process_runtime.string-step-rest step)]
              (begin
                (array-set!
                  arr
                  w
                  (unsafe
                    (cast
                      (ptr->int (io.array-const-ptr (io.c-string text)))
                      : u64)))
                (set! w (+ w 1))
                (set! cur rest)))
            (set! continue false))))
      (array-set! arr w (cast 0 : u64))
      (stdlib.process_runtime.array-u64-addr arr))))

;: Count inherited environment entries not overridden by `ov`.
(define (linux-count-inherited [environ : (Ptr (Ptr u8))] [ov : (Array u64)]) : i64
  (let
    [i : i64 0]
    [count : i64 0]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [entry : (Ptr u8)
            (unsafe
              (ptr-read (ptr-offset environ i)))]
          (if (ptr-null? entry)
            (set! done true)
            (begin
              (if (not (stdlib.process_runtime.inherited-overridden? entry ov))
                (set! count (+ count 1))
                unit)
              (set! i (+ i 1))))))
      count)))

;: Build the `char**` envp for `env` (inherited minus overrides, plus overrides)
;: and return its integer address; an empty override list reuses the inherited
;: environment array directly.
(define (linux-build-envp [env : ProcessRuntimeEnvList]) : i64
  (let
    [ov : (Array u64) (stdlib.process_runtime.build-override-cstrings env)]
    [ovc : i64 (array-length ov)]
    (if (= ovc 0)
      (unsafe
        (cast
          (ptr->int (ptr-cast (stdlib.process_runtime.linux-envp) : (Ptr u8)))
          : i64))
      (let
        [environ : (Ptr (Ptr u8))
          (unsafe
            (ptr-cast (stdlib.process_runtime.linux-envp) : (Ptr (Ptr u8))))]
        [inh : i64 (stdlib.process_runtime.linux-count-inherited environ ov)]
        [arr : (Array u64) (array.make-array u64 (+ (+ inh ovc) 1))]
        [w : i64 0]
        [i : i64 0]
        [k : i64 0]
        [done : bool false]
        (begin
          (while (not done)
            (let
              [entry : (Ptr u8)
                (unsafe
                  (ptr-read (ptr-offset environ i)))]
              (if (ptr-null? entry)
                (set! done true)
                (begin
                  (if (not
                    (stdlib.process_runtime.inherited-overridden? entry ov))
                    (begin
                      (array-set!
                        arr
                        w
                        (unsafe
                          (cast (ptr->int entry) : u64)))
                      (set! w (+ w 1)))
                    unit)
                  (set! i (+ i 1))))))
          (while (< k ovc)
            (begin
              (array-set! arr w (array-ref ov k))
              (set! w (+ w 1))
              (set! k (+ k 1))))
          (array-set! arr w (cast 0 : u64))
          (stdlib.process_runtime.array-u64-addr arr))))))

;: Decode a `wait4` status word into the process exit status: a terminating
;: signal becomes `128 + signal`, otherwise the low byte of the exit code.
(define (decode-status [status : i32]) : i64
  (let
    [value : i64 (cast status : i64)]
    [signal : i64 (bit-and value 0x7f)]
    (if (not (= signal 0))
      (+ 128 signal)
      (bit-and (shr value 8) 0xff))))

;: Write `len` bytes at `data-addr` to `fd`, returning 0 on success, the raw
;: negative `-errno` on a write error, or -1 on a zero-length write.
(define (linux-write-all [fd : i64] [data-addr : i64] [len : i64]) : i64
  (cfg
    windows
    -1
    (let
      [off : i64 0]
      [result : i64 0]
      [done : bool false]
      (begin
        (while (and (not done) (< off len))
          (let
            [written : i64
              (unsafe
                (syscall 1 fd (+ data-addr off) (- len off)))]
            (if (< written 0)
              (begin
                (set! result written)
                (set! done true))
              (if (= written 0)
                (begin
                  (set! result -1)
                  (set! done true))
                (set! off (+ off written))))))
        result))))

;: Feed `data-addr`/`len` to the child stdin pipe while ignoring SIGPIPE, then
;: restore the old SIGPIPE disposition. Returns 0 when input was delivered (or a
;: broken pipe was tolerated) and 1 on an unexpected write failure.
(define (linux-feed-stdin
  [has-stdin : bool]
  [stdin-r : i64]
  [stdin-w : i64]
  [data-addr : i64]
  [len : i64]) : i64
  (cfg
    windows
    1
    (if (not has-stdin)
      0
      (begin
        (stdlib.process_runtime.linux-close-if stdin-r)
        (let
          [act : (Array u64) (array.make-array u64 4)]
          [old : (Array u64) (array.make-array u64 4)]
          (begin
            (array-set! act 0 (cast 1 : u64))
            (unsafe
              (syscall
                13
                13
                (stdlib.process_runtime.array-u64-addr act)
                (stdlib.process_runtime.array-u64-addr old)
                8))
            (let
              [written : i64
                (stdlib.process_runtime.linux-write-all stdin-w data-addr len)]
              (begin
                (stdlib.process_runtime.linux-close-if stdin-w)
                (unsafe
                  (syscall
                    13
                    13
                    (stdlib.process_runtime.array-u64-addr old)
                    0
                    8))
                (if (>= written 0)
                  0
                  (if (= written -32)
                    0
                    1))))))))))

;: Assemble argv/envp/cwd/marker C strings and open the capture descriptors
;: (memfd stdout/stderr, an optional stdin pipe, and the exec-failure pipe)
;: before spawning. `failed` records a pre-spawn OS error.
(define (linux-prepare [command : ProcessRuntimeCommand]) : ProcessLinuxSpawn
  (cfg
    windows
    (ProcessLinuxSpawn 0 0 0 0 0 false 0 0 -1 -1 -1 -1 -1 -1 true)
    (let
      [exec-addr : i64
        (stdlib.process_runtime.array-u8-addr
          (io.c-string (stdlib.process_runtime.command-executable command)))]
      [argv-addr : i64
        (stdlib.process_runtime.linux-build-argv
          exec-addr
          (stdlib.process_runtime.command-argv command))]
      [envp-addr : i64
        (stdlib.process_runtime.linux-build-envp
          (stdlib.process_runtime.command-env command))]
      [cwd-addr : i64
        (stdlib.process_runtime.maybe-cstring-addr
          (stdlib.process_runtime.command-cwd command))]
      [marker-addr : i64
        (stdlib.process_runtime.array-u8-addr (io.c-string "exec"))]
      [has-stdin : bool
        (stdlib.process_runtime.maybe-present?
          (stdlib.process_runtime.command-stdin command))]
      [stdin-data : i64
        (stdlib.process_runtime.maybe-data-addr
          (stdlib.process_runtime.command-stdin command))]
      [stdin-len : i64
        (stdlib.process_runtime.maybe-len
          (stdlib.process_runtime.command-stdin command))]
      [stdin-r : i64 -1]
      [stdin-w : i64 -1]
      [stdout-fd : i64 -1]
      [stderr-fd : i64 -1]
      [exec-r : i64 -1]
      [exec-w : i64 -1]
      [failed : bool false]
      [pbuf : (Array i32) (array.make-array i32 2)]
      [ebuf : (Array i32) (array.make-array i32 2)]
      (begin
        (if has-stdin
          (if (<
            (unsafe
              (syscall 293 (stdlib.process_runtime.array-i32-addr pbuf) 524288))
            0)
            (set! failed true)
            (begin
              (set! stdin-r (cast (array-ref pbuf 0) : i64))
              (set! stdin-w (cast (array-ref pbuf 1) : i64))))
          unit)
        (if (not failed)
          (let
            [fd : i64
              (unsafe
                (syscall
                  319
                  (stdlib.process_runtime.array-u8-addr
                    (io.c-string "typelisp-process-stdout"))
                  0))]
            (if (< fd 0)
              (set! failed true)
              (set! stdout-fd fd)))
          unit)
        (if (not failed)
          (let
            [fd : i64
              (unsafe
                (syscall
                  319
                  (stdlib.process_runtime.array-u8-addr
                    (io.c-string "typelisp-process-stderr"))
                  0))]
            (if (< fd 0)
              (set! failed true)
              (set! stderr-fd fd)))
          unit)
        (if (not failed)
          (if (<
            (unsafe
              (syscall 293 (stdlib.process_runtime.array-i32-addr ebuf) 524288))
            0)
            (set! failed true)
            (begin
              (set! exec-r (cast (array-ref ebuf 0) : i64))
              (set! exec-w (cast (array-ref ebuf 1) : i64))))
          unit)
        (ProcessLinuxSpawn
          exec-addr
          argv-addr
          envp-addr
          cwd-addr
          marker-addr
          has-stdin
          stdin-data
          stdin-len
          stdin-r
          stdin-w
          stdout-fd
          stderr-fd
          exec-r
          exec-w
          failed)))))

;: Assemble the Linux inherited-stream spawn state. This has the same command,
;: cwd, environment, stdin, and exec-failure setup as `linux-prepare`, but
;: deliberately creates no stdout/stderr capture descriptors.
(define (linux-prepare-inherit [command : ProcessRuntimeCommand]) : ProcessLinuxInheritedSpawn
  (cfg
    windows
    (ProcessLinuxInheritedSpawn 0 0 0 0 0 false 0 0 -1 -1 -1 -1 true)
    (let
      [exec-addr : i64
        (stdlib.process_runtime.array-u8-addr
          (io.c-string (stdlib.process_runtime.command-executable command)))]
      [argv-addr : i64
        (stdlib.process_runtime.linux-build-argv
          exec-addr
          (stdlib.process_runtime.command-argv command))]
      [envp-addr : i64
        (stdlib.process_runtime.linux-build-envp
          (stdlib.process_runtime.command-env command))]
      [cwd-addr : i64
        (stdlib.process_runtime.maybe-cstring-addr
          (stdlib.process_runtime.command-cwd command))]
      [marker-addr : i64
        (stdlib.process_runtime.array-u8-addr (io.c-string "exec"))]
      [has-stdin : bool
        (stdlib.process_runtime.maybe-present?
          (stdlib.process_runtime.command-stdin command))]
      [stdin-data : i64
        (stdlib.process_runtime.maybe-data-addr
          (stdlib.process_runtime.command-stdin command))]
      [stdin-len : i64
        (stdlib.process_runtime.maybe-len
          (stdlib.process_runtime.command-stdin command))]
      [stdin-r : i64 -1]
      [stdin-w : i64 -1]
      [exec-r : i64 -1]
      [exec-w : i64 -1]
      [failed : bool false]
      [pbuf : (Array i32) (array.make-array i32 2)]
      [ebuf : (Array i32) (array.make-array i32 2)]
      (begin
        (if has-stdin
          (if (<
            (unsafe
              (syscall 293 (stdlib.process_runtime.array-i32-addr pbuf) 524288))
            0)
            (set! failed true)
            (begin
              (set! stdin-r (cast (array-ref pbuf 0) : i64))
              (set! stdin-w (cast (array-ref pbuf 1) : i64))))
          unit)
        (if (not failed)
          (if (<
            (unsafe
              (syscall 293 (stdlib.process_runtime.array-i32-addr ebuf) 524288))
            0)
            (set! failed true)
            (begin
              (set! exec-r (cast (array-ref ebuf 0) : i64))
              (set! exec-w (cast (array-ref ebuf 1) : i64))))
          unit)
        (ProcessLinuxInheritedSpawn
          exec-addr
          argv-addr
          envp-addr
          cwd-addr
          marker-addr
          has-stdin
          stdin-data
          stdin-len
          stdin-r
          stdin-w
          exec-r
          exec-w
          failed)))))

;: Close every descriptor recorded in a spawn struct (pre-fork cleanup).
(define (linux-cleanup-spawn [spawn : ProcessLinuxSpawn]) : unit
  (begin
    (stdlib.process_runtime.linux-close-if (struct-get spawn stdin-r))
    (stdlib.process_runtime.linux-close-if (struct-get spawn stdin-w))
    (stdlib.process_runtime.linux-close-if (struct-get spawn stdout-fd))
    (stdlib.process_runtime.linux-close-if (struct-get spawn stderr-fd))
    (stdlib.process_runtime.linux-close-if (struct-get spawn exec-r))
    (stdlib.process_runtime.linux-close-if (struct-get spawn exec-w))
    unit))

;: Close every descriptor in an inherited-stream spawn state before a failed
;: Linux spawn returns to its caller.
(define (linux-cleanup-inherited-spawn [spawn : ProcessLinuxInheritedSpawn]) : unit
  (begin
    (stdlib.process_runtime.linux-close-if (struct-get spawn stdin-r))
    (stdlib.process_runtime.linux-close-if (struct-get spawn stdin-w))
    (stdlib.process_runtime.linux-close-if (struct-get spawn exec-r))
    (stdlib.process_runtime.linux-close-if (struct-get spawn exec-w))
    unit))

;: Child failure path: write the `exec` marker through the failure pipe so the
;: parent learns `execve` did not take over, then exit(127). Never returns.
(define (linux-child-fail [exec-w : i64] [marker-addr : i64]) : never
  (cfg
    windows
    (stdlib.process_runtime.linux-child-fail exec-w marker-addr)
    (begin
      (unsafe
        (syscall 1 exec-w marker-addr 4))
      (unsafe
        (syscall 60 127))
      (stdlib.process_runtime.linux-child-fail exec-w marker-addr))))

;: Child path after vfork (syscalls only, no allocation or parent-memory writes):
;: wire stdin/stdout/stderr, chdir, then `execve`. Never returns.
(define (linux-exec-child [spawn : ProcessLinuxSpawn]) : never
  (cfg
    windows
    (stdlib.process_runtime.linux-exec-child spawn)
    (begin
      (unsafe
        (syscall 3 (struct-get spawn exec-r)))
      (if (>= (struct-get spawn stdin-w) 0)
        (begin
          (unsafe
            (syscall 3 (struct-get spawn stdin-w)))
          (if (<
            (unsafe
              (syscall 33 (struct-get spawn stdin-r) 0))
            0)
            (stdlib.process_runtime.linux-child-fail
              (struct-get spawn exec-w)
              (struct-get spawn marker-addr))
            (begin
              (unsafe
                (syscall 3 (struct-get spawn stdin-r)))
              unit)))
        unit)
      (unsafe
        (syscall 33 (struct-get spawn stdout-fd) 1))
      (unsafe
        (syscall 33 (struct-get spawn stderr-fd) 2))
      (unsafe
        (syscall 3 (struct-get spawn stdout-fd)))
      (unsafe
        (syscall 3 (struct-get spawn stderr-fd)))
      (if (not (= (struct-get spawn cwd-addr) 0))
        (if (<
          (unsafe
            (syscall 80 (struct-get spawn cwd-addr)))
          0)
          (stdlib.process_runtime.linux-child-fail
            (struct-get spawn exec-w)
            (struct-get spawn marker-addr))
          unit)
        unit)
      (unsafe
        (syscall
          59
          (struct-get spawn exec-addr)
          (struct-get spawn argv-addr)
          (struct-get spawn envp-addr)))
      (stdlib.process_runtime.linux-child-fail
        (struct-get spawn exec-w)
        (struct-get spawn marker-addr)))))

;: Child path after vfork for inherited stdout/stderr: wire only an explicitly
;: supplied stdin pipe, leave descriptors 1 and 2 untouched, then execve.
(define (linux-exec-child-inherit [spawn : ProcessLinuxInheritedSpawn]) : never
  (cfg
    windows
    (stdlib.process_runtime.linux-exec-child-inherit spawn)
    (begin
      (unsafe
        (syscall 3 (struct-get spawn exec-r)))
      (if (>= (struct-get spawn stdin-w) 0)
        (begin
          (unsafe
            (syscall 3 (struct-get spawn stdin-w)))
          (if (<
            (unsafe
              (syscall 33 (struct-get spawn stdin-r) 0))
            0)
            (stdlib.process_runtime.linux-child-fail
              (struct-get spawn exec-w)
              (struct-get spawn marker-addr))
            (begin
              (unsafe
                (syscall 3 (struct-get spawn stdin-r)))
              unit)))
        unit)
      (if (not (= (struct-get spawn cwd-addr) 0))
        (if (<
          (unsafe
            (syscall 80 (struct-get spawn cwd-addr)))
          0)
          (stdlib.process_runtime.linux-child-fail
            (struct-get spawn exec-w)
            (struct-get spawn marker-addr))
          unit)
        unit)
      (unsafe
        (syscall
          59
          (struct-get spawn exec-addr)
          (struct-get spawn argv-addr)
          (struct-get spawn envp-addr)))
      (stdlib.process_runtime.linux-child-fail
        (struct-get spawn exec-w)
        (struct-get spawn marker-addr)))))

;: Return true when the child wrote the `execve`-failure marker.
(define (linux-exec-failed? [exec-r : i64]) : bool
  (cfg
    windows
    true
    (let
      [buf : (Array u8) (array.make-array u8 8)]
      [count : i64
        (unsafe
          (syscall 0 exec-r (stdlib.process_runtime.array-u8-addr buf) 8))]
      (begin
        (stdlib.process_runtime.linux-close-if exec-r)
        (> count 0)))))

;: Parent path for the captured-output runtime: feed stdin, wait for the child,
;: detect `execve` failure, then read the memfd-captured stdout/stderr.
(define (linux-output-parent [spawn : ProcessLinuxSpawn] [pid : i64]) : ResultProcessRuntimeOutput
  (cfg
    windows
    (stdlib.process_runtime.wait-error)
    (begin
      (stdlib.process_runtime.linux-close-if (struct-get spawn exec-w))
      (let
        [stdin-status : i64
          (stdlib.process_runtime.linux-feed-stdin
            (struct-get spawn has-stdin)
            (struct-get spawn stdin-r)
            (struct-get spawn stdin-w)
            (struct-get spawn stdin-data)
            (struct-get spawn stdin-len))]
        (if (= stdin-status 1)
          (begin
            (stdlib.process_runtime.linux-close-if (struct-get spawn stdout-fd))
            (stdlib.process_runtime.linux-close-if (struct-get spawn stderr-fd))
            (stdlib.process_runtime.linux-close-if (struct-get spawn exec-r))
            (stdlib.process_runtime.wait-error))
          (let
            [statusbuf : (Array i32) (array.make-array i32 1)]
            [waited : i64
              (unsafe
                (syscall
                  61
                  pid
                  (stdlib.process_runtime.array-i32-addr statusbuf)
                  0
                  0))]
            (if (< waited 0)
              (begin
                (stdlib.process_runtime.linux-close-if
                  (struct-get spawn stdout-fd))
                (stdlib.process_runtime.linux-close-if
                  (struct-get spawn stderr-fd))
                (stdlib.process_runtime.linux-close-if
                  (struct-get spawn exec-r))
                (stdlib.process_runtime.wait-error))
              (if (stdlib.process_runtime.linux-exec-failed?
                (struct-get spawn exec-r))
                (begin
                  (stdlib.process_runtime.linux-close-if
                    (struct-get spawn stdout-fd))
                  (stdlib.process_runtime.linux-close-if
                    (struct-get spawn stderr-fd))
                  (stdlib.process_runtime.spawn-error))
                (let
                  [stdout-text : String
                    (io.read-fd-to-string (struct-get spawn stdout-fd))]
                  [stderr-text : String
                    (io.read-fd-to-string (struct-get spawn stderr-fd))]
                  [status : i64
                    (stdlib.process_runtime.decode-status
                      (array-ref statusbuf 0))]
                  (begin
                    (stdlib.process_runtime.linux-close-if
                      (struct-get spawn stdout-fd))
                    (stdlib.process_runtime.linux-close-if
                      (struct-get spawn stderr-fd))
                    (stdlib.process_runtime.output-ok
                      status
                      stdout-text
                      stderr-text)))))))))))

;: Parent path for the asynchronous start runtime: feed stdin, detect immediate
;: `execve` failure, otherwise return a child owning the capture descriptors.
(define (linux-start-parent [spawn : ProcessLinuxSpawn] [pid : i64]) : ResultProcessRuntimeChild
  (cfg
    windows
    (stdlib.process_runtime.wait-error-child)
    (begin
      (stdlib.process_runtime.linux-close-if (struct-get spawn exec-w))
      (let
        [stdin-status : i64
          (stdlib.process_runtime.linux-feed-stdin
            (struct-get spawn has-stdin)
            (struct-get spawn stdin-r)
            (struct-get spawn stdin-w)
            (struct-get spawn stdin-data)
            (struct-get spawn stdin-len))]
        (if (= stdin-status 1)
          (begin
            (unsafe
              (syscall
                61
                pid
                (stdlib.process_runtime.array-i32-addr (array.make-array i32 1))
                0
                0))
            (stdlib.process_runtime.linux-close-if (struct-get spawn stdout-fd))
            (stdlib.process_runtime.linux-close-if (struct-get spawn stderr-fd))
            (stdlib.process_runtime.linux-close-if (struct-get spawn exec-r))
            (stdlib.process_runtime.wait-error-child))
          (if (stdlib.process_runtime.linux-exec-failed?
            (struct-get spawn exec-r))
            (begin
              (unsafe
                (syscall
                  61
                  pid
                  (stdlib.process_runtime.array-i32-addr
                    (array.make-array i32 1))
                  0
                  0))
              (stdlib.process_runtime.linux-close-if
                (struct-get spawn stdout-fd))
              (stdlib.process_runtime.linux-close-if
                (struct-get spawn stderr-fd))
              (stdlib.process_runtime.spawn-error-child))
            (stdlib.process_runtime.child-ok
              pid
              (struct-get spawn stdout-fd)
              (struct-get spawn stderr-fd))))))))

;: Linux captured-output runtime: prepare, vfork, and dispatch parent/child.
(define (linux-output [command : ProcessRuntimeCommand]) : ResultProcessRuntimeOutput
  (cfg
    windows
    (stdlib.process_runtime.spawn-error)
    (let
      [spawn : ProcessLinuxSpawn (stdlib.process_runtime.linux-prepare command)]
      (if (struct-get spawn failed)
        (begin
          (stdlib.process_runtime.linux-cleanup-spawn spawn)
          (stdlib.process_runtime.spawn-error))
        (let
          ;; Use vfork so high-RSS selfhost builds can still exec tiny tools
          ;; on memory-constrained runners without copying page tables.
          [pid : i64
            (unsafe
              (syscall 58))]
          (if (< pid 0)
            (begin
              (stdlib.process_runtime.linux-cleanup-spawn spawn)
              (stdlib.process_runtime.spawn-error))
            (if (= pid 0)
              (stdlib.process_runtime.linux-exec-child spawn)
              (stdlib.process_runtime.linux-output-parent spawn pid))))))))

;: Parent path for an inherited-stream child: feed explicit stdin, wait for the
;: child, detect an exec failure, and return only its exit status. Stdout and
;: stderr stay connected to the caller throughout execution.
(define (linux-inherit-parent [spawn : ProcessLinuxInheritedSpawn] [pid : i64]) : ResultProcessRuntimeOutput
  (cfg
    windows
    (stdlib.process_runtime.wait-error)
    (begin
      (stdlib.process_runtime.linux-close-if (struct-get spawn exec-w))
      (let
        [stdin-status : i64
          (stdlib.process_runtime.linux-feed-stdin
            (struct-get spawn has-stdin)
            (struct-get spawn stdin-r)
            (struct-get spawn stdin-w)
            (struct-get spawn stdin-data)
            (struct-get spawn stdin-len))]
        (if (= stdin-status 1)
          (begin
            (unsafe
              (syscall
                61
                pid
                (stdlib.process_runtime.array-i32-addr (array.make-array i32 1))
                0
                0))
            (stdlib.process_runtime.linux-close-if (struct-get spawn exec-r))
            (stdlib.process_runtime.wait-error))
          (let
            [statusbuf : (Array i32) (array.make-array i32 1)]
            [waited : i64
              (unsafe
                (syscall
                  61
                  pid
                  (stdlib.process_runtime.array-i32-addr statusbuf)
                  0
                  0))]
            (if (< waited 0)
              (begin
                (stdlib.process_runtime.linux-close-if
                  (struct-get spawn exec-r))
                (stdlib.process_runtime.wait-error))
              (if (stdlib.process_runtime.linux-exec-failed?
                (struct-get spawn exec-r))
                (stdlib.process_runtime.spawn-error)
                (stdlib.process_runtime.output-ok
                  (stdlib.process_runtime.decode-status (array-ref statusbuf 0))
                  ""
                  "")))))))))

;: Linux inherited-stream runtime: prepare without output capture, vfork, and
;: keep child stdout/stderr attached to the caller until it exits.
(define (linux-inherit [command : ProcessRuntimeCommand]) : ResultProcessRuntimeOutput
  (cfg
    windows
    (stdlib.process_runtime.spawn-error)
    (let
      [spawn : ProcessLinuxInheritedSpawn
        (stdlib.process_runtime.linux-prepare-inherit command)]
      (if (struct-get spawn failed)
        (begin
          (stdlib.process_runtime.linux-cleanup-inherited-spawn spawn)
          (stdlib.process_runtime.spawn-error))
        (let
          [pid : i64
            (unsafe
              (syscall 58))]
          (if (< pid 0)
            (begin
              (stdlib.process_runtime.linux-cleanup-inherited-spawn spawn)
              (stdlib.process_runtime.spawn-error))
            (if (= pid 0)
              (stdlib.process_runtime.linux-exec-child-inherit spawn)
              (stdlib.process_runtime.linux-inherit-parent spawn pid))))))))

;: Linux asynchronous start runtime: prepare, vfork, and dispatch parent/child.
(define (linux-start [command : ProcessRuntimeCommand]) : ResultProcessRuntimeChild
  (cfg
    windows
    (stdlib.process_runtime.spawn-error-child)
    (let
      [spawn : ProcessLinuxSpawn (stdlib.process_runtime.linux-prepare command)]
      (if (struct-get spawn failed)
        (begin
          (stdlib.process_runtime.linux-cleanup-spawn spawn)
          (stdlib.process_runtime.spawn-error-child))
        (let
          ;; Use vfork so high-RSS selfhost builds can still exec tiny tools
          ;; on memory-constrained runners without copying page tables.
          [pid : i64
            (unsafe
              (syscall 58))]
          (if (< pid 0)
            (begin
              (stdlib.process_runtime.linux-cleanup-spawn spawn)
              (stdlib.process_runtime.spawn-error-child))
            (if (= pid 0)
              (stdlib.process_runtime.linux-exec-child spawn)
              (stdlib.process_runtime.linux-start-parent spawn pid))))))))

;: Linux asynchronous wait runtime: reap the child, read the memfd-captured
;: stdout/stderr, release the capture descriptors, and decode the exit status.
(define (linux-wait [child : ProcessRuntimeChild]) : ResultProcessRuntimeOutput
  (cfg
    windows
    (stdlib.process_runtime.wait-error)
    (let
      [pid : i64 (struct-get child pid)]
      [stdout-fd : i64 (struct-get child stdout-handle)]
      [stderr-fd : i64 (struct-get child stderr-handle)]
      [statusbuf : (Array i32) (array.make-array i32 1)]
      [waited : i64
        (unsafe
          (syscall 61 pid (stdlib.process_runtime.array-i32-addr statusbuf) 0 0))]
      (if (< waited 0)
        (begin
          (stdlib.process_runtime.linux-close-if stdout-fd)
          (stdlib.process_runtime.linux-close-if stderr-fd)
          (stdlib.process_runtime.wait-error))
        (let
          [stdout-text : String (io.read-fd-to-string stdout-fd)]
          (begin
            (stdlib.process_runtime.linux-close-if stdout-fd)
            (let
              [stderr-text : String (io.read-fd-to-string stderr-fd)]
              (begin
                (stdlib.process_runtime.linux-close-if stderr-fd)
                (stdlib.process_runtime.output-ok
                  (stdlib.process_runtime.decode-status (array-ref statusbuf 0))
                  stdout-text
                  stderr-text)))))))))

;; ---------------------------------------------------------------------------
;; Windows runtime (kernel32 CreateProcessA with temp-file redirection).
;; ---------------------------------------------------------------------------
;: Return true when `text` contains an ASCII space (argv-quoting trigger).
(define (string-has-space? [text : String]) : bool
  (let
    [n : i64 (string-length text)]
    [i : i64 0]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (if (= (cast (string-ref text i) : i64) 32)
          (set! found true)
          (set! i (+ i 1))))
      found)))

;: Quote a command-line argument with double quotes when it contains a space.
(define (quote-arg [text : String]) : String
  (if (stdlib.process_runtime.string-has-space? text)
    (string.append (string.append "\"" text) "\"")
    text))

;: Join the executable and argv into a single space-separated command line,
;: quoting space-containing entries (the CreateProcessA `lpCommandLine`).
(define (windows-cmdline [command : ProcessRuntimeCommand]) : String
  (let
    [line : String
      (stdlib.process_runtime.quote-arg
        (stdlib.process_runtime.command-executable command))]
    [cur : ProcessRuntimeStringList
      (stdlib.process_runtime.command-argv command)]
    [continue : bool true]
    (begin
      (while continue
        (let
          [step : ProcessRuntimeStringStep
            (stdlib.process_runtime.string-step cur)]
          (if (stdlib.process_runtime.string-step-present? step)
            (let
              [text : String (stdlib.process_runtime.string-step-value step)]
              [rest : ProcessRuntimeStringList
                (stdlib.process_runtime.string-step-rest step)]
              (begin
                (set!
                  line
                  (string.append
                    (string.append line " ")
                    (stdlib.process_runtime.quote-arg text)))
                (set! cur rest)))
            (set! continue false))))
      line)))

;: Append the NUL-terminated C string at `addr` (including its NUL) onto a block.
;: Private Windows environment block builder; `CreateProcessA` consumes only the
;: final raw byte block, and no growable byte array escapes this module.
(cfg
  windows
  (define (windows-push-cstr
    [block : (&mut block byte_buf_core.ByteBufBuilder)]
    [addr : i64]) : unit
    (let
      [ptr : (Ptr u8) (stdlib.process_runtime.addr->ptr addr)]
      [i : i64 0]
      [done : bool false]
      (begin
        (while (not done)
          (let
            [byte : i64 (stdlib.process_runtime.byte-at ptr i)]
            (begin
              (byte_buf_core.byte-buf-builder-push block (cast byte : u8))
              (if (= byte 0)
                (set! done true)
                (set! i (+ i 1))))))
        unit))))

;: Build the double-NUL-terminated CreateProcessA environment block from the
;: inherited environment minus overrides plus the override entries; an empty
;: override list returns 0 so the child inherits the environment.
(cfg
  windows
  (define (windows-build-env [env : ProcessRuntimeEnvList]) : i64
    (let
      [ov : (Array u64) (stdlib.process_runtime.build-override-cstrings env)]
      [ovc : i64 (array-length ov)]
      (if (= ovc 0)
        0
        (let
          [block : byte_buf_core.ByteBufBuilder
            (byte_buf_core.ByteBufBuilder (array.make-array u8 0) 0)]
          [base : (Ptr u8) (stdlib.process_runtime.win-get-environment-strings)]
          [i : i64 0]
          [k : i64 0]
          [done : bool false]
          (begin
            (while (not done)
              (if (= (stdlib.process_runtime.byte-at base i) 0)
                (set! done true)
                (let
                  [entry : (Ptr u8)
                    (unsafe
                      (ptr-offset base i))]
                  [j : i64 i]
                  (begin
                    (while (not (= (stdlib.process_runtime.byte-at base j) 0))
                      (set! j (+ j 1)))
                    (if (not
                      (stdlib.process_runtime.inherited-overridden? entry ov))
                      (stdlib.process_runtime.windows-push-cstr
                        (&mut block)
                        (unsafe
                          (cast (ptr->int entry) : i64)))
                      unit)
                    (set! i (+ j 1))))))
            (while (< k ovc)
              (begin
                (stdlib.process_runtime.windows-push-cstr
                  (&mut block)
                  (cast (array-ref ov k) : i64))
                (set! k (+ k 1))))
            (byte_buf_core.byte-buf-builder-push (&mut block) (cast 0 : u8))
            (stdlib.process_runtime.byte-builder-addr block)))))))

;: Close a Windows handle when it is not INVALID_HANDLE_VALUE.
(cfg
  windows
  (define (windows-close-if [handle : i64]) : unit
    (if (= handle -1)
      unit
      (begin
        (stdlib.process_runtime.win-close-handle handle)
        unit))))

;: Duplicate one caller standard handle as an inheritable child handle, or -1
;: when no usable standard handle is available. Keeping the duplication local
;: avoids changing inheritable flags on the caller's own console or pipe.
(cfg
  windows
  (define (windows-duplicate-standard-handle [which : i32]) : i64
    (let
      [source : i64 (stdlib.process_runtime.win-get-std-handle which)]
      [current : i64 (stdlib.process_runtime.win-get-current-process)]
      [copy : (Array i64) (array.make-array i64 1)]
      (if (or (= source 0) (= source -1))
        -1
        (if (=
          (stdlib.process_runtime.win-duplicate-handle
            current
            source
            current
            (unsafe
              (ptr-cast (array-data copy) : (MutPtr i64)))
            0
            (cast 1 : i32)
            (cast 2 : i32))
          (cast 0 : i32))
          -1
          (array-ref copy 0))))))

;: Create an inheritable, delete-on-close temp file and return its HANDLE, or -1.
(cfg
  windows
  (define (windows-make-temp-file) : i64
    (let
      [pathbuf : (Array u8) (array.make-array u8 320)]
      [namebuf : (Array u8) (array.make-array u8 320)]
      [prefix : (Array u8) (io.c-string "tlp")]
      [path-len : i32
        (stdlib.process_runtime.win-get-temp-path
          (cast 320 : i32)
          (unsafe
            (array-data pathbuf)))]
      (if (= (cast path-len : i64) 0)
        -1
        (let
          [name-result : i32
            (stdlib.process_runtime.win-get-temp-file-name
              (io.array-const-ptr pathbuf)
              (io.array-const-ptr prefix)
              (cast 0 : i32)
              (unsafe
                (array-data namebuf)))]
          (if (= (cast name-result : i64) 0)
            -1
            (let
              [security : (Array u64) (array.make-array u64 3)]
              (begin
                (array-set! security 0 (cast 24 : u64))
                (array-set! security 1 (cast 0 : u64))
                (array-set! security 2 (cast 1 : u64))
                (let
                  [handle : i64
                    (stdlib.process_runtime.win-create-file
                      (io.array-const-ptr namebuf)
                      0xc0000000
                      0x3
                      (stdlib.process_runtime.array-u64-addr security)
                      2
                      0x4000100
                      0)]
                  (if (= handle -1)
                    -1
                    handle))))))))))

;: Launch the process with stdout/stderr bound to the temp handles, wait for it
;: to exit, and return the exit code (or -1 when CreateProcessA fails).
(cfg
  windows
  (define (windows-create-and-wait
    [appname-addr : i64]
    [cmdline-addr : i64]
    [env-addr : i64]
    [cwd-addr : i64]
    [out-handle : i64]
    [err-handle : i64]) : i64
    (let
      [startup : (Array u64) (array.make-array u64 13)]
      [procinfo : (Array u64) (array.make-array u64 3)]
      (begin
        (array-set! startup 0 (cast 104 : u64))
        (array-set! startup 7 (shl (cast 0x100 : u64) 32))
        (array-set!
          startup
          10
          (cast
            (stdlib.process_runtime.win-get-std-handle (cast -10 : i32))
            : u64))
        (array-set! startup 11 (cast out-handle : u64))
        (array-set! startup 12 (cast err-handle : u64))
        (let
          [created : i32
            (stdlib.process_runtime.win-create-process
              appname-addr
              cmdline-addr
              0
              0
              (cast 1 : i32)
              0
              env-addr
              cwd-addr
              (stdlib.process_runtime.array-u64-addr startup)
              (stdlib.process_runtime.array-u64-addr procinfo))]
          (if (= created (cast 0 : i32))
            -1
            (let
              [codebuf : (Array i32) (array.make-array i32 1)]
              [process-handle : i64 (cast (array-ref procinfo 0) : i64)]
              [worker-handle : i64 (cast (array-ref procinfo 1) : i64)]
              (begin
                (stdlib.process_runtime.win-wait-single
                  process-handle
                  (cast -1 : i32))
                (stdlib.process_runtime.win-get-exit-code
                  process-handle
                  (unsafe
                    (ptr-cast (array-data codebuf) : (MutPtr i32))))
                (stdlib.process_runtime.win-close-handle process-handle)
                (stdlib.process_runtime.win-close-handle worker-handle)
                (cast (array-ref codebuf 0) : i64)))))))))

;: Launch a process with duplicated caller standard handles, wait for its exit,
;: and return the exit code. The child writes directly to the caller's stdout
;: and stderr instead of temporary capture files.
(cfg
  windows
  (define (windows-create-and-wait-inherit
    [appname-addr : i64]
    [cmdline-addr : i64]
    [env-addr : i64]
    [cwd-addr : i64]) : i64
    (let
      [startup : (Array u64) (array.make-array u64 13)]
      [procinfo : (Array u64) (array.make-array u64 3)]
      [stdin-handle : i64
        (stdlib.process_runtime.windows-duplicate-standard-handle
          (cast -10 : i32))]
      [stdout-handle : i64
        (stdlib.process_runtime.windows-duplicate-standard-handle
          (cast -11 : i32))]
      [stderr-handle : i64
        (stdlib.process_runtime.windows-duplicate-standard-handle
          (cast -12 : i32))]
      (if (or
        (= stdin-handle -1)
        (or (= stdout-handle -1) (= stderr-handle -1)))
        (begin
          (stdlib.process_runtime.windows-close-if stdin-handle)
          (stdlib.process_runtime.windows-close-if stdout-handle)
          (stdlib.process_runtime.windows-close-if stderr-handle)
          -1)
        (begin
          (array-set! startup 0 (cast 104 : u64))
          (array-set! startup 7 (shl (cast 0x100 : u64) 32))
          (array-set! startup 10 (cast stdin-handle : u64))
          (array-set! startup 11 (cast stdout-handle : u64))
          (array-set! startup 12 (cast stderr-handle : u64))
          (let
            [created : i32
              (stdlib.process_runtime.win-create-process
                appname-addr
                cmdline-addr
                0
                0
                (cast 1 : i32)
                0
                env-addr
                cwd-addr
                (stdlib.process_runtime.array-u64-addr startup)
                (stdlib.process_runtime.array-u64-addr procinfo))]
            (begin
              (stdlib.process_runtime.windows-close-if stdin-handle)
              (stdlib.process_runtime.windows-close-if stdout-handle)
              (stdlib.process_runtime.windows-close-if stderr-handle)
              (if (= created (cast 0 : i32))
                -1
                (let
                  [codebuf : (Array i32) (array.make-array i32 1)]
                  [process-handle : i64 (cast (array-ref procinfo 0) : i64)]
                  [worker-handle : i64 (cast (array-ref procinfo 1) : i64)]
                  (begin
                    (stdlib.process_runtime.win-wait-single
                      process-handle
                      (cast -1 : i32))
                    (stdlib.process_runtime.win-get-exit-code
                      process-handle
                      (unsafe
                        (ptr-cast (array-data codebuf) : (MutPtr i32))))
                    (stdlib.process_runtime.win-close-handle process-handle)
                    (stdlib.process_runtime.win-close-handle worker-handle)
                    (cast (array-ref codebuf 0) : i64)))))))))))

;: Seek a raw Windows file HANDLE and return the resulting offset.
(cfg
  windows
  (define (windows-seek-handle [handle : i64] [offset : i64] [whence : i32]) : i64
    (let
      [pos : (Array i64) (array.make-array i64 1)]
      [ok : i32
        (stdlib.process_runtime.win-set-file-pointer-ex
          handle
          offset
          (unsafe
            (ptr-cast (array-data pos) : (MutPtr i64)))
          whence)]
      (if (= ok (cast 0 : i32))
        -1
        (array-ref pos 0)))))

;: Non-Windows stub for the module-qualified helper name.
(cfg
  (not windows)
  (define (windows-seek-handle [_handle : i64] [_offset : i64] [_whence : i32]) : i64
    -1))

;: Read an entire seekable raw Windows file HANDLE into a String.
(cfg
  windows
  (define (windows-read-handle-to-string [handle : i64]) : String
    (let
      [end : i64
        (stdlib.process_runtime.windows-seek-handle handle 0 (cast 2 : i32))]
      (if (<= end 0)
        ""
        (if (<
          (stdlib.process_runtime.windows-seek-handle handle 0 (cast 0 : i32))
          0)
          ""
          (let
            [buf : (Array u8) (array.make-array u8 end)]
            [offset : i64 0]
            [done : bool false]
            (begin
              (while (if (not done)
                (< offset end)
                false)
                (let
                  [remaining : i64 (- end offset)]
                  [chunk : i32
                    (if (> remaining 1048576)
                      (cast 1048576 : i32)
                      (cast remaining : i32))]
                  [readbuf : (Array i32) (array.make-array i32 1)]
                  [ok : i32
                    (stdlib.process_runtime.win-read-file
                      handle
                      (unsafe
                        (ptr-offset (stdlib.io.array-ptr buf) offset))
                      chunk
                      (unsafe
                        (ptr-cast (array-data readbuf) : (MutPtr i32)))
                      0)]
                  [read-count : i64 (cast (array-ref readbuf 0) : i64)]
                  (if (= ok (cast 0 : i32))
                    (set! done true)
                    (if (= read-count 0)
                      (set! done true)
                      (set! offset (+ offset read-count))))))
              (unsafe
                (string-from-bytes (stdlib.io.array-const-ptr buf) offset)))))))))

;: Non-Windows stub for the module-qualified helper name.
(cfg
  (not windows)
  (define (windows-read-handle-to-string [_handle : i64]) : String
    ""))

;: Windows captured-output runtime: redirect stdout/stderr to temp files, run
;: the process to completion, and read the captured output back.
(cfg
  windows
  (define (windows-output [command : ProcessRuntimeCommand]) : ResultProcessRuntimeOutput
    (let
      [appname-addr : i64
        (stdlib.process_runtime.array-u8-addr
          (io.c-string (stdlib.process_runtime.command-executable command)))]
      [cmdline-addr : i64
        (stdlib.process_runtime.array-u8-addr
          (io.c-string (stdlib.process_runtime.windows-cmdline command)))]
      [env-addr : i64 0]
      [cwd-addr : i64
        (stdlib.process_runtime.maybe-cstring-addr
          (stdlib.process_runtime.command-cwd command))]
      [out-handle : i64 -1]
      [err-handle : i64 -1]
      (begin
        (set!
          env-addr
          (stdlib.process_runtime.windows-build-env
            (stdlib.process_runtime.command-env command)))
        (set! out-handle (stdlib.process_runtime.windows-make-temp-file))
        (set! err-handle (stdlib.process_runtime.windows-make-temp-file))
        (if (or (= out-handle -1) (= err-handle -1))
          (begin
            (stdlib.process_runtime.windows-close-if out-handle)
            (stdlib.process_runtime.windows-close-if err-handle)
            (stdlib.process_runtime.wait-error))
          (let
            [status : i64 -1]
            (begin
              (set!
                status
                (stdlib.process_runtime.windows-create-and-wait
                  appname-addr
                  cmdline-addr
                  env-addr
                  cwd-addr
                  out-handle
                  err-handle))
              (if (< status 0)
                (begin
                  (stdlib.process_runtime.windows-close-if out-handle)
                  (stdlib.process_runtime.windows-close-if err-handle)
                  (stdlib.process_runtime.spawn-error))
                (let
                  [stdout-text : String
                    (stdlib.process_runtime.windows-read-handle-to-string
                      out-handle)]
                  [stderr-text : String
                    (stdlib.process_runtime.windows-read-handle-to-string
                      err-handle)]
                  (begin
                    (stdlib.process_runtime.windows-close-if out-handle)
                    (stdlib.process_runtime.windows-close-if err-handle)
                    (stdlib.process_runtime.output-ok
                      status
                      stdout-text
                      stderr-text)))))))))))

;: Windows inherited-stream runtime: launch with duplicated caller standard
;: handles so stdout/stderr remain live, then return the child exit status.
(cfg
  windows
  (define (windows-inherit [command : ProcessRuntimeCommand]) : ResultProcessRuntimeOutput
    (let
      [appname-addr : i64
        (stdlib.process_runtime.array-u8-addr
          (io.c-string (stdlib.process_runtime.command-executable command)))]
      [cmdline-addr : i64
        (stdlib.process_runtime.array-u8-addr
          (io.c-string (stdlib.process_runtime.windows-cmdline command)))]
      [env-addr : i64
        (stdlib.process_runtime.windows-build-env
          (stdlib.process_runtime.command-env command))]
      [cwd-addr : i64
        (stdlib.process_runtime.maybe-cstring-addr
          (stdlib.process_runtime.command-cwd command))]
      [status : i64 -1]
      (begin
        (set!
          status
          (stdlib.process_runtime.windows-create-and-wait-inherit
            appname-addr
            cmdline-addr
            env-addr
            cwd-addr))
        (if (< status 0)
          (stdlib.process_runtime.spawn-error)
          (stdlib.process_runtime.output-ok status "" ""))))))

;; ---------------------------------------------------------------------------
;; Cross-target runtime entry points consumed by tl.
;; ---------------------------------------------------------------------------
;: Run a command and capture stdout, stderr, and exit status.
(define (tl_process_output [command : ProcessRuntimeCommand]) : ResultProcessRuntimeOutput
  (cfg
    windows
    (stdlib.process_runtime.windows-output command)
    (stdlib.process_runtime.linux-output command)))

;: Run a command with child stdout/stderr inherited from the caller and return
;: its status with no captured output payload.
(define (tl_process_inherit [command : ProcessRuntimeCommand]) : ResultProcessRuntimeOutput
  (cfg
    windows
    (stdlib.process_runtime.windows-inherit command)
    (stdlib.process_runtime.linux-inherit command)))

;: Start a command without waiting; Windows reports async as unsupported.
(define (tl_process_start [command : ProcessRuntimeCommand]) : ResultProcessRuntimeChild
  (cfg
    windows
    (stdlib.process_runtime.async-unsupported-child)
    (stdlib.process_runtime.linux-start command)))

;: Wait for a started child; Windows reports async as unsupported.
(define (tl_process_wait [child : ProcessRuntimeChild]) : ResultProcessRuntimeOutput
  (cfg
    windows
    (stdlib.process_runtime.async-unsupported-output)
    (stdlib.process_runtime.linux-wait child)))