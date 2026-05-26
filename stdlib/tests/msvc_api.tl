(import "stdlib/test.tl")

(import "stdlib/msvc.tl")

;; Assert that a discovery result is the `MsvcUnsupported` error variant.
(define (assert-unsupported [result : ResultMsvcTool] [message : String]) : unit
  (match result
    [(ErrMsvcTool error)
      (match error
        [(MsvcUnsupported _) unit]
        [(MsvcMissingEnvironment _) (panic message)]
        [(MsvcToolNotFound _) (panic message)]
        [(MsvcSetupUnavailable _) (panic message)])]
    [(OkMsvcTool _) (panic message)]))

;; Assert that a discovery result is the `MsvcSetupUnavailable` error variant.
(define (assert-setup-unavailable [result : ResultMsvcTool] [message : String]) : unit
  (match result
    [(ErrMsvcTool error)
      (match error
        [(MsvcSetupUnavailable _) unit]
        [(MsvcUnsupported _) (panic message)]
        [(MsvcMissingEnvironment _) (panic message)]
        [(MsvcToolNotFound _) (panic message)])]
    [(OkMsvcTool _) (panic message)]))

(define (main) : i64
  (let
    [tool : MsvcTool
      (MsvcTool "C:\\bin\\link.exe" "C:\\bin" "C:\\lib" "C:\\inc")]
    (begin
      (assert-string-eq
        (msvc-tool-executable tool)
        "C:\\bin\\link.exe"
        "msvc tool executable")
      (assert-string-eq (msvc-tool-path tool) "C:\\bin" "msvc tool path")
      (assert-string-eq (msvc-tool-lib tool) "C:\\lib" "msvc tool lib")
      (assert-string-eq (msvc-tool-include tool) "C:\\inc" "msvc tool include")
      (assert-true
        (msvc-supported-target? "x86_64-pc-windows-msvc")
        "msvc supported target")
      (assert-false
        (msvc-supported-target? "x86_64-unknown-linux-gnu")
        "msvc unsupported target")
      (assert-string-eq
        (msvc-error-message (MsvcUnsupported "u"))
        "u"
        "render unsupported")
      (assert-string-eq
        (msvc-error-message (MsvcMissingEnvironment "m"))
        "m"
        "render missing-environment")
      (assert-string-eq
        (msvc-error-message (MsvcToolNotFound "n"))
        "n"
        "render tool-not-found")
      (assert-string-eq
        (msvc-error-message (MsvcSetupUnavailable "s"))
        "s"
        "render setup-unavailable")
      (assert-setup-unavailable
        (msvc-find-tool-from-setup "x86_64-pc-windows-msvc" "link.exe")
        "msvc setup enumeration is stubbed")
      ;; An unsupported target yields `MsvcUnsupported` on every host: a
      ;; non-Windows host rejects first, a Windows host rejects the target.
      (assert-unsupported
        (msvc-find-tool "x86_64-unknown-linux-gnu" "link.exe")
        "msvc unsupported target or non-Windows host")
      42)))