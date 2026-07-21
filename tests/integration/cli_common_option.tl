(import cli_option_core as cli_option)
(import stdlib.string)

(define (main) : i64
  (match (cli_option.cli-common-option-parse
    "--target"
    0
    1
    cli_option.cli-common-option-all)
    [(cli_option.CliCommonOption.Missing
        (cli_option.CliCommonOptionKind.Target))
      (match (cli_option.cli-common-option-parse
        "--target"
        0
        1
        cli_option.cli-common-option-stdlib-root)
        [(cli_option.CliCommonOption.NotCommon)
          (if (string.eq
            (cli_option.cli-common-option-missing-message
              "fmt"
              (cli_option.CliCommonOptionKind.StdlibRoot))
            "fmt: --stdlib-root requires a value")
            42
            1)]
        [_ 2])]
    [_ 3]))