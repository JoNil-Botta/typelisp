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

;; Keep public diagnostics as complete literals. Besides making the wording
;; policy visible in one place, this preserves the assembly-level diagnostic
;; audit used by the self-host compile manifest.
(define (cli-common-option-missing-message
  [command : String]
  [kind : CliCommonOptionKind]) : String
  (cond
    [(string.eq command "build")
      (match kind
        [(CliCommonOptionKind.StdlibRoot)
          "build: --stdlib-root requires a value"]
        [(CliCommonOptionKind.Target) "build: --target requires a value"]
        [(CliCommonOptionKind.OptLevel) "build: --opt-level requires a value"]
        [(CliCommonOptionKind.Cfg)
          (cli-common-option-missing-message-default command kind)])]
    [(string.eq command "run")
      (match kind
        [(CliCommonOptionKind.StdlibRoot) "run: --stdlib-root requires a value"]
        [(CliCommonOptionKind.Cfg) "run: --cfg requires a value"]
        [(CliCommonOptionKind.Target) "run: --target requires a value"]
        [(CliCommonOptionKind.OptLevel) "run: --opt-level requires a value"])]
    [(string.eq command "compile")
      (match kind
        [(CliCommonOptionKind.StdlibRoot)
          "compile: --stdlib-root requires a value"]
        [(CliCommonOptionKind.Cfg) "compile: --cfg requires a value"]
        [(CliCommonOptionKind.Target) "compile: --target requires a value"]
        [(CliCommonOptionKind.OptLevel) "compile: --opt-level requires a value"])]
    [(string.eq command "test")
      (match kind
        [(CliCommonOptionKind.StdlibRoot)
          "test: --stdlib-root requires a value"]
        [(CliCommonOptionKind.Target) "test: --target requires a value"]
        [(CliCommonOptionKind.OptLevel) "test: --opt-level requires a value"]
        [(CliCommonOptionKind.Cfg)
          (cli-common-option-missing-message-default command kind)])]
    [(string.eq command "fmt")
      (match kind
        [(CliCommonOptionKind.StdlibRoot) "fmt: --stdlib-root requires a value"]
        [_ (cli-common-option-missing-message-default command kind)])]
    [(string.eq command "doc")
      (match kind
        [(CliCommonOptionKind.StdlibRoot) "doc: --stdlib-root requires a value"]
        [_ (cli-common-option-missing-message-default command kind)])]
    [(string.eq command "selfhost-check")
      (match kind
        [(CliCommonOptionKind.StdlibRoot)
          "selfhost-check: --stdlib-root requires a value"]
        [_ (cli-common-option-missing-message-default command kind)])]
    [(string.eq command "Error")
      (match kind
        [(CliCommonOptionKind.StdlibRoot)
          "Error: --stdlib-root requires a value"]
        [_ (cli-common-option-missing-message-default command kind)])]
    [else (cli-common-option-missing-message-default command kind)]))

(test
  cli-common-option-recognizes-enabled-flags
  (match (cli-common-option-parse "--target" 0 1 cli-common-option-all)
    [(CliCommonOption.Missing (CliCommonOptionKind.Target)) unit]
    [_ (io.panic "shared CLI parser did not recognize --target")]))

(test
  cli-common-option-respects-allowed-mask
  (match (cli-common-option-parse "--target" 0 1 cli-common-option-stdlib-root)
    [(CliCommonOption.NotCommon)
      (if (string.eq
        (cli-common-option-missing-message
          "fmt"
          (CliCommonOptionKind.StdlibRoot))
        "fmt: --stdlib-root requires a value")
        unit
        (io.panic "shared CLI parser changed the missing-value diagnostic"))]
    [_ (io.panic "shared CLI parser ignored its allowed-option mask")]))