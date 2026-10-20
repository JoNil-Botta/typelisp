;; cli_option_core.tl - The declarative option layer every command parses
;; its arguments with.
;;
;; A command declares the options it accepts as a spec table: a string of
;; whitespace-separated entries, each an option spelling (aliases joined by
;; `|`, the first being the canonical name) followed by one `<metavar>` per
;; value the option takes, for example
;;
;;   "--debug|-g|--backtrace --target <target> --manifest-path <file>"
;;
;; `CliArgs` checks arity and canonicalizes aliases before command dispatch.
;; Common compile options go through `cli-compile-option!`; command-specific
;; options retain their own validation. Optional or irregular value lists use
;; a flag entry and advance the cursor explicitly.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import compiler_target_cfg_core as target_cfg)

(defstruct CliArgs
  (command String)
  (specs String)
  (count i64)
  ;; argv index of the current argument, and of the argument after its values.
  (index i64)
  (next i64)
  ;; The current argument as written, and the canonical name of the option it
  ;; matched ("" when it matched none).
  (arg String)
  (name String)
  (error String)
  (failed bool)
  (stopped bool))

(defenum CliOptionMatch
  (None)
  (Found String i64))

(define (cli-args
  [command : String]
  [specs : String]
  [start : i64]
  [count : i64]) : CliArgs
  (CliArgs command specs count start start "" "" "" false false))

;; A leading `-` marks a flag: parsers reject unknown ones and treat anything
;; else as a positional argument.
(define (cli-flag? [value : (& value str)]) : bool
  (and (> (string.string-length value) 0) (= (string.string-ref value 0) '-')))

(define (cli-spec-space? [c : char]) : bool
  (or (= c ' ') (= c '\n')))

(define (cli-spec-skip-space [specs : (& specs str)] [start : i64]) : i64
  (let
    [n : i64 (string.string-length specs)]
    [i : i64 start]
    (while (and (< i n) (cli-spec-space? (string.string-ref specs i)))
      (set! i (+ i 1)))
    i))

(define (cli-spec-token-end [specs : (& specs str)] [start : i64]) : i64
  (let
    [n : i64 (string.string-length specs)]
    [i : i64 start]
    (while (and (< i n) (not (cli-spec-space? (string.string-ref specs i))))
      (set! i (+ i 1)))
    i))

;; End of the `|`-separated spelling at `start` in an entry ending at `end`.
(define (cli-spec-alias-end [specs : (& specs str)] [start : i64] [end : i64]) : i64
  (let
    [i : i64 start]
    (while (and (< i end) (not (= (string.string-ref specs i) '|')))
      (set! i (+ i 1)))
    i))

(define (cli-spec-entry-names?
  [specs : (& specs str)]
  [start : i64]
  [end : i64]
  [arg : (& arg str)]) : bool
  (let
    [alias : i64 start]
    [found : bool false]
    (while (and (not found) (< alias end))
      (let
        [alias-end : i64 (cli-spec-alias-end specs alias end)]
        (set!
          found
          (and
            (= (- alias-end alias) (string.string-length arg))
            (string.is-string-prefix-at specs arg alias)))
        (set! alias (+ alias-end 1))))
    found))

;; Find `arg` in a spec table: its canonical name and how many values it takes.
(define (cli-option-lookup [specs : (& specs str)] [arg : (& arg str)]) : CliOptionMatch
  (let
    [n : i64 (string.string-length specs)]
    [i : i64 (cli-spec-skip-space specs 0)]
    [result : CliOptionMatch (None)]
    [found : bool false]
    (while (and (not found) (< i n))
      (let
        [end : i64 (cli-spec-token-end specs i)]
        (when
          (and
            (not (= (string.string-ref specs i) '<'))
            (cli-spec-entry-names? specs i end arg))
          (let
            [value : i64 (cli-spec-skip-space specs end)]
            [arity : i64 0]
            (while (and (< value n) (= (string.string-ref specs value) '<'))
              (set! arity (+ arity 1))
              (set!
                value
                (cli-spec-skip-space specs (cli-spec-token-end specs value))))
            (set!
              result
              (Found
                (string.substring
                  specs
                  i
                  (- (cli-spec-alias-end specs i end) i))
                arity))
            (set! found true)))
        (set! i (cli-spec-skip-space specs end))))
    result))

(define (cli-option-missing-value-message
  [command : (& command str)]
  [option : (& option str)]) : String
  (if (cli-compile-option? option)
    (string.concat3-borrowed "" option " requires a value")
    (string.concat4-borrowed command ": " option " requires a value")))

(define (cli-args-fail! [args : (&mut args CliArgs)] [message : String]) : unit
  (set! args.error message)
  (set! args.failed true))

;; Fail with `prefix` followed by the current argument, as in
;; "clean: unknown flag --bogus".
(define (cli-args-fail-arg!
  [args : (&mut args CliArgs)]
  [prefix : (& prefix str)]) : unit
  (let
    [message : String (string.concat3-borrowed prefix (& args.arg) "")]
    (cli-args-fail! args message)))

;; Stop before the next argument, leaving the rest of argv to the caller.
(define (cli-args-stop! [args : (&mut args CliArgs)]) : unit
  (set! args.stopped true))

;; Step to the next argument. False at the end of argv, after a failure, or
;; after `cli-args-stop!`.
(define (cli-args-next! [args : (&mut args CliArgs)]) : bool
  (if (or args.failed args.stopped (>= args.next args.count))
    false
    (let
      [index : i64 args.next]
      [arg : String (io.arg index)]
      (set! args.index index)
      (match (cli-option-lookup (& args.specs) (& arg))
        [(None)
          (set! args.name "")
          (set! args.next (+ index 1))]
        [(Found name arity)
          (set! args.name name)
          (set! args.next (+ index (+ arity 1)))
          (when
            (> args.next args.count)
            (cli-args-fail!
              args
              (cli-option-missing-value-message (& args.command) (& arg))))])
      (set! args.arg arg)
      (not args.failed))))

;; The first (or `n`th) value of the current option.
(define (cli-args-value [args : (& args CliArgs)]) : String
  (io.arg (+ args.index 1)))

(define (cli-args-value-at [args : (& args CliArgs)] [n : i64]) : String
  (io.arg (+ args.index n)))

;; Shared value validators.
(define (cli-option-opt-level [value : (& value str)]) : i64
  (cond
    [(string.eq value "0") 0]
    [(string.eq value "1") 1]
    [(string.eq value "2") 2]
    [else -1]))

(defenum CliBackendMode
  (Scalar)
  (Avx2)
  (Avx512))

(defenum ResultCliBackendMode
  (Ok CliBackendMode)
  (Err String))

;; Defaults belong to the command. Presence records survive parsing so later
;; configuration resolution can distinguish an explicit value from a default.
(defstruct CliCompileOptions
  (target target_cfg.CompilerTargetCfg)
  (has-target bool)
  (backend-mode CliBackendMode)
  (has-backend-mode bool)
  (opt-level i64)
  (has-opt-level bool)
  (stdlib-roots cli_svec.Vec)
  (cfgs cli_svec.Vec)
  (debug bool)
  (has-debug bool))

(define (cli-compile-options
  [target : target_cfg.CompilerTargetCfg]
  [opt-level : i64]) : CliCompileOptions
  (CliCompileOptions
    target
    false
    Scalar
    false
    opt-level
    false
    (cli_svec.new)
    (cli_svec.new)
    false
    false))

(define (cli-compile-option? [name : (& name str)]) : bool
  (or
    (string.eq name "--target")
    (string.eq name "--backend-mode")
    (string.eq name "--opt-level")
    (string.eq name "--stdlib-root")
    (string.eq name "--cfg")
    (string.eq name "--debug")
    (string.eq name "-g")
    (string.eq name "--backtrace")))

(define (cli-option-target [value : String]) : target_cfg.ResultCompilerTargetCfg
  (cond
    [(or (string.eq value "linux-x86_64") (string.eq value "linux_x86_64"))
      (Ok Linux)]
    [(or (string.eq value "windows-x86_64") (string.eq value "windows_x86_64"))
      (Ok Windows)]
    [else
      (Err
        (string.concat3-borrowed
          "invalid --target '"
          (& value)
          "'; expected linux-x86_64 or windows-x86_64"))]))

(define (cli-option-target-name [target : target_cfg.CompilerTargetCfg]) : String
  (match target
    [(Linux) "linux-x86_64"]
    [(Windows) "windows-x86_64"]))

(define (cli-option-backend-mode [value : String]) : ResultCliBackendMode
  (cond
    [(string.eq value "scalar") (Ok Scalar)]
    [(string.eq value "avx2") (Ok Avx2)]
    [(string.eq value "avx512") (Ok Avx512)]
    [else
      (Err
        (string.concat3-borrowed
          "invalid --backend-mode '"
          (& value)
          "'; expected scalar, avx2, or avx512"))]))

(define (cli-option-backend-mode-name [mode : CliBackendMode]) : String
  (match mode
    [(Scalar) "scalar"]
    [(Avx2) "avx2"]
    [(Avx512) "avx512"]))

(define (cli-option-duplicate! [args : (&mut args CliArgs)]) : unit
  (cli-args-fail!
    args
    (string.concat3-borrowed "" (& args.name) " was provided more than once")))

;; Repeatable roots/cfgs retain order; singleton aliases share one presence bit.
;; Parsing has no compiler-global side effects, including on rejected input.
(define (cli-compile-option!
  [options : (&mut options CliCompileOptions)]
  [args : (&mut args CliArgs)]) : bool
  (cond
    [(not (cli-compile-option? (& args.name))) false]
    [(string.eq args.name "--debug")
      (if options.has-debug
        (cli-option-duplicate! args)
        (begin
          (set! options.debug true)
          (set! options.has-debug true)))
      true]
    [else
      (let
        [value : String (cli-args-value args)]
        (cond
          [(cli-flag? (& value))
            (cli-args-fail!
              args
              (cli-option-missing-value-message (& args.command) (& args.name)))]
          [(string.eq args.name "--target")
            (if options.has-target
              (cli-option-duplicate! args)
              (match (cli-option-target value)
                [(Ok target)
                  (set! options.target target)
                  (set! options.has-target true)]
                [(Err message) (cli-args-fail! args message)]))]
          [(string.eq args.name "--backend-mode")
            (if options.has-backend-mode
              (cli-option-duplicate! args)
              (match (cli-option-backend-mode value)
                [(Ok mode)
                  (set! options.backend-mode mode)
                  (set! options.has-backend-mode true)]
                [(Err message) (cli-args-fail! args message)]))]
          [(string.eq args.name "--opt-level")
            (let
              [level : i64 (cli-option-opt-level (& value))]
              (cond
                [options.has-opt-level (cli-option-duplicate! args)]
                [(< level 0)
                  (cli-args-fail!
                    args
                    (string.concat3-borrowed
                      "invalid --opt-level '"
                      (& value)
                      "'; expected 0, 1, or 2"))]
                [else
                  (set! options.opt-level level)
                  (set! options.has-opt-level true)]))]
          [(= (string.string-length (& value)) 0)
            (cli-args-fail!
              args
              (string.concat3-borrowed
                ""
                (& args.name)
                " requires a non-empty value"))]
          [(string.eq args.name "--cfg")
            (cli_svec.push-ref! (&mut options.cfgs) value)]
          [else (cli_svec.push-ref! (&mut options.stdlib-roots) value)])
        true)]))