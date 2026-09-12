;; Synthetic verifier failures exercise the CLI handoff without relying on an
;; optimizer bug to produce invalid IR. The companion shell check asserts the
;; exact stderr order, single emission, and absence of published artifacts.
(import compile_cli_core as cli)
(import compiler_driver_core as driver)
(import compiler_windows_coff_core as windows)
(import compiler_backend as backend)
(import compiler_diagnostic as diag)
(import stdlib.io)
(import stdlib.string)
(import stdlib.text_buf)

(define (advisories [first : String] [second : String]) : diag.CompilerAdvisoryList
  (let
    [items : diag.CompilerAdvisoryList (diag.compiler-advisory-list-empty)]
    (begin
      (if (string.eq first "")
        unit
        (diag.compiler-advisory-list-push!
          (&mut items)
          (diag.CompilerAdvisoryPhase.Semantic)
          (diag.compiler-diagnostic-at-start "" first)))
      (if (string.eq second "")
        unit
        (diag.compiler-advisory-list-push!
          (&mut items)
          (diag.CompilerAdvisoryPhase.Backend)
          (diag.compiler-diagnostic-at-start "" second)))
      items)))

(define (windows-rejected? [result : cli.ResultCompileCliWindowsBatchEntry]) : bool
  (match result
    [(cli.ResultCompileCliWindowsBatchEntry.Err status) (= status 1)]
    [(cli.ResultCompileCliWindowsBatchEntry.Ok _ _ _) false]))

(define (main) : i64
  (let
    [driver-ok : i64
      (cli.compile-cli-reject-result-on-ir-verification
        (driver.ResultCompilerDriver.Ok
          "unused"
          (advisories "driver-first" "driver-second"))
        "verify-driver-ok")]
    [driver-err : i64
      (cli.compile-cli-reject-result-on-ir-verification
        (driver.ResultCompilerDriver.Err
          (box (diag.compiler-diagnostic-at-start "" "discarded-driver-fatal"))
          (advisories "driver-err" ""))
        "verify-driver-err")]
    [buffer-ok : i64
      (cli.compile-cli-reject-buffer-result-on-ir-verification
        (driver.ResultCompilerDriverBuffer.Ok
          (text_buf.empty)
          (advisories "buffer-ok" ""))
        "verify-buffer-ok")]
    [buffer-err : i64
      (cli.compile-cli-reject-buffer-result-on-ir-verification
        (driver.ResultCompilerDriverBuffer.Err
          (box (diag.compiler-diagnostic-at-start "" "discarded-buffer-fatal"))
          (advisories "buffer-err" ""))
        "verify-buffer-err")]
    [pic-ok : i64
      (cli.compile-cli-reject-pic-result-on-ir-verification
        (driver.ResultCompilerDriverPic.Ok
          (backend.CompilerBackendPicOutput "unused" "unused")
          (advisories "pic-ok" ""))
        "verify-pic-ok")]
    [pic-err : i64
      (cli.compile-cli-reject-pic-result-on-ir-verification
        (driver.ResultCompilerDriverPic.Err
          (box (diag.compiler-diagnostic-at-start "" "discarded-pic-fatal"))
          (advisories "pic-err" ""))
        "verify-pic-err")]
    [coff-ok : bool
      (windows-rejected?
        (cli.compile-cli-reject-windows-batch-artifact-on-ir-verification
          (windows.ResultCompilerWindowsBatchArtifact.CoffObject
            "unused"
            (windows.CompilerWindowsBatchSideAssembly.None)
            (advisories "coff-first" "coff-second"))
          "verify-coff"))]
    [assembly-ok : bool
      (windows-rejected?
        (cli.compile-cli-reject-windows-batch-artifact-on-ir-verification
          (windows.ResultCompilerWindowsBatchArtifact.Assembly
            (text_buf.empty)
            backend.CompilerDirectObjectFallbackReason.ForcedAssembly
            (advisories "assembly" ""))
          "verify-assembly"))]
    [windows-err : bool
      (windows-rejected?
        (cli.compile-cli-reject-windows-batch-artifact-on-ir-verification
          (windows.ResultCompilerWindowsBatchArtifact.Err
            (box (diag.compiler-diagnostic-at-start "" "discarded-coff-fatal"))
            (advisories "windows-err" ""))
          "verify-windows-err"))]
    ;; A later job with no advisories must not inherit the preceding payload.
    [empty-later-job : i64
      (cli.compile-cli-reject-result-on-ir-verification
        (driver.ResultCompilerDriver.Ok "unused" (advisories "" ""))
        "verify-empty-later-job")]
    (if (and
      (= driver-ok 1)
      (= driver-err 1)
      (= buffer-ok 1)
      (= buffer-err 1)
      (= pic-ok 1)
      (= pic-err 1)
      coff-ok
      assembly-ok
      windows-err
      (= empty-later-job 1))
      0
      (begin
        (io.print-error "wrong verifier rejection status\n")
        1))))