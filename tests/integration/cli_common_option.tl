(import cli_option_core as cli_option)
(import stdlib.string)

(define (main) : i64
  (match (cli_option.cli-option-lookup
    "--stdlib-root <dir> --cfg <name> --target <target> --opt-level <0|1|2>"
    "--target")
    [(Found name 1)
      (if (string.eq name "--target")
        (match (cli_option.cli-option-lookup "--stdlib-root <dir>" "--target")
          [(None)
            (match (cli_option.cli-option-lookup
              "--debug|-g|--backtrace -o <file>"
              "-g")
              [(Found alias-name 0)
                (if (and
                  (string.eq alias-name "--debug")
                  (string.eq
                    (cli_option.cli-option-missing-value-message
                      "fmt"
                      "--stdlib-root")
                    "fmt: --stdlib-root requires a value"))
                  42
                  1)]
              [_ 4])]
          [_ 2])
        5)]
    [_ 3]))