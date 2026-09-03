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
;# runtime boundary: inherited entries matching any override name are removed,
;# overrides are emitted in vector order, and duplicate override names are
;# preserved in vector order.
;#
;# Usage: `(import stdlib.process)`
;#
(import stdlib.string)
(import stdlib.vector)
(import stdlib.io)
(import (vector.vector String) as svec)

;; Process values are persistent arena-backed records. These shallow reads make
;; an explicit shared view when a builder or accessor retains owner storage.
;: Return a representation-level shared view of a process value place.
(defmacro (process-place-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

;: Return a representation-level shared view of a process array element.
(defmacro (process-array-shared-view [items : Expr] [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (__tl_array-data ,items) ,index))))

;: Immutable sequence of process argument strings in argv order. Every backing
;: array entry is live. Sequences are shared persistently, so helpers that
;: extend one copy into a right-sized array instead of mutating storage another
;: value still observes.
(defstruct ProcessStringList
  (slots (__tl_dyn-array String)))

;: Optional string value used for cwd and stdin configuration.
(defenum ProcessMaybeString
  (ProcessNoString)
  (ProcessSomeString String))

;: Immutable sequence of environment override name/value pairs.
;: `names` and `values` hold entries in override order. Their lengths must be
;: equal. Accessors use only the common in-bounds prefix and command validation
;: rejects a mismatch before conversion. Values are persistent: builders
;: allocate fresh backing arrays before extending a retained parent.
(defstruct ProcessEnvList
  (names (__tl_dyn-array String))
  (values (__tl_dyn-array String)))

;: Maximum argv or environment entry count accepted by process builders and
;: the command validation boundary.
(define process-storage-max-count : i64
  4096)

;: Maximum byte length of one C-string-bound process field. Stdin remains
;: length-delimited and is intentionally not subject to this cap.
(define process-storage-max-string-bytes : i64
  1048576)

;: Return the smaller of two nonnegative storage lengths.
(define (process-count-min [left : i64] [right : i64]) : i64
  (if (< left right)
    left
    right))

;: Reject builder growth before count arithmetic or allocation can overflow or
;: exceed the implementation cap.
(define (process-checked-count-add [left : i64] [right : i64]) : i64
  (if (or
    (< left 0)
    (< right 0)
    (> left process-storage-max-count)
    (> right (- process-storage-max-count left)))
    (io.panic "process: command storage limit exceeded")
    (+ left right)))

;: Vector-backed process environment overrides. `names` and `values` are
;: parallel generated string-vector buffers with the invariant that their live
;: lengths are equal. Converting this representation preserves vector order
;: and keeps duplicate names.
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

;: Internal lifetime-carrying wrapper around a borrowed process string.
(defstruct ProcessStringRef
  (:lifetimes value)
  (value (& value str)))

;: Internal lifetime-carrying wrapper around a borrowed argument list.
(defstruct ProcessStringListRef
  (:lifetimes value)
  (value (& value ProcessStringList)))

;: Internal lifetime-carrying wrapper around a borrowed environment list.
(defstruct ProcessEnvListRef
  (:lifetimes value)
  (value (& value ProcessEnvList)))

;: Internal lifetime-carrying wrapper around a borrowed optional string.
(defstruct ProcessMaybeStringRef
  (:lifetimes value)
  (value (& value ProcessMaybeString)))

;: Re-expose a borrowed process string through the public String surface.
(define (process-string-shared-view [value : (& value str)]) : String
  (__tl-compiler-owned-shared-view-dyn-ref-as value String))

;: Re-expose a borrowed argument list through the owning compatibility surface.
(define (process-string-list-shared-view [value : (& value ProcessStringList)]) : ProcessStringList
  (let
    [cell : (ProcessStringListRef value) (ProcessStringListRef value)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr ProcessStringList))))))

;: Re-expose a borrowed environment through the owning compatibility surface.
(define (process-env-list-shared-view [value : (& value ProcessEnvList)]) : ProcessEnvList
  (let
    [cell : (ProcessEnvListRef value) (ProcessEnvListRef value)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr ProcessEnvList))))))

;: Re-expose a borrowed optional string through the owning compatibility surface.
(define (process-maybe-string-shared-view
  [value : (& value ProcessMaybeString)]) : ProcessMaybeString
  (let
    [cell : (ProcessMaybeStringRef value) (ProcessMaybeStringRef value)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr ProcessMaybeString))))))

;: Return a destructured step from an argv list. The tail is copied into a
;: right-sized array so the stepped-over sequence keeps its own storage.
(define (string-step [args : ProcessStringList]) : ProcessStringStep
  (let
    [n : i64 (- (array-length args.slots) 1)]
    (if (< n 0)
      (ProcessStringStep false "" (args-empty))
      (let
        [slots : (__tl_dyn-array String) (__tl_make-array String n)]
        [i : i64 0]
        (begin
          (while (< i n)
            (begin
              (set!
                (array-ref slots i)
                (process-array-shared-view args.slots (+ i 1)))
              (set! i (+ i 1))))
          (ProcessStringStep
            true
            (process-array-shared-view args.slots 0)
            (ProcessStringList slots)))))))

;: Return whether a destructured argv step contains an item.
(define (string-step-present? [step : (& step ProcessStringStep)]) : bool
  step.present)

;: Return the argv value from a destructured step, or the empty string.
(define (string-step-value [step : (& step ProcessStringStep)]) : String
  (process-string-shared-view step.value))

;: Return the argv tail from a destructured step.
(define (string-step-rest [step : (& step ProcessStringStep)]) : ProcessStringList
  (process-string-list-shared-view step.rest))

;: Return the environment name at `index`, or the empty string out of range.
(define (env-name-ref [env : (& env ProcessEnvList)] [index : i64]) : String
  (if (and (>= index 0) (< index (env-count env)))
    (process-array-shared-view env.names index)
    ""))

;: Return the environment value at `index`, or the empty string out of range.
(define (env-value-ref [env : (& env ProcessEnvList)] [index : i64]) : String
  (if (and (>= index 0) (< index (env-count env)))
    (process-array-shared-view env.values index)
    ""))

;: Copy a live environment range into parallel destination buffers, preserving
;: entry order.
(define (env-copy-into
  [dst-names : (&mut dst-names (__tl_dyn-array String))]
  [dst-values : (&mut dst-values (__tl_dyn-array String))]
  [env : (& env ProcessEnvList)]
  [offset : i64]
  [start : i64]) : unit
  (let
    [n : i64 (env-count env)]
    [i : i64 start]
    (while (< i n)
      (begin
        (set! (array-ref dst-names (+ offset (- i start))) (env-name-ref env i))
        (set!
          (array-ref dst-values (+ offset (- i start)))
          (env-value-ref env i))
        (set! i (+ i 1))))))

;: Return a destructured step from an environment override list. The tail is
;: copied to right-sized parallel arrays so stepping does not retain a boxed
;: self-tail.
(define (env-step [env : ProcessEnvList]) : ProcessEnvStep
  (let
    [n : i64 (env-count env)]
    (if (< n 1)
      (ProcessEnvStep false "" "" (env-empty))
      (let
        [tail-n : i64 (- n 1)]
        [tail-names : (__tl_dyn-array String) (__tl_make-array String tail-n)]
        [tail-values : (__tl_dyn-array String) (__tl_make-array String tail-n)]
        [i : i64 1]
        (begin
          (while (< i n)
            (begin
              (set! (array-ref tail-names (- i 1)) (env-name-ref env i))
              (set! (array-ref tail-values (- i 1)) (env-value-ref env i))
              (set! i (+ i 1))))
          (ProcessEnvStep
            true
            (env-name-ref env 0)
            (env-value-ref env 0)
            (ProcessEnvList tail-names tail-values)))))))

;: Return whether a destructured env step contains an item.
(define (env-step-present? [step : (& step ProcessEnvStep)]) : bool
  step.present)

;: Return the env name from a destructured step, or the empty string.
(define (env-step-name [step : (& step ProcessEnvStep)]) : String
  (process-string-shared-view step.name))

;: Return the env value from a destructured step, or the empty string.
(define (env-step-value [step : (& step ProcessEnvStep)]) : String
  (process-string-shared-view step.value))

;: Return the env tail from a destructured step.
(define (env-step-rest [step : (& step ProcessEnvStep)]) : ProcessEnvList
  (process-env-list-shared-view step.rest))

;: Return a destructured optional string.
(define (maybe-string-info [value : ProcessMaybeString]) : ProcessMaybeStringInfo
  (match value
    [(ProcessNoString) (ProcessMaybeStringInfo false "")]
    [(ProcessSomeString text) (ProcessMaybeStringInfo true text)]))

;: Return whether a destructured optional string is present.
(define (maybe-string-info-present? [info : (& info ProcessMaybeStringInfo)]) : bool
  info.present)

;: Return the string from a destructured optional string, or the empty string.
(define (maybe-string-info-value [info : (& info ProcessMaybeStringInfo)]) : String
  (process-string-shared-view info.value))

;: Return an empty argument list.
(define (args-empty) : ProcessStringList
  (ProcessStringList (__tl_make-array String 0)))

;: Return the number of argv entries in `args`.
(define (args-count [args : (& args ProcessStringList)]) : i64
  (array-length args.slots))

;: Return the argv entry at `index`, or the empty string when out of range.
(define (args-ref [args : (& args ProcessStringList)] [index : i64]) : String
  (if (and (>= index 0) (< index (array-length args.slots)))
    (process-array-shared-view args.slots index)
    ""))

;: Copy every backing-array entry of `args` into `dst` starting at `offset`.
(define (args-copy-into
  [dst : (&mut dst (__tl_dyn-array String))]
  [args : (& args ProcessStringList)]
  [offset : i64]) : unit
  (let
    [n : i64 (array-length args.slots)]
    [i : i64 0]
    (while (< i n)
      (begin
        (set!
          (array-ref dst (+ offset i))
          (process-array-shared-view args.slots i))
        (set! i (+ i 1))))))

;: Prepend an owned argument string to an argv list.
(define (args-cons [value : String] [rest : ProcessStringList]) : ProcessStringList
  (let
    [n : i64 (array-length rest.slots)]
    [next : i64 (process-checked-count-add n 1)]
    [slots : (__tl_dyn-array String) (__tl_make-array String next)]
    (begin
      (set! (array-ref slots 0) value)
      (args-copy-into (&mut slots) rest 1)
      (ProcessStringList slots))))

;: Return a one-element argument list backed by an owned string.
(define (args-single [value : String]) : ProcessStringList
  (let
    [slots : (__tl_dyn-array String) (__tl_make-array String 1)]
    (begin
      (set! (array-ref slots 0) value)
      (ProcessStringList slots))))

;: Concatenate two argument lists while preserving argv order.
(define (args-append [left : ProcessStringList] [right : ProcessStringList]) : ProcessStringList
  (let
    [ln : i64 (array-length left.slots)]
    [rn : i64 (array-length right.slots)]
    [count : i64 (process-checked-count-add ln rn)]
    [slots : (__tl_dyn-array String) (__tl_make-array String count)]
    (begin
      (args-copy-into (&mut slots) left 0)
      (args-copy-into (&mut slots) right ln)
      (ProcessStringList slots))))

;: Convert a generated string-vector argv buffer to the sequence representation
;: consumed by `ProcessCommand`, preserving vector order.
(define (args-from-string-vec [args : (& args svec.Vec)]) : ProcessStringList
  (let
    [n : i64 (svec.len args)]
    (if (> n process-storage-max-count)
      (io.panic "process: command storage limit exceeded")
      (let
        [slots : (__tl_dyn-array String) (__tl_make-array String n)]
        [i : i64 0]
        (begin
          (while (< i n)
            (begin
              (set! (array-ref slots i) (svec.get args i ""))
              (set! i (+ i 1))))
          (ProcessStringList slots))))))

;: Return an empty environment override list.
(define (env-empty) : ProcessEnvList
  (ProcessEnvList (__tl_make-array String 0) (__tl_make-array String 0)))

;: Return the number of env overrides in `env`.
(define (env-count [env : (& env ProcessEnvList)]) : i64
  (process-count-min (array-length env.names) (array-length env.values)))

;: Return true when the parallel environment arrays have the same bounded
;: length.
(define (env-storage-valid? [env : (& env ProcessEnvList)]) : bool
  (and
    (= (array-length env.names) (array-length env.values))
    (<= (array-length env.names) process-storage-max-count)))

;: Prepend owned environment override strings to an env list. The retained
;: parent is never mutated.
(define (env-cons [name : String] [value : String] [rest : ProcessEnvList]) : ProcessEnvList
  (let
    [n : i64 (env-count rest)]
    [next : i64 (process-checked-count-add n 1)]
    [names : (__tl_dyn-array String) (__tl_make-array String next)]
    [values : (__tl_dyn-array String) (__tl_make-array String next)]
    (begin
      (set! (array-ref names 0) name)
      (set! (array-ref values 0) value)
      (env-copy-into (&mut names) (&mut values) rest 1 0)
      (ProcessEnvList names values))))

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
  (& env.names))

;: Return the value buffer from a vector-backed env override set.
(define (env-vec-values [env : (& env ProcessEnvVec)]) : (& env svec.Vec)
  (& env.values))

;: Create an empty vector-backed env override set with at least `capacity`
;: backing slots in each parallel buffer.
(define (env-vec-with-capacity [capacity : i64]) : ProcessEnvVec
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (if (> cap process-storage-max-count)
      (io.panic "process: command storage limit exceeded")
      (ProcessEnvVec (svec.with-capacity cap) (svec.with-capacity cap)))))

;: Create an empty vector-backed env override set.
(define (env-vec-new) : ProcessEnvVec
  (env-vec-with-capacity 4))

;: Return the number of vector-backed env overrides. Helper-created values keep
;: this equal to the live length of both buffers; manually constructed values
;: should be checked with `env-vec-validation-error`.
(define (env-vec-count [env : (& env ProcessEnvVec)]) : i64
  (svec.len (env-vec-names env)))

;: Return true when both vector live lengths are equal, nonnegative, within
;: their backing arrays, and within the public process-storage cap.
(define (env-vec-storage-valid? [env : (& env ProcessEnvVec)]) : bool
  (let
    [names-len : i64 (svec.len (env-vec-names env))]
    [values-len : i64 (svec.len (env-vec-values env))]
    (and
      (>= names-len 0)
      (>= values-len 0)
      (= names-len values-len)
      (<= names-len (array-length (svec.slots (env-vec-names env))))
      (<= values-len (array-length (svec.slots (env-vec-values env))))
      (<= names-len process-storage-max-count))))

;: Append one owned environment override at the end of the vector-backed set.
;: Duplicate names are preserved in append order.
(define (env-vec-append!
  [env : (&mut env ProcessEnvVec)]
  [name : String]
  [value : String]) : unit
  (if (env-vec-storage-valid? env)
    (let
      [_next : i64 (process-checked-count-add (svec.len (& env.names)) 1)]
      (begin
        (svec.push-ref! (&mut env.names) name)
        (svec.push-ref! (&mut env.values) value)))
    (io.panic "process: environment vector storage is malformed")))

;: Fill dense public env storage from a vector-backed override set.
(define (env-vec-to-list-fill
  [env : (& env ProcessEnvVec)]
  [names : (&mut names (__tl_dyn-array String))]
  [values : (&mut values (__tl_dyn-array String))]) : unit
  (let
    [n : i64 (env-vec-count env)]
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref names i) (svec.get (env-vec-names env) i ""))
        (set! (array-ref values i) (svec.get (env-vec-values env) i ""))
        (set! i (+ i 1))))))

;: Convert vector-backed env overrides to the dense representation consumed by
;: `ProcessCommand` and the process runtime.
(define (env-vec-to-list [env : (& env ProcessEnvVec)]) : ProcessEnvList
  (if (env-vec-storage-valid? env)
    (let
      [n : i64 (env-vec-count env)]
      [names : (__tl_dyn-array String) (__tl_make-array String n)]
      [values : (__tl_dyn-array String) (__tl_make-array String n)]
      (begin
        (env-vec-to-list-fill env (&mut names) (&mut values))
        (ProcessEnvList names values)))
    (io.panic "process: environment vector storage is malformed")))

;: Return the first vector-backed env validation error, or `ProcessNoString`.
(define (env-vec-validation-error-from
  [env : (& env ProcessEnvVec)]
  [index : i64]) : ProcessMaybeString
  (if (>= index (env-vec-count env))
    (ProcessNoString)
    (let
      [name : String (svec.get (env-vec-names env) index "")]
      [value : String (svec.get (env-vec-values env) index "")]
      (cond
        [(string.eq name "")
          (ProcessSomeString "process: environment variable name is empty")]
        [(string-contains-char? (& name) '=')
          (ProcessSomeString "process: environment variable name contains '='")]
        [(> (string-length (& name)) process-storage-max-string-bytes)
          (ProcessSomeString
            "process: environment variable name exceeds storage limit")]
        [(> (string-length (& value)) process-storage-max-string-bytes)
          (ProcessSomeString
            "process: environment variable value exceeds storage limit")]
        [(string-contains-char? (& name) '\0')
          (ProcessSomeString "process: environment variable name contains NUL")]
        [(string-contains-char? (& value) '\0')
          (ProcessSomeString "process: environment variable value contains NUL")]
        [else (env-vec-validation-error-from env (+ index 1))]))))

;: Return the first vector-backed env validation error, or `ProcessNoString`.
;: The inherited environment is filtered by names that appear in the override
;: set, then override entries are emitted in vector order. Duplicate override
;: names are preserved in vector order.
(define (env-vec-validation-error [env : (& env ProcessEnvVec)]) : ProcessMaybeString
  (if (not (= (svec.len (env-vec-names env)) (svec.len (env-vec-values env))))
    (ProcessSomeString "process: environment vector name/value counts differ")
    (if (env-vec-storage-valid? env)
      (env-vec-validation-error-from env 0)
      (ProcessSomeString "process: environment vector storage is malformed"))))

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
    (env-empty)
    (ProcessNoString)))

;: Construct a process command from an executable and a vector-backed argv
;: buffer. The command keeps the dense public ABI after one conversion.
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
;: argv entries through one dense conversion and one append.
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
    (env-cons name value (command-env command))
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
;: storage converted to dense public storage.
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
(define (command-executable [command : (& command ProcessCommand)]) : String
  (process-string-shared-view command.executable))

;: Return the argv list from `command`.
(define (command-argv [command : (& command ProcessCommand)]) : ProcessStringList
  (process-string-list-shared-view command.argv))

;: Return the cwd setting from `command`.
(define (command-cwd [command : (& command ProcessCommand)]) : ProcessMaybeString
  (process-maybe-string-shared-view command.cwd))

;: Return the env override list from `command`.
(define (command-env [command : (& command ProcessCommand)]) : ProcessEnvList
  (process-env-list-shared-view command.env))

;: Return the stdin setting from `command`.
(define (command-stdin [command : (& command ProcessCommand)]) : ProcessMaybeString
  (process-maybe-string-shared-view command.stdin))

;: Return the process exit status.
;:
;: On Linux this is the small wait(2) exit status. On Windows it is the
;: child's exit DWORD zero-extended into i64: every completed child reports a
;: non-negative status in 0..0xFFFFFFFF, including high-bit NTSTATUS
;: terminations such as 0xC0000005 (reported as 3221225477). Spawn and wait
;: failures are never encoded in this field; they are `ProcessError` values.
(define (output-status [output : (& output ProcessOutput)]) : i64
  output.status)

;: Return captured stdout from `output`.
(define (output-stdout [output : (& output ProcessOutput)]) : String
  (process-string-shared-view output.stdout))

;: Return captured stderr from `output`.
(define (output-stderr [output : (& output ProcessOutput)]) : String
  (process-string-shared-view output.stderr))

;: Return true when the process exit status is zero.
(define (success? [output : (& output ProcessOutput)]) : bool
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
      (ProcessChildInfo true child.pid child.stdout-handle child.stderr-handle)]
    [(ErrProcessChild _) (ProcessChildInfo false (- 0 1) (- 0 1) (- 0 1))]))

;: Return true when `info` describes a started child.
(define (child-info-ok? [info : (& info ProcessChildInfo)]) : bool
  info.ok)

;: Return the child pid from `info`, or -1 when it is not ok.
(define (child-info-pid [info : (& info ProcessChildInfo)]) : i64
  info.pid)

;: Return the child stdout handle from `info`, or -1 when it is not ok.
(define (child-info-stdout-handle [info : (& info ProcessChildInfo)]) : i64
  info.stdout-handle)

;: Return the child stderr handle from `info`, or -1 when it is not ok.
(define (child-info-stderr-handle [info : (& info ProcessChildInfo)]) : i64
  info.stderr-handle)

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
    [(OkProcessChild child) child.pid]
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

;: Return the first argv validation error, or `ProcessNoString`.
(define (args-validation-error-from
  [args : (& args ProcessStringList)]
  [index : i64]) : ProcessMaybeString
  (if (>= index (args-count args))
    (ProcessNoString)
    (let
      [value : String (args-ref args index)]
      (cond
        [(> (string-length (& value)) process-storage-max-string-bytes)
          (ProcessSomeString "process: argument exceeds storage limit")]
        [(string-contains-char? (& value) '\0')
          (ProcessSomeString "process: argument contains NUL")]
        [else (args-validation-error-from args (+ index 1))]))))

;: Return the first argv validation error, including the storage cap.
(define (args-validation-error [args : (& args ProcessStringList)]) : ProcessMaybeString
  (if (> (args-count args) process-storage-max-count)
    (ProcessSomeString "process: argument storage limit exceeded")
    (args-validation-error-from args 0)))

;: Return the first env entry validation error after storage shape is proven.
(define (env-validation-error-from [env : (& env ProcessEnvList)] [index : i64]) : ProcessMaybeString
  (if (>= index (env-count env))
    (ProcessNoString)
    (let
      [name : String (env-name-ref env index)]
      [value : String (env-value-ref env index)]
      (cond
        [(string.eq name "")
          (ProcessSomeString "process: environment variable name is empty")]
        [(string-contains-char? (& name) '=')
          (ProcessSomeString "process: environment variable name contains '='")]
        [(> (string-length (& name)) process-storage-max-string-bytes)
          (ProcessSomeString
            "process: environment variable name exceeds storage limit")]
        [(> (string-length (& value)) process-storage-max-string-bytes)
          (ProcessSomeString
            "process: environment variable value exceeds storage limit")]
        [(string-contains-char? (& name) '\0')
          (ProcessSomeString "process: environment variable name contains NUL")]
        [(string-contains-char? (& value) '\0')
          (ProcessSomeString "process: environment variable value contains NUL")]
        [else (env-validation-error-from env (+ index 1))]))))

;: Return the first environment override validation error, or `ProcessNoString`.
(define (env-validation-error [env : (& env ProcessEnvList)]) : ProcessMaybeString
  (if (env-storage-valid? env)
    (env-validation-error-from env 0)
    (ProcessSomeString "process: environment storage is malformed")))

;: Return the first command validation error, or `ProcessNoString`.
(define (command-validation-error [command : (& command ProcessCommand)]) : ProcessMaybeString
  (let
    [executable : String (command-executable command)]
    [argv : ProcessStringList (command-argv command)]
    [env : ProcessEnvList (command-env command)]
    (cond
      [(string.eq executable "")
        (ProcessSomeString "process: executable path is empty")]
      [(> (string-length (& executable)) process-storage-max-string-bytes)
        (ProcessSomeString "process: executable path exceeds storage limit")]
      [(string-contains-char? (& executable) '\0')
        (ProcessSomeString "process: executable path contains NUL")]
      [else
        (match (args-validation-error argv)
          [(ProcessSomeString message) (ProcessSomeString message)]
          [(ProcessNoString)
            (match (command-cwd command)
              [(ProcessSomeString cwd)
                (cond
                  [(string.eq cwd "")
                    (ProcessSomeString "process: cwd path is empty")]
                  [(> (string-length (& cwd)) process-storage-max-string-bytes)
                    (ProcessSomeString
                      "process: cwd path exceeds storage limit")]
                  [(string-contains-char? (& cwd) '\0')
                    (ProcessSomeString "process: cwd path contains NUL")]
                  [else (env-validation-error env)])]
              [(ProcessNoString) (env-validation-error env)])])])))

;: Return true when `command` passes stdlib validation.
(define (command-valid? [command : (& command ProcessCommand)]) : bool
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

;: Convert public argv storage to the runtime module's no-cycle representation,
;: walking backwards so the emitted list keeps argv order.
(define (runtime-args-from
  [args : (& args ProcessStringList)]
  [index : i64]
  [out : process_runtime.ProcessRuntimeStringList]) : process_runtime.ProcessRuntimeStringList
  (if (< index 0)
    out
    (runtime-args-from
      args
      (- index 1)
      (process_runtime.args-cons (args-ref args index) out))))

;: Convert public argv storage to the runtime module's no-cycle representation.
(define (runtime-args [args : (& args ProcessStringList)]) : process_runtime.ProcessRuntimeStringList
  (runtime-args-from args (- (args-count args) 1) (process_runtime.args-empty)))

;: Convert public env storage to the runtime module's no-cycle representation.
(define (runtime-env-from
  [env : (& env ProcessEnvList)]
  [index : i64]
  [out : process_runtime.ProcessRuntimeEnvList]) : process_runtime.ProcessRuntimeEnvList
  (if (< index 0)
    out
    (runtime-env-from
      env
      (- index 1)
      (process_runtime.env-cons
        (env-name-ref env index)
        (env-value-ref env index)
        out))))

;: Convert the public dense environment representation to the runtime module's no-cycle representation.
(define (runtime-env [env : (& env ProcessEnvList)]) : process_runtime.ProcessRuntimeEnvList
  (runtime-env-from env (- (env-count env) 1) (process_runtime.env-empty)))

;: Convert a public optional string to the runtime module's no-cycle representation.
(define (runtime-maybe-string [value : ProcessMaybeString]) : process_runtime.ProcessRuntimeMaybeString
  (let
    [info : ProcessMaybeStringInfo (maybe-string-info value)]
    (if (maybe-string-info-present? info)
      (process_runtime.some-string (maybe-string-info-value info))
      (process_runtime.no-string))))

;: Convert a public command to the runtime module's no-cycle representation.
(define (runtime-command [command : (& command ProcessCommand)]) : process_runtime.ProcessRuntimeCommand
  (let
    [argv : ProcessStringList (command-argv command)]
    [env : ProcessEnvList (command-env command)]
    (process_runtime.command-full
      (command-executable command)
      (runtime-args argv)
      (runtime-maybe-string (command-cwd command))
      (runtime-env env)
      (runtime-maybe-string (command-stdin command)))))

;: Convert a public child handle to the runtime module's no-cycle representation.
(define (runtime-child [child : ProcessChild]) : process_runtime.ProcessRuntimeChild
  (process_runtime.child child.pid child.stdout-handle child.stderr-handle))

;: Convert a runtime captured-output result to the public result enum.
(define (output-from-runtime
  [result : process_runtime.ResultProcessRuntimeOutput]) : ResultProcessOutput
  (let
    [info : process_runtime.ProcessRuntimeOutputInfo
      (process_runtime.result-output-info result)]
    (if info.ok
      (output-ok-public info.status info.stdout info.stderr)
      (output-error-public (error-from-runtime-kind info.kind info.message)))))

;: Convert a runtime async-start result to the public result enum.
(define (child-from-runtime
  [result : process_runtime.ResultProcessRuntimeChild]) : ResultProcessChild
  (let
    [info : process_runtime.ProcessRuntimeChildInfo
      (process_runtime.result-child-info result)]
    (if info.ok
      (child-ok-public info.pid info.stdout-handle info.stderr-handle)
      (child-error-public (error-from-runtime-kind info.kind info.message)))))

;: Run a command and capture stdout, stderr, and exit status.
(define (output [command : ProcessCommand]) : ResultProcessOutput
  (let
    [validation : ProcessMaybeString (command-validation-error command)]
    [info : ProcessMaybeStringInfo (maybe-string-info validation)]
    (if (maybe-string-info-present? info)
      (output-error-public
        (error-from-runtime-kind 0 (maybe-string-info-value info)))
      (output-from-runtime
        (unsafe
          (process_runtime.tl_process_output (runtime-command command)))))))

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
        (unsafe
          (process_runtime.tl_process_inherit (runtime-command command)))))))

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
        (unsafe
          (process_runtime.tl_process_start (runtime-command command)))))))

;: Wait for a child started by `start`, collect its captured output, and
;: release the child handle resources. Do not wait on the same child twice.
(define (wait [child : ProcessChild]) : ResultProcessOutput
  (output-from-runtime
    (unsafe
      (process_runtime.tl_process_wait (runtime-child child)))))

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
  (test-assert-i64-eq (args-count items) 0))

;: Inline test assertion for a one-item process string list.
(define (test-assert-string-list1 [items : ProcessStringList] [first : String]) : unit
  (begin
    (test-assert-i64-eq (args-count items) 1)
    (test-assert-string-eq (args-ref items 0) first)))

;: Inline test assertion for a two-item process string list.
(define (test-assert-string-list2
  [items : ProcessStringList]
  [first : String]
  [second : String]) : unit
  (begin
    (test-assert-i64-eq (args-count items) 2)
    (test-assert-string-eq (args-ref items 0) first)
    (test-assert-string-eq (args-ref items 1) second)))

;: Inline test assertion for a three-item process string list.
(define (test-assert-string-list3
  [items : ProcessStringList]
  [first : String]
  [second : String]
  [third : String]) : unit
  (begin
    (test-assert-i64-eq (args-count items) 3)
    (test-assert-string-eq (args-ref items 0) first)
    (test-assert-string-eq (args-ref items 1) second)
    (test-assert-string-eq (args-ref items 2) third)))

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
  (begin
    (test-assert (> (env-count env) 0))
    (test-assert-string-eq (env-name-ref env 0) expected-name)
    (test-assert-string-eq (env-value-ref env 0) expected-value)))

;: Inline test assertion for a two-entry process environment list.
(define (test-assert-env-list2
  [env : ProcessEnvList]
  [first-name : String]
  [first-value : String]
  [second-name : String]
  [second-value : String]) : unit
  (begin
    (test-assert-i64-eq (env-count env) 2)
    (test-assert-string-eq (env-name-ref env 0) first-name)
    (test-assert-string-eq (env-value-ref env 0) first-value)
    (test-assert-string-eq (env-name-ref env 1) second-name)
    (test-assert-string-eq (env-value-ref env 1) second-value)))

;: Inline test body for dense environment storage, stepping, duplicates, and
;: retained-parent persistence.
(define (test-env-dense-api) : unit
  (let
    [empty : ProcessEnvList (env-empty)]
    [parent : ProcessEnvList
      (env-cons "PARENT" "one" (process-place-shared-view empty))]
    [child : ProcessEnvList
      (env-cons "CHILD" "two" (process-place-shared-view parent))]
    [duplicate : ProcessEnvList
      (env-cons
        "DUP"
        "second"
        (env-cons "DUP" "first" (process-place-shared-view empty)))]
    [empty-step : ProcessEnvStep (env-step (process-place-shared-view empty))]
    [child-step : ProcessEnvStep (env-step (process-place-shared-view child))]
    [tail-step : ProcessEnvStep (env-step (env-step-rest child-step))]
    (begin
      (test-assert-i64-eq (env-count empty) 0)
      (test-assert (not (env-step-present? empty-step)))
      (test-assert-i64-eq (env-count parent) 1)
      (test-assert-env-head parent "PARENT" "one")
      (test-assert-i64-eq (env-count child) 2)
      (test-assert-env-list2 child "CHILD" "two" "PARENT" "one")
      (test-assert (env-step-present? child-step))
      (test-assert-string-eq (env-step-name child-step) "CHILD")
      (test-assert-string-eq (env-step-value child-step) "two")
      (test-assert (env-step-present? tail-step))
      (test-assert-string-eq (env-step-name tail-step) "PARENT")
      (test-assert-string-eq (env-step-value tail-step) "one")
      (test-assert-env-list2 duplicate "DUP" "second" "DUP" "first"))))

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
      (svec.push-ref! (&mut items) a)
      items)))

;: Inline test helper for generated string-vector argv buffers.
(define (test-string-vec2 [a : String] [b : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.with-capacity 2)]
    (begin
      (svec.push-ref! (&mut items) a)
      (svec.push-ref! (&mut items) b)
      items)))

;: Inline test helper for generated string-vector argv buffers.
(define (test-string-vec3 [a : String] [b : String] [c : String]) : svec.Vec
  (let
    [items : svec.Vec (svec.with-capacity 3)]
    (begin
      (svec.push-ref! (&mut items) a)
      (svec.push-ref! (&mut items) b)
      (svec.push-ref! (&mut items) c)
      items)))

;: Inline test helper for vector-backed environment overrides.
(define (test-env-vec1 [name : String] [value : String]) : ProcessEnvVec
  (let
    [env : ProcessEnvVec (env-vec-new)]
    (begin
      (env-vec-append! (&mut env) name value)
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
      (env-vec-append! (&mut env) name-a value-a)
      (env-vec-append! (&mut env) name-b value-b)
      env)))

;: Inline test helper for malformed vector-backed environment overrides.
(define (test-env-vec-bad-shape) : ProcessEnvVec
  (let
    [names : svec.Vec (svec.new)]
    [values : svec.Vec (svec.new)]
    (begin
      (svec.push-ref! (&mut names) "ONLY_NAME")
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
            (command-with-cwd
              (command "echo" (process-place-shared-view args))
              "target")
            "stdin")
          "TL_TEST"
          "1")
        "!")]
    (begin
      (test-env-dense-api)
      (test-assert-string-eq (command-executable cmd) "echo")
      (test-assert-string-list2
        (process-place-shared-view args)
        "hello"
        "world")
      (test-assert-string-list3 (command-argv cmd) "hello" "world" "!")
      (let
        [cmd-argv : ProcessStringList (command-argv cmd)]
        (test-assert-i64-eq (args-count cmd-argv) 3))
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
        [empty-command : ProcessCommand
          (command-from-argv-vec "echo" (& empty-argv))]
        [solo-command : ProcessCommand
          (command-from-argv-vec "echo" (& solo-argv))]
        [multi-command : ProcessCommand
          (command-from-argv-vec "echo" (& multi-argv))]
        [replace-command : ProcessCommand
          (command-with-argv-vec
            (process-place-shared-view cmd)
            (& replace-argv))]
        [tail-command : ProcessCommand
          (command-with-args-vec
            (command "echo" (args-single "base"))
            (& tail-argv))]
        (begin
          (test-assert-string-empty (args-from-string-vec (& empty-argv)))
          (test-assert-string-list1 (args-from-string-vec (& solo-argv)) "solo")
          (test-assert-string-list3
            (args-from-string-vec (& multi-argv))
            "hello"
            "world"
            "!")
          (test-assert-string-empty (command-argv empty-command))
          (test-assert-string-list1 (command-argv solo-command) "solo")
          (test-assert-string-list3
            (command-argv multi-command)
            "hello"
            "world"
            "!")
          (test-assert-string-list3
            (command-argv replace-command)
            "vec"
            "replace"
            "argv")
          (test-assert-string-list3
            (command-argv tail-command)
            "base"
            "vec"
            "tail")))
      (test-assert-some-string (command-cwd cmd) "target")
      (test-assert-some-string (command-stdin cmd) "stdin")
      (test-assert-env-head (command-env cmd) "TL_TEST" "1")
      (let
        [cmd-env : ProcessEnvList (command-env cmd)]
        (test-assert-i64-eq (env-count cmd-env) 1))
      (let
        [replaced-command : ProcessCommand
          (command-with-env-list
            (process-place-shared-view cmd)
            (env-cons "TL_REPLACED" "yes" (env-empty)))]
        (test-assert-env-head
          (command-env replaced-command)
          "TL_REPLACED"
          "yes"))
      (let
        [default-command : ProcessCommand (command "echo" (args-empty))]
        (test-assert-no-string (command-cwd default-command))))))

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
      (let
        [command-with-env : ProcessCommand
          (command-with-env-vec cmd (& env-vec))]
        (test-assert-env-list2
          (command-env command-with-env)
          "TL_FIRST"
          "one"
          "TL_SECOND"
          "two"))
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
    [invalid-executable : ProcessCommand (command "" (args-empty))]
    [invalid-cwd : ProcessCommand
      (command-with-cwd (process-place-shared-view cmd) "")]
    [invalid-env-name : ProcessCommand
      (command-with-env (process-place-shared-view cmd) "" "1")]
    [invalid-env-equals : ProcessCommand
      (command-with-env (process-place-shared-view cmd) "BAD=NAME" "1")]
    (begin
      (test-env-vec-api (process-place-shared-view cmd))
      (test-assert-validation
        (command-validation-error invalid-executable)
        "process: executable path is empty")
      (test-assert-validation
        (command-validation-error invalid-cwd)
        "process: cwd path is empty")
      (test-assert-validation
        (command-validation-error invalid-env-name)
        "process: environment variable name is empty")
      (test-assert-validation
        (command-validation-error invalid-env-equals)
        "process: environment variable name contains '='")
      (test-assert (command-valid? cmd))
      (test-assert (not (command-valid? invalid-executable)))
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