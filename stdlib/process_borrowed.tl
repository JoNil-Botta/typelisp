;# Borrowed process command storage companion surface (#1915).
;#
;# `ProcessBorrowedCommand` stores executable, argv, cwd, env, and stdin text as
;# `(& lifetime str)` values without copying at each builder step. Rendering to
;# the runtime-owned `ProcessCommand` copies at the explicit compatibility
;# boundary.
;#
;# This module remains separate from `process.tl` as the explicit borrowed
;# storage companion. Runtime wrappers validate borrowed commands and copy once
;# at the owned `ProcessCommand` boundary before calling `process.tl`.
(import "process.tl")

(import "string.tl")

;: Borrowed process argument strings in argv order. All entries in one list
;: share one lifetime; use owned conversion to join independently scoped text.
(defenum ProcessBorrowedStringList
  (:lifetimes text)
  (ProcessBorrowedStringNil)
  (ProcessBorrowedStringCons
    (& text str)
    (Box (ProcessBorrowedStringList text))))

;: Optional borrowed string value used for cwd and stdin configuration.
(defenum ProcessBorrowedMaybeString
  (:lifetimes text)
  (ProcessBorrowedNoString)
  (ProcessBorrowedSomeString (& text str)))

;: Borrowed environment override list stored as name/value pairs. All entries
;: in one list share one lifetime.
(defenum ProcessBorrowedEnvList
  (:lifetimes text)
  (ProcessBorrowedEnvNil)
  (ProcessBorrowedEnvCons
    (& text str)
    (& text str)
    (Box (ProcessBorrowedEnvList text))))

;: Borrowed process command data. The process runtime still receives owned
;: `ProcessCommand` values; borrowed commands copy at that explicit boundary.
(defstruct ProcessBorrowedCommand
  (:lifetimes executable argv cwd env stdin)
  (executable (& executable str))
  (argv (ProcessBorrowedStringList argv))
  (cwd (ProcessBorrowedMaybeString cwd))
  (env (ProcessBorrowedEnvList env))
  (stdin (ProcessBorrowedMaybeString stdin)))

;: Return an empty borrowed argument list tied to `text` without storing it.
(define (process-borrowed-args-empty-like [text : (& text str)]) : (ProcessBorrowedStringList
  text)
  (ProcessBorrowedStringNil))

;: Return the number of borrowed argv entries in `args`.
(define (process-borrowed-args-count [args : (ProcessBorrowedStringList text)]) : i64
  (match args
    [(ProcessBorrowedStringNil) 0]
    [(ProcessBorrowedStringCons _ rest)
      (+ 1 (process-borrowed-args-count (box-get rest)))]))

;: Prepend a borrowed argument string to an argv list without copying bytes.
(define (process-borrowed-args-cons
  [value : (& text str)]
  [rest : (ProcessBorrowedStringList text)]) : (ProcessBorrowedStringList text)
  (ProcessBorrowedStringCons value (box rest)))

;: Return a one-element borrowed argument list.
(define (process-borrowed-args-single [value : (& text str)]) : (ProcessBorrowedStringList
  text)
  (ProcessBorrowedStringCons value (box (ProcessBorrowedStringNil))))

;: Copy a borrowed string into active-arena owned storage.
(define (process-borrowed-string-owned [value : (& value str)]) : String
  (substring-borrowed value 0 (string-length value)))

;: Copy borrowed argv storage to the owned process argv representation.
(define (process-borrowed-args-owned [args : (ProcessBorrowedStringList text)]) : ProcessStringList
  (match args
    [(ProcessBorrowedStringNil) (ProcessStringNil)]
    [(ProcessBorrowedStringCons value rest)
      (ProcessStringCons
        (process-borrowed-string-owned value)
        (box (process-borrowed-args-owned (box-get rest))))]))

;: Return an empty borrowed environment override list tied to `text`.
(define (process-borrowed-env-empty-like [text : (& text str)]) : (ProcessBorrowedEnvList
  text)
  (ProcessBorrowedEnvNil))

;: Return the number of borrowed env overrides in `env`.
(define (process-borrowed-env-count [env : (ProcessBorrowedEnvList text)]) : i64
  (match env
    [(ProcessBorrowedEnvNil) 0]
    [(ProcessBorrowedEnvCons _ _ rest)
      (+ 1 (process-borrowed-env-count (box-get rest)))]))

;: Prepend borrowed environment override strings without copying bytes.
(define (process-borrowed-env-cons
  [name : (& text str)]
  [value : (& text str)]
  [rest : (ProcessBorrowedEnvList text)]) : (ProcessBorrowedEnvList text)
  (ProcessBorrowedEnvCons name value (box rest)))

;: Copy borrowed env storage to the owned process env representation.
(define (process-borrowed-env-owned [env : (ProcessBorrowedEnvList text)]) : ProcessEnvList
  (match env
    [(ProcessBorrowedEnvNil) (ProcessEnvNil)]
    [(ProcessBorrowedEnvCons name value rest)
      (ProcessEnvCons
        (process-borrowed-string-owned name)
        (process-borrowed-string-owned value)
        (box (process-borrowed-env-owned (box-get rest))))]))

;: Return a borrowed stdin/cwd value that stores no string but keeps the target
;: type lifetime anchored to `text`.
(define (process-borrowed-no-string-like [text : (& text str)]) : (ProcessBorrowedMaybeString
  text)
  (ProcessBorrowedNoString))

;: Return a borrowed stdin/cwd value without copying bytes.
(define (process-borrowed-some-string [value : (& text str)]) : (ProcessBorrowedMaybeString
  text)
  (ProcessBorrowedSomeString value))

;: Copy a borrowed optional string to the owned process representation.
(define (process-borrowed-maybe-owned
  [value : (ProcessBorrowedMaybeString text)]) : ProcessMaybeString
  (match value
    [(ProcessBorrowedNoString) (ProcessNoString)]
    [(ProcessBorrowedSomeString text)
      (ProcessSomeString (process-borrowed-string-owned text))]))

;: Construct a borrowed command with default cwd, env, and stdin settings.
(define (process-borrowed-command
  [executable : (& executable str)]
  [argv : (ProcessBorrowedStringList argv)]) : (ProcessBorrowedCommand
  executable
  argv
  executable
  executable
  executable)
  (ProcessBorrowedCommand
    executable
    argv
    (process-borrowed-no-string-like executable)
    (process-borrowed-env-empty-like executable)
    (process-borrowed-no-string-like executable)))

;: Construct a borrowed command with no argv entries.
(define (process-borrowed-command-empty [executable : (& executable str)]) : (ProcessBorrowedCommand
  executable
  executable
  executable
  executable
  executable)
  (process-borrowed-command
    executable
    (process-borrowed-args-empty-like executable)))

;: Return a borrowed command copy with the full argv list replaced.
(define (process-borrowed-command-with-argv
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [args : (ProcessBorrowedStringList next-argv)]) : (ProcessBorrowedCommand
  executable
  next-argv
  cwd
  env
  stdin)
  (ProcessBorrowedCommand
    (process-borrowed-command-executable command)
    args
    (process-borrowed-command-cwd command)
    (process-borrowed-command-env command)
    (process-borrowed-command-stdin command)))

;: Construct a borrowed process command with every field supplied explicitly.
(define (process-borrowed-command-full
  [executable : (& executable str)]
  [argv : (ProcessBorrowedStringList argv)]
  [cwd : (ProcessBorrowedMaybeString cwd)]
  [env : (ProcessBorrowedEnvList env)]
  [stdin : (ProcessBorrowedMaybeString stdin)]) : (ProcessBorrowedCommand
  executable
  argv
  cwd
  env
  stdin)
  (ProcessBorrowedCommand executable argv cwd env stdin))

;: Return a borrowed command copy with cwd set to `cwd`.
(define (process-borrowed-command-with-cwd
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [cwd : (& next-cwd str)]) : (ProcessBorrowedCommand
  executable
  argv
  next-cwd
  env
  stdin)
  (ProcessBorrowedCommand
    (process-borrowed-command-executable command)
    (process-borrowed-command-argv command)
    (ProcessBorrowedSomeString cwd)
    (process-borrowed-command-env command)
    (process-borrowed-command-stdin command)))

;: Return a borrowed command copy with an additional env override. The new
;: override must share the existing env-list lifetime.
(define (process-borrowed-command-with-env
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [name : (& env str)]
  [value : (& env str)]) : (ProcessBorrowedCommand
  executable
  argv
  cwd
  env
  stdin)
  (ProcessBorrowedCommand
    (process-borrowed-command-executable command)
    (process-borrowed-command-argv command)
    (process-borrowed-command-cwd command)
    (ProcessBorrowedEnvCons
      name
      value
      (box (process-borrowed-command-env command)))
    (process-borrowed-command-stdin command)))

;: Return a borrowed command copy with the full env override list replaced.
(define (process-borrowed-command-with-env-list
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [env : (ProcessBorrowedEnvList next-env)]) : (ProcessBorrowedCommand
  executable
  argv
  cwd
  next-env
  stdin)
  (ProcessBorrowedCommand
    (process-borrowed-command-executable command)
    (process-borrowed-command-argv command)
    (process-borrowed-command-cwd command)
    env
    (process-borrowed-command-stdin command)))

;: Return a borrowed command copy with stdin set to `stdin`.
(define (process-borrowed-command-with-stdin
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]
  [stdin-value : (& next-stdin str)]) : (ProcessBorrowedCommand
  executable
  argv
  cwd
  env
  next-stdin)
  (ProcessBorrowedCommand
    (process-borrowed-command-executable command)
    (process-borrowed-command-argv command)
    (process-borrowed-command-cwd command)
    (process-borrowed-command-env command)
    (ProcessBorrowedSomeString stdin-value)))

;: Return the borrowed executable path from `command`.
(define (process-borrowed-command-executable
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (&
  executable
  str)
  (struct-get command executable))

;: Return the borrowed argv list from `command`.
(define (process-borrowed-command-argv
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (ProcessBorrowedStringList
  argv)
  (struct-get command argv))

;: Return the borrowed cwd setting from `command`.
(define (process-borrowed-command-cwd
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (ProcessBorrowedMaybeString
  cwd)
  (struct-get command cwd))

;: Return the borrowed env override list from `command`.
(define (process-borrowed-command-env
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (ProcessBorrowedEnvList
  env)
  (struct-get command env))

;: Return the borrowed stdin setting from `command`.
(define (process-borrowed-command-stdin
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : (ProcessBorrowedMaybeString
  stdin)
  (struct-get command stdin))

;: Copy borrowed command storage to the owned runtime command representation.
(define (process-borrowed-command-owned
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : ProcessCommand
  (ProcessCommand
    (process-borrowed-string-owned
      (process-borrowed-command-executable command))
    (process-borrowed-args-owned (process-borrowed-command-argv command))
    (process-borrowed-maybe-owned (process-borrowed-command-cwd command))
    (process-borrowed-env-owned (process-borrowed-command-env command))
    (process-borrowed-maybe-owned (process-borrowed-command-stdin command))))

;: Return the first borrowed env validation error, or `ProcessNoString`.
(define (process-borrowed-env-validation-error
  [env : (ProcessBorrowedEnvList env)]) : ProcessMaybeString
  (match env
    [(ProcessBorrowedEnvNil) (ProcessNoString)]
    [(ProcessBorrowedEnvCons name _ rest)
      (if (= (string-length name) 0)
        (ProcessSomeString "process: environment variable name is empty")
        (if (process-string-contains-char? name #=')
          (ProcessSomeString "process: environment variable name contains '='")
          (process-borrowed-env-validation-error (box-get rest))))]))

;: Return the first borrowed command validation error, or `ProcessNoString`.
(define (process-borrowed-command-validation-error
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : ProcessMaybeString
  (if (= (string-length (process-borrowed-command-executable command)) 0)
    (ProcessSomeString "process: executable path is empty")
    (match (process-borrowed-command-cwd command)
      [(ProcessBorrowedSomeString cwd)
        (if (= (string-length cwd) 0)
          (ProcessSomeString "process: cwd path is empty")
          (process-borrowed-env-validation-error
            (process-borrowed-command-env command)))]
      [(ProcessBorrowedNoString)
        (process-borrowed-env-validation-error
          (process-borrowed-command-env command))])))

;: Return true when a borrowed command passes stdlib validation.
(define (process-borrowed-command-valid?
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : bool
  (match (process-borrowed-command-validation-error command)
    [(ProcessNoString) true]
    [(ProcessSomeString _) false]))

;: Run a borrowed command by validating borrowed storage, copying to an owned
;: command at the runtime boundary, then using `process-output`.
(define (process-borrowed-output
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : ResultProcessOutput
  (match (process-borrowed-command-validation-error command)
    [(ProcessSomeString message)
      (ErrProcessOutput (ProcessInvalidCommand message))]
    [(ProcessNoString)
      (process-output (process-borrowed-command-owned command))]))

;: Run a borrowed command using the same captured-output path as
;: `process-borrowed-output`.
(define (process-borrowed-run
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : ResultProcessOutput
  (process-borrowed-output command))

;: Start a borrowed command after validation and owned runtime conversion.
(define (process-borrowed-start
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : ResultProcessChild
  (match (process-borrowed-command-validation-error command)
    [(ProcessSomeString message)
      (ErrProcessChild (ProcessInvalidCommand message))]
    [(ProcessNoString) (process-start (process-borrowed-command-owned command))]))