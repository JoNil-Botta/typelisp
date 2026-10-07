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
;; A parser walks argv in one `while` loop over a `CliArgs` cursor, filling
;; its command's mutable config. `cli-args-next!` steps to the next argument,
;; matches it against the table, and checks that the option's values are
;; present, failing with the shared "<command>: <option> requires a value"
;; diagnostic. The loop body dispatches on the canonical `name` (empty for an
;; argument no entry matches) and reports the command's own duplicate,
;; invalid-value and unknown-argument diagnostics: scripts assert their wording
;; byte for byte, so each command keeps its literals. The few options with
;; irregular values (an optional value, or a custom missing-value message)
;; are declared as flags and take their values by advancing `next` by hand.
(import stdlib.io)
(import stdlib.string)

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
  (string.concat4-borrowed command ": " option " requires a value"))

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

;; Shared value validators; each command words its own diagnostic.
(define (cli-option-opt-level [value : (& value str)]) : i64
  (cond
    [(string.eq value "0") 0]
    [(string.eq value "1") 1]
    [(string.eq value "2") 2]
    [else -1]))