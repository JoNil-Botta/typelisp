(import "stdlib/test.tl")

(import "stdlib/msvc.tl")

(import "stdlib/process.tl")

(import "stdlib/string.tl")

(import "stdlib/windows_sdk.tl")

(import "stdlib/windows_setup.tl")

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

;; Assert that the current Windows host can discover and run MSVC `link.exe /?`.
(define (assert-link-help-if-windows) : unit
  (if (msvc-host-windows?)
    (match (msvc-find-tool "x86_64-pc-windows-msvc" "link.exe")
      [(OkMsvcTool found)
        (match (process-output
          (process-command-full
            (msvc-tool-executable found)
            (process-args-single "/?")
            (process-no-cwd)
            (msvc-tool-process-env found)
            (process-no-stdin)))
          [(OkProcessOutput output)
            (begin
              (assert-true
                (string-contains (msvc-tool-executable found) "VC\\Tools\\MSVC")
                "msvc link.exe path")
              (assert-true
                (string-contains
                  (process-output-stdout output)
                  "Incremental Linker")
                "link.exe /? output"))]
          [(ErrProcessOutput error) (panic (process-error-message error))])]
      [(ErrMsvcTool error)
        (match error
          [(MsvcSetupUnavailable message)
            (assert-true
              (> (string-length message) 0)
              "msvc setup unavailable has message")]
          [_ (panic (msvc-error-message error))])])
    unit))

;; Assert that the pure path assembly helpers build the expected MSVC layout.
(define (assert-msvc-setup-paths) : unit
  (let
    [packages : WindowsSetupStringList
      (windows-setup-string-list-cons
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
        (windows-setup-string-list-empty))]
    [instance : WindowsSetupInstance
      (WindowsSetupInstance
        "C:\\VS\\BuildTools"
        "17.10.0"
        "Visual Studio Build Tools"
        "Microsoft.VisualStudio.Product.BuildTools"
        packages)]
    [sdk : WindowsSdkLayout
      (WindowsSdkLayout
        "C:\\SDK"
        "10.0.99999.0"
        "C:\\SDK\\Include\\10.0.99999.0\\ucrt"
        "C:\\SDK\\Include\\10.0.99999.0\\um"
        "C:\\SDK\\Include\\10.0.99999.0\\shared"
        "C:\\SDK\\Lib\\10.0.99999.0\\ucrt\\x64"
        "C:\\SDK\\Lib\\10.0.99999.0\\um\\x64"
        "C:\\SDK\\bin\\10.0.99999.0\\x64")]
    [root : String (msvc-toolset-root instance "14.44.35207")]
    (begin
      (assert-string-eq
        root
        "C:\\VS\\BuildTools\\VC\\Tools\\MSVC\\14.44.35207"
        "msvc toolset root")
      (assert-string-eq
        (msvc-toolset-executable root "link.exe")
        "C:\\VS\\BuildTools\\VC\\Tools\\MSVC\\14.44.35207\\bin\\Hostx64\\x64\\link.exe"
        "msvc toolset executable")
      (assert-string-eq
        (msvc-toolset-lib-x64 root)
        "C:\\VS\\BuildTools\\VC\\Tools\\MSVC\\14.44.35207\\lib\\x64"
        "msvc toolset lib")
      (assert-string-eq
        (msvc-toolset-include root)
        "C:\\VS\\BuildTools\\VC\\Tools\\MSVC\\14.44.35207\\include"
        "msvc toolset include")
      (assert-true
        (string-contains
          (msvc-setup-path root sdk)
          "C:\\VS\\BuildTools\\VC\\Tools\\MSVC\\14.44.35207\\bin\\Hostx64\\x64")
        "msvc setup PATH")
      (assert-true
        (string-contains
          (msvc-setup-lib root sdk)
          "C:\\SDK\\Lib\\10.0.99999.0\\ucrt\\x64")
        "msvc setup LIB")
      (assert-true
        (string-contains
          (msvc-setup-include root sdk)
          "C:\\SDK\\Include\\10.0.99999.0\\shared")
        "msvc setup INCLUDE"))))

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
      (assert-i64-eq
        (process-env-count (msvc-tool-process-env tool))
        3
        "msvc process env count")
      (assert-true
        (msvc-version-greater? "17.10.0" "17.9.9")
        "msvc version numeric compare")
      (assert-false
        (msvc-version-greater? "17.9.9" "17.10.0")
        "msvc version numeric compare inverse")
      (assert-false
        (msvc-version-greater? "17.10.0" "17.10.0")
        "msvc version equal compare")
      (assert-msvc-setup-paths)
      (if (msvc-host-windows?)
        unit
        (assert-unsupported
          (msvc-find-tool-from-setup "x86_64-pc-windows-msvc" "link.exe")
          "msvc setup unsupported host"))
      ;; An unsupported target yields `MsvcUnsupported` on every host: a
      ;; non-Windows host rejects first, a Windows host rejects the target.
      (assert-unsupported
        (msvc-find-tool "x86_64-unknown-linux-gnu" "link.exe")
        "msvc unsupported target or non-Windows host")
      (assert-link-help-if-windows)
      42)))