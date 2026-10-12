;; expand_cli_core.tl - Self-hosted `expand` command: inspect the checked
;; expansion of the macro invocation at a source position (#7067).
;;
;; Main-free, so the unified `main.tl` dispatcher runs the command without a
;; duplicate `main`. The query itself lives in `compiler_expand_query.tl` and
;; is shared with the language server's `tl/expandMacro`.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.io)
(import stdlib.string)
(import stdlib.byte_buf)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import cli_option_core as cli_option)
(import compiler_target_cfg_core as target_cfg)
(import compiler_driver_core)
(import compiler_diagnostic as cdiag)
(import compiler_expand_query as expand)

(defstruct SelfhostExpandConfig
  (input-path String)
  (line i64)
  (col i64)
  (max-bytes i64)
  (stdlib-roots cli_svec.Vec)
  (target target_cfg.CompilerTargetCfg)
  (cfg-names cli_svec.Vec))

(defenum ResultSelfhostExpandConfig
  (Ok SelfhostExpandConfig)
  (Err String))

;; The decimal value of `text`, or -1 unless it is 1-9 digits.
(define (selfhost-expand-positive-int [text : String]) : i64
  (let
    [count : i64 (string.string-length (& text))]
    [index : i64 0]
    [value : i64 0]
    [ok : bool (and (> count 0) (<= count 9))]
    (while (and ok (< index count))
      (let
        [c : char (string.char-at (& text) index)]
        (if (and (>= c '0') (<= c '9'))
          (set! value (+ (* value 10) (- (cast c : i64) (cast '0' : i64))))
          (set! ok false)))
      (set! index (+ index 1)))
    (if (and ok (> value 0))
      value
      -1)))

;; `line:column`, both 1-based, as a two-element pair packed into one value:
;; line * 2^32 + column, or -1 when malformed.
(define (selfhost-expand-position [text : String]) : i64
  (let
    [count : i64 (string.string-length (& text))]
    [colon : i64 -1]
    [index : i64 0]
    (while (< index count)
      (when
        (and (= colon -1) (= (string.char-at (& text) index) ':'))
        (set! colon index))
      (set! index (+ index 1)))
    (if (< colon 0)
      -1
      (let
        [line : i64
          (selfhost-expand-positive-int (string.substring text 0 colon))]
        [col : i64
          (selfhost-expand-positive-int
            (string.substring text (+ colon 1) (- count (+ colon 1))))]
        (if (or (< line 0) (< col 0))
          -1
          (+ (* line 4294967296) col))))))

;; Parse the `expand` config from arguments starting at `start`. `count` is
;; `(arg-count)`.
(define (selfhost-expand-config-from [start : i64] [count : i64]) : ResultSelfhostExpandConfig
  (let
    [args : cli_option.CliArgs
      (cli_option.cli-args
        "expand"
        "--at <line:column> --max-bytes <n> --stdlib-root <dir> --cfg <name> --target <target>"
        start
        count)]
    [input-path : String ""]
    [has-input : bool false]
    [position : i64 -1]
    [has-position : bool false]
    [max-bytes : i64 expand.compiler-expand-default-max-bytes]
    [has-max-bytes : bool false]
    [stdlib-roots : cli_svec.Vec (cli_svec.new)]
    [target : target_cfg.CompilerTargetCfg
      (target_cfg.compiler-target-cfg-default)]
    [has-target : bool false]
    [cfg-names : cli_svec.Vec (cli_svec.new)]
    (while (cli_option.cli-args-next! (&mut args))
      (cond
        [(string.eq args.name "--at")
          (cond
            [has-position
              (cli_option.cli-args-fail!
                (&mut args)
                "expand: --at was provided more than once")]
            [else
              (set!
                position
                (selfhost-expand-position (cli_option.cli-args-value (& args))))
              (set! has-position true)
              (when
                (< position 0)
                (cli_option.cli-args-fail!
                  (&mut args)
                  "expand: --at expects <line>:<column> with positive line and column numbers"))])]
        [(string.eq args.name "--max-bytes")
          (cond
            [has-max-bytes
              (cli_option.cli-args-fail!
                (&mut args)
                "expand: --max-bytes was provided more than once")]
            [else
              (set!
                max-bytes
                (selfhost-expand-positive-int
                  (cli_option.cli-args-value (& args))))
              (set! has-max-bytes true)
              (when
                (< max-bytes 0)
                (cli_option.cli-args-fail!
                  (&mut args)
                  "expand: --max-bytes expects a positive byte count"))])]
        [(string.eq args.name "--stdlib-root")
          (cli_svec.push-ref!
            (&mut stdlib-roots)
            (cli_option.cli-args-value (& args)))]
        [(string.eq args.name "--cfg")
          (cli_svec.push-ref!
            (&mut cfg-names)
            (cli_option.cli-args-value (& args)))]
        [(string.eq args.name "--target")
          (if has-target
            (cli_option.cli-args-fail!
              (&mut args)
              "expand: --target was provided more than once")
            (match (target_cfg.compiler-target-cfg-parse
              (cli_option.cli-args-value (& args)))
              [(Ok parsed-target)
                (set! target parsed-target)
                (set! has-target true)]
              [(Err message)
                (cli_option.cli-args-fail!
                  (&mut args)
                  (str_cat.str-cat "expand: " message))]))]
        [(cli_option.cli-flag? args.arg)
          (cli_option.cli-args-fail-arg! (&mut args) "expand: unknown flag ")]
        [has-input
          (cli_option.cli-args-fail-arg!
            (&mut args)
            "expand: unexpected argument ")]
        [else
          (set! input-path (string.copy (& args.arg)))
          (set! has-input true)]))
    (cond
      [args.failed (Err args.error)]
      [(not has-input) (Err "expand: expected a source file")]
      [(not has-position) (Err "expand: --at <line>:<column> is required")]
      [else
        (Ok
          (SelfhostExpandConfig
            input-path
            (/ position 4294967296)
            (% position 4294967296)
            max-bytes
            stdlib-roots
            target
            cfg-names))])))

(define (selfhost-expand-span-text
  [path : String]
  [frame : expand.CompilerExpandFrame]) : String
  (str_cat.str-cat
    path
    ":"
    (string.int->string frame.start-line)
    ":"
    (string.int->string frame.start-col)
    "-"
    (string.int->string frame.end-line)
    ":"
    (string.int->string frame.end-col)))

(define (selfhost-expand-report-diagnostics
  [diagnostics : cdiag.CompilerDiagnosticList]) : unit
  (let
    [count : i64 (cdiag.compiler-diagnostic-list-count diagnostics)]
    [index : i64 0]
    [sources : compiler_driver_core.CompilerDriverDiagnosticSources
      (compiler_driver_core.compiler-driver-diagnostic-sources-new)]
    (while (< index count)
      (io.print-error
        (compiler_driver_core.compiler-driver-render-source-diagnostic-from
          (&mut sources)
          (cdiag.compiler-diagnostic-list-get diagnostics index)))
      (set! index (+ index 1)))))

;: The readable report: the selected invocation, its frames from the outermost
;: invocation inward, and the checked expansion.
(define (selfhost-expand-report
  [path : String]
  [frames : expand.CompilerExpandFrames]
  [text : String]
  [truncated : bool]
  [max-bytes : i64]) : String
  (let
    [count : i64 frames.len]
    [ends-newline? : bool
      (and
        (> (string.string-length (& text)) 0)
        (= (string.char-at (& text) (- (string.string-length (& text)) 1)) '\n'))]
    [selected : expand.CompilerExpandFrame
      (expand.compiler-expand-frame-ref (& frames) (- count 1))]
    [out : String
      (str_cat.str-cat
        "macro: "
        selected.macro-name
        "\ndefined in: "
        selected.module-path
        "\ninvoked at: "
        (selfhost-expand-span-text
          (owned_view.compiler-owned-shared-view path)
          (expand.compiler-expand-frame-ref (& frames) (- count 1)))
        "\nframes:\n")]
    [index : i64 0]
    (while (< index count)
      (let
        [frame : expand.CompilerExpandFrame
          (expand.compiler-expand-frame-ref (& frames) index)]
        (set!
          out
          (str_cat.str-cat
            out
            "  "
            (string.int->string (+ index 1))
            ". "
            frame.macro-name
            " at "
            (selfhost-expand-span-text
              (owned_view.compiler-owned-shared-view path)
              (expand.compiler-expand-frame-ref (& frames) index))
            "\n")))
      (set! index (+ index 1)))
    (str_cat.str-cat
      out
      "expansion:\n"
      text
      (if ends-newline?
        ""
        "\n")
      (if truncated
        (str_cat.str-cat
          "; truncated: the expansion is longer than "
          (string.int->string max-bytes)
          " bytes\n")
        ""))))

(define (selfhost-expand-run [config : SelfhostExpandConfig]) : i64
  (match (io.try-read-file (& config.input-path))
    [(ErrIoBytes error)
      (io.print-error
        (str_cat.str-cat
          "expand: cannot read '"
          config.input-path
          "': "
          (io.error-message error)
          "\n"))
      1]
    [(OkIoBytes contents)
      (match (expand.compiler-expand-source-at
        (owned_view.compiler-owned-shared-view config.input-path)
        (byte_buf.to-string contents)
        (owned_view.compiler-owned-shared-view config.stdlib-roots)
        (target_cfg.compiler-target-cfgs-with-names
          config.target
          (owned_view.compiler-owned-shared-view config.cfg-names))
        config.line
        config.col
        config.max-bytes)
        [(Expanded frames text truncated diagnostics)
          (io.print-format
            "{}"
            (selfhost-expand-report
              (owned_view.compiler-owned-shared-view config.input-path)
              frames
              text
              truncated
              config.max-bytes))
          (if (> (cdiag.compiler-diagnostic-list-count diagnostics) 0)
            (begin
              (selfhost-expand-report-diagnostics diagnostics)
              1)
            0)]
        [(NotFound diagnostics)
          (selfhost-expand-report-diagnostics diagnostics)
          (io.print-error
            (str_cat.str-cat
              "expand: no macro invocation at "
              config.input-path
              ":"
              (string.int->string config.line)
              ":"
              (string.int->string config.col)
              "\n"))
          1]
        [(Failed diagnostics)
          (selfhost-expand-report-diagnostics diagnostics)
          1])]))

(define (selfhost-expand-run-from [start : i64] [count : i64]) : i64
  (match (selfhost-expand-config-from start count)
    [(Ok config) (selfhost-expand-run config)]
    [(Err message)
      (io.print-error (str_cat.str-cat message "\n"))
      1]))