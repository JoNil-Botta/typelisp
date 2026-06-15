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
(module stdlib.process_borrowed)

(import stdlib.process as process_mod)

(import stdlib.string as string_mod)

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
  stdlib.process_borrowed.ProcessBorrowedStringNil)

;: Return the number of borrowed argv entries in `args`.
(define (process-borrowed-args-count [args : (ProcessBorrowedStringList text)]) : i64
  (match args
    [(ProcessBorrowedStringNil) 0]
    [(ProcessBorrowedStringCons _ rest)
      (+ 1 (stdlib.process_borrowed.process-borrowed-args-count (box-get rest)))]))

;: Prepend a borrowed argument string to an argv list without copying bytes.
(define (process-borrowed-args-cons
  [value : (& text str)]
  [rest : (ProcessBorrowedStringList text)]) : (ProcessBorrowedStringList text)
  (ProcessBorrowedStringCons value (box rest)))

;: Return a one-element borrowed argument list.
(define (process-borrowed-args-single [value : (& text str)]) : (ProcessBorrowedStringList
    text)
  (ProcessBorrowedStringCons
    value
    (box stdlib.process_borrowed.ProcessBorrowedStringNil)))

;: Copy a borrowed string into active-arena owned storage.
(define (process-borrowed-string-owned [value : (& value str)]) : String
  (string_mod.substring-borrowed value 0 (string-length value)))

;: Copy borrowed argv storage to the owned process argv representation.
(define (process-borrowed-args-owned [args : (ProcessBorrowedStringList text)]) : process_mod.ProcessStringList
  (match args
    [(ProcessBorrowedStringNil) (process_mod.ProcessStringNil)]
    [(ProcessBorrowedStringCons value rest)
      (process_mod.ProcessStringCons
        (stdlib.process_borrowed.process-borrowed-string-owned value)
        (box
          (stdlib.process_borrowed.process-borrowed-args-owned (box-get rest))))]))

;: Return an empty borrowed environment override list tied to `text`.
(define (process-borrowed-env-empty-like [text : (& text str)]) : (ProcessBorrowedEnvList
    text)
  stdlib.process_borrowed.ProcessBorrowedEnvNil)

;: Return the number of borrowed env overrides in `env`.
(define (process-borrowed-env-count [env : (ProcessBorrowedEnvList text)]) : i64
  (match env
    [(ProcessBorrowedEnvNil) 0]
    [(ProcessBorrowedEnvCons _ _ rest)
      (+ 1 (stdlib.process_borrowed.process-borrowed-env-count (box-get rest)))]))

;: Prepend borrowed environment override strings without copying bytes.
(define (process-borrowed-env-cons
  [name : (& text str)]
  [value : (& text str)]
  [rest : (ProcessBorrowedEnvList text)]) : (ProcessBorrowedEnvList text)
  (ProcessBorrowedEnvCons name value (box rest)))

;: Copy borrowed env storage to the owned process env representation.
(define (process-borrowed-env-owned [env : (ProcessBorrowedEnvList text)]) : process_mod.ProcessEnvList
  (match env
    [(ProcessBorrowedEnvNil) (process_mod.ProcessEnvNil)]
    [(ProcessBorrowedEnvCons name value rest)
      (process_mod.ProcessEnvCons
        (stdlib.process_borrowed.process-borrowed-string-owned name)
        (stdlib.process_borrowed.process-borrowed-string-owned value)
        (box
          (stdlib.process_borrowed.process-borrowed-env-owned (box-get rest))))]))

;: Return a borrowed stdin/cwd value that stores no string but keeps the target
;: type lifetime anchored to `text`.
(define (process-borrowed-no-string-like [text : (& text str)]) : (ProcessBorrowedMaybeString
    text)
  stdlib.process_borrowed.ProcessBorrowedNoString)

;: Return a borrowed stdin/cwd value without copying bytes.
(define (process-borrowed-some-string [value : (& text str)]) : (ProcessBorrowedMaybeString
    text)
  (ProcessBorrowedSomeString value))

;: Copy a borrowed optional string to the owned process representation.
(define (process-borrowed-maybe-owned
  [value : (ProcessBorrowedMaybeString text)]) : process_mod.ProcessMaybeString
  (match value
    [(ProcessBorrowedNoString) (process_mod.ProcessNoString)]
    [(ProcessBorrowedSomeString text)
      (process_mod.ProcessSomeString
        (stdlib.process_borrowed.process-borrowed-string-owned text))]))

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
    (stdlib.process_borrowed.process-borrowed-no-string-like executable)
    (stdlib.process_borrowed.process-borrowed-env-empty-like executable)
    (stdlib.process_borrowed.process-borrowed-no-string-like executable)))

;: Construct a borrowed command with no argv entries.
(define (process-borrowed-command-empty [executable : (& executable str)]) : (ProcessBorrowedCommand
    executable
    executable
    executable
    executable
    executable)
  (stdlib.process_borrowed.process-borrowed-command
    executable
    (stdlib.process_borrowed.process-borrowed-args-empty-like executable)))

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
    (stdlib.process_borrowed.process-borrowed-command-executable command)
    args
    (stdlib.process_borrowed.process-borrowed-command-cwd command)
    (stdlib.process_borrowed.process-borrowed-command-env command)
    (stdlib.process_borrowed.process-borrowed-command-stdin command)))

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
    (stdlib.process_borrowed.process-borrowed-command-executable command)
    (stdlib.process_borrowed.process-borrowed-command-argv command)
    (ProcessBorrowedSomeString cwd)
    (stdlib.process_borrowed.process-borrowed-command-env command)
    (stdlib.process_borrowed.process-borrowed-command-stdin command)))

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
    (stdlib.process_borrowed.process-borrowed-command-executable command)
    (stdlib.process_borrowed.process-borrowed-command-argv command)
    (stdlib.process_borrowed.process-borrowed-command-cwd command)
    (ProcessBorrowedEnvCons
      name
      value
      (box (stdlib.process_borrowed.process-borrowed-command-env command)))
    (stdlib.process_borrowed.process-borrowed-command-stdin command)))

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
    (stdlib.process_borrowed.process-borrowed-command-executable command)
    (stdlib.process_borrowed.process-borrowed-command-argv command)
    (stdlib.process_borrowed.process-borrowed-command-cwd command)
    env
    (stdlib.process_borrowed.process-borrowed-command-stdin command)))

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
    (stdlib.process_borrowed.process-borrowed-command-executable command)
    (stdlib.process_borrowed.process-borrowed-command-argv command)
    (stdlib.process_borrowed.process-borrowed-command-cwd command)
    (stdlib.process_borrowed.process-borrowed-command-env command)
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
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process_mod.ProcessCommand
  (process_mod.ProcessCommand
    (stdlib.process_borrowed.process-borrowed-string-owned
      (stdlib.process_borrowed.process-borrowed-command-executable command))
    (stdlib.process_borrowed.process-borrowed-args-owned
      (stdlib.process_borrowed.process-borrowed-command-argv command))
    (stdlib.process_borrowed.process-borrowed-maybe-owned
      (stdlib.process_borrowed.process-borrowed-command-cwd command))
    (stdlib.process_borrowed.process-borrowed-env-owned
      (stdlib.process_borrowed.process-borrowed-command-env command))
    (stdlib.process_borrowed.process-borrowed-maybe-owned
      (stdlib.process_borrowed.process-borrowed-command-stdin command))))

;: Return the first borrowed env validation error, or `ProcessNoString`.
(define (process-borrowed-env-validation-error
  [env : (ProcessBorrowedEnvList env)]) : process_mod.ProcessMaybeString
  (match env
    [(ProcessBorrowedEnvNil) (process_mod.ProcessNoString)]
    [(ProcessBorrowedEnvCons name _ rest)
      (if (= (string-length name) 0)
        (process_mod.ProcessSomeString
          "process: environment variable name is empty")
        (if (process_mod.process-string-contains-char? name #=')
          (process_mod.ProcessSomeString
            "process: environment variable name contains '='")
          (stdlib.process_borrowed.process-borrowed-env-validation-error
            (box-get rest))))]))

;: Return the first borrowed command validation error, or `ProcessNoString`.
(define (process-borrowed-command-validation-error
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process_mod.ProcessMaybeString
  (if (=
    (string-length
      (stdlib.process_borrowed.process-borrowed-command-executable command))
    0)
    (process_mod.ProcessSomeString "process: executable path is empty")
    (match (stdlib.process_borrowed.process-borrowed-command-cwd command)
      [(ProcessBorrowedSomeString cwd)
        (if (= (string-length cwd) 0)
          (process_mod.ProcessSomeString "process: cwd path is empty")
          (stdlib.process_borrowed.process-borrowed-env-validation-error
            (stdlib.process_borrowed.process-borrowed-command-env command)))]
      [(ProcessBorrowedNoString)
        (stdlib.process_borrowed.process-borrowed-env-validation-error
          (stdlib.process_borrowed.process-borrowed-command-env command))])))

;: Return true when a borrowed command passes stdlib validation.
(define (process-borrowed-command-valid?
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : bool
  (match (stdlib.process_borrowed.process-borrowed-command-validation-error
    command)
    [(process_mod.ProcessNoString) true]
    [(process_mod.ProcessSomeString _) false]))

;: Run a borrowed command by validating borrowed storage, copying to an owned
;: command at the runtime boundary, then using `process-output`.
(define (process-borrowed-output
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process_mod.ResultProcessOutput
  (match (stdlib.process_borrowed.process-borrowed-command-validation-error
    command)
    [(process_mod.ProcessSomeString message)
      (process_mod.ErrProcessOutput (process_mod.ProcessInvalidCommand message))]
    [(process_mod.ProcessNoString)
      (process_mod.process-output
        (stdlib.process_borrowed.process-borrowed-command-owned command))]))

;: Run a borrowed command using the same captured-output path as
;: `process-borrowed-output`.
(define (process-borrowed-run
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process_mod.ResultProcessOutput
  (stdlib.process_borrowed.process-borrowed-output command))

;: Start a borrowed command after validation and owned runtime conversion.
(define (process-borrowed-start
  [command : (ProcessBorrowedCommand executable argv cwd env stdin)]) : process_mod.ResultProcessChild
  (match (stdlib.process_borrowed.process-borrowed-command-validation-error
    command)
    [(process_mod.ProcessSomeString message)
      (process_mod.ErrProcessChild (process_mod.ProcessInvalidCommand message))]
    [(process_mod.ProcessNoString)
      (process_mod.process-start
        (stdlib.process_borrowed.process-borrowed-command-owned command))]))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value process-borrowed-args-empty-like)
  (value process-borrowed-args-count)
  (value process-borrowed-args-cons)
  (value process-borrowed-args-single)
  (value process-borrowed-string-owned)
  (value process-borrowed-args-owned)
  (value process-borrowed-env-empty-like)
  (value process-borrowed-env-count)
  (value process-borrowed-env-cons)
  (value process-borrowed-env-owned)
  (value process-borrowed-no-string-like)
  (value process-borrowed-some-string)
  (value process-borrowed-maybe-owned)
  (value process-borrowed-command)
  (value process-borrowed-command-empty)
  (value process-borrowed-command-with-argv)
  (value process-borrowed-command-full)
  (value process-borrowed-command-with-cwd)
  (value process-borrowed-command-with-env)
  (value process-borrowed-command-with-env-list)
  (value process-borrowed-command-with-stdin)
  (value process-borrowed-command-executable)
  (value process-borrowed-command-argv)
  (value process-borrowed-command-cwd)
  (value process-borrowed-command-env)
  (value process-borrowed-command-stdin)
  (value process-borrowed-command-owned)
  (value process-borrowed-env-validation-error)
  (value process-borrowed-command-validation-error)
  (value process-borrowed-command-valid?)
  (value process-borrowed-output)
  (value process-borrowed-run)
  (value process-borrowed-start)
  (type ProcessBorrowedStringList)
  (type ProcessBorrowedMaybeString)
  (type ProcessBorrowedEnvList)
  (type ProcessBorrowedCommand)
  (constructor ProcessBorrowedCommand)
  (field ProcessBorrowedCommand executable)
  (field ProcessBorrowedCommand argv)
  (field ProcessBorrowedCommand cwd)
  (field ProcessBorrowedCommand env)
  (field ProcessBorrowedCommand stdin)
  (variant ProcessBorrowedStringNil)
  (variant ProcessBorrowedStringCons)
  (variant ProcessBorrowedNoString)
  (variant ProcessBorrowedSomeString)
  (variant ProcessBorrowedEnvNil)
  (variant ProcessBorrowedEnvCons))