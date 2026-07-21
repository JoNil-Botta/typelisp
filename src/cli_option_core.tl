;; Shared recognition for value-taking command options. Command modules keep
;; their own config/result types and value validation, while this module owns
;; flag spelling, argv bounds checks, and the common missing-value diagnostic.
(import stdlib.io)
(import stdlib.string)

(define cli-common-option-stdlib-root : i64
  1)
(define cli-common-option-cfg : i64
  2)
(define cli-common-option-target : i64
  4)
(define cli-common-option-opt-level : i64
  8)
(define cli-common-option-build : i64
  13)
(define cli-common-option-all : i64
  15)

(defenum CliCommonOptionKind
  (StdlibRoot)
  (Cfg)
  (Target)
  (OptLevel))

(defenum CliCommonOption
  (NotCommon)
  (Missing CliCommonOptionKind)
  (Value CliCommonOptionKind String i64))

(define (cli-common-option-enabled? [allowed : i64] [flag : i64]) : bool
  (not (= (bit-and allowed flag) 0)))

(define (cli-common-option-name [kind : CliCommonOptionKind]) : String
  (match kind
    [(CliCommonOptionKind.StdlibRoot) "--stdlib-root"]
    [(CliCommonOptionKind.Cfg) "--cfg"]
    [(CliCommonOptionKind.Target) "--target"]
    [(CliCommonOptionKind.OptLevel) "--opt-level"]))

(define (cli-common-option-value
  [kind : CliCommonOptionKind]
  [idx : i64]
  [count : i64]) : CliCommonOption
  (if (>= (+ idx 1) count)
    (CliCommonOption.Missing kind)
    (CliCommonOption.Value kind (io.arg (+ idx 1)) (+ idx 2))))

(define (cli-common-option-parse
  [current : String]
  [idx : i64]
  [count : i64]
  [allowed : i64]) : CliCommonOption
  (cond
    [(and
        (cli-common-option-enabled? allowed cli-common-option-stdlib-root)
        (string.eq current "--stdlib-root"))
      (cli-common-option-value (CliCommonOptionKind.StdlibRoot) idx count)]
    [(and
        (cli-common-option-enabled? allowed cli-common-option-cfg)
        (string.eq current "--cfg"))
      (cli-common-option-value (CliCommonOptionKind.Cfg) idx count)]
    [(and
        (cli-common-option-enabled? allowed cli-common-option-target)
        (string.eq current "--target"))
      (cli-common-option-value (CliCommonOptionKind.Target) idx count)]
    [(and
        (cli-common-option-enabled? allowed cli-common-option-opt-level)
        (string.eq current "--opt-level"))
      (cli-common-option-value (CliCommonOptionKind.OptLevel) idx count)]
    [else CliCommonOption.NotCommon]))

(define (cli-common-option-missing-message-default
  [command : String]
  [kind : CliCommonOptionKind]) : String
  (string.append
    command
    (string.append
      ": "
      (string.append (cli-common-option-name kind) " requires a value"))))

;; Keep the diagnostics covered by the assembly-level self-host audit as
;; complete literals. Other commands use the same centralized wording below.
(define (cli-common-option-missing-message
  [command : String]
  [kind : CliCommonOptionKind]) : String
  (cond
    [(string.eq command "compile")
      (match kind
        [(CliCommonOptionKind.StdlibRoot)
          "compile: --stdlib-root requires a value"]
        [(CliCommonOptionKind.Cfg) "compile: --cfg requires a value"]
        [(CliCommonOptionKind.Target) "compile: --target requires a value"]
        [(CliCommonOptionKind.OptLevel) "compile: --opt-level requires a value"])]
    [(and
        (string.eq command "test")
        (match kind
          [(CliCommonOptionKind.OptLevel) true]
          [_ false]))
      "test: --opt-level requires a value"]
    [(and
        (string.eq command "selfhost-check")
        (match kind
          [(CliCommonOptionKind.StdlibRoot) true]
          [_ false]))
      "selfhost-check: --stdlib-root requires a value"]
    [else (cli-common-option-missing-message-default command kind)]))