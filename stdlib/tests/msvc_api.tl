(import "stdlib/test.tl")

(import "stdlib/msvc.tl")

(import "stdlib/process.tl")

(import "stdlib/string.tl")

(import "stdlib/windows_sdk.tl")

(import "stdlib/windows_setup.tl")

(define (test-windows-setup-string-list-cons
  [value : String]
  [rest : WindowsSetupStringList]) : WindowsSetupStringList
  (windows-setup-string-list-cons (& value) rest))

(define (test-msvc-find-tool [target : String] [tool : String]) : ResultMsvcTool
  (msvc-find-tool (& target) (& tool)))

(define (test-msvc-find-tool-from-setup [target : String] [tool : String]) : ResultMsvcTool
  (msvc-find-tool-from-setup (& target) (& tool)))

(define (test-msvc-supported-target? [target : String]) : bool
  (msvc-supported-target? (& target)))

(define (test-msvc-version-greater? [left : String] [right : String]) : bool
  (msvc-version-greater? (& left) (& right)))

(define (test-msvc-toolset-root
  [instance : WindowsSetupInstance]
  [version : String]) : String
  (msvc-toolset-root instance (& version)))

(define (test-msvc-toolset-executable [toolset-root : String] [tool : String]) : String
  (msvc-toolset-executable (& toolset-root) (& tool)))

(define (test-msvc-toolset-lib-x64 [toolset-root : String]) : String
  (msvc-toolset-lib-x64 (& toolset-root)))

(define (test-msvc-toolset-include [toolset-root : String]) : String
  (msvc-toolset-include (& toolset-root)))

(define (test-msvc-setup-path [toolset-root : String] [sdk : WindowsSdkLayout]) : String
  (msvc-setup-path (& toolset-root) sdk))

(define (test-msvc-setup-lib [toolset-root : String] [sdk : WindowsSdkLayout]) : String
  (msvc-setup-lib (& toolset-root) sdk))

(define (test-msvc-setup-include
  [toolset-root : String]
  [sdk : WindowsSdkLayout]) : String
  (msvc-setup-include (& toolset-root) sdk))

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

(define (msvc-test-contains [haystack : String] [needle : String]) : bool
  (string-contains (& haystack) (& needle)))

;; Assert that the current Windows host can discover and run MSVC `link.exe /?`.
(define (assert-link-help-if-windows) : unit
  (if (msvc-host-windows?)
    (match (test-msvc-find-tool "x86_64-pc-windows-msvc" "link.exe")
      [(OkMsvcTool found)
        (match (process-output
          (process-command-full
            (msvc-tool-executable found)
            (process-args-single "/?")
            (process-no-cwd)
            (msvc-tool-process-env found)
            (process-no-stdin)))
          [(OkProcessOutput output)
            (let
              [executable : String (msvc-tool-executable found)]
              [path-needle : String "VC\\Tools\\MSVC"]
              [stdout : String (process-output-stdout output)]
              [stdout-needle : String "Incremental Linker"]
              (begin
                (assert-true
                  (msvc-test-contains executable path-needle)
                  "msvc link.exe path")
                (assert-true
                  (msvc-test-contains stdout stdout-needle)
                  "link.exe /? output")))]
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
      (test-windows-setup-string-list-cons
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
    [root : String (test-msvc-toolset-root instance "14.44.35207")]
    [setup-path : String (test-msvc-setup-path root sdk)]
    [setup-lib : String (test-msvc-setup-lib root sdk)]
    [setup-include : String (test-msvc-setup-include root sdk)]
    [path-needle : String
      "C:\\VS\\BuildTools\\VC\\Tools\\MSVC\\14.44.35207\\bin\\Hostx64\\x64"]
    [lib-needle : String "C:\\SDK\\Lib\\10.0.99999.0\\ucrt\\x64"]
    [include-needle : String "C:\\SDK\\Include\\10.0.99999.0\\shared"]
    (begin
      (assert-string-eq
        root
        "C:\\VS\\BuildTools\\VC\\Tools\\MSVC\\14.44.35207"
        "msvc toolset root")
      (assert-string-eq
        (test-msvc-toolset-executable root "link.exe")
        "C:\\VS\\BuildTools\\VC\\Tools\\MSVC\\14.44.35207\\bin\\Hostx64\\x64\\link.exe"
        "msvc toolset executable")
      (assert-string-eq
        (test-msvc-toolset-lib-x64 root)
        "C:\\VS\\BuildTools\\VC\\Tools\\MSVC\\14.44.35207\\lib\\x64"
        "msvc toolset lib")
      (assert-string-eq
        (test-msvc-toolset-include root)
        "C:\\VS\\BuildTools\\VC\\Tools\\MSVC\\14.44.35207\\include"
        "msvc toolset include")
      (assert-true
        (msvc-test-contains setup-path path-needle)
        "msvc setup PATH")
      (assert-true (msvc-test-contains setup-lib lib-needle) "msvc setup LIB")
      (assert-true
        (msvc-test-contains setup-include include-needle)
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
        (test-msvc-supported-target? "x86_64-pc-windows-msvc")
        "msvc supported target")
      (assert-false
        (test-msvc-supported-target? "x86_64-unknown-linux-gnu")
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
        (test-msvc-version-greater? "17.10.0" "17.9.9")
        "msvc version numeric compare")
      (assert-false
        (test-msvc-version-greater? "17.9.9" "17.10.0")
        "msvc version numeric compare inverse")
      (assert-false
        (test-msvc-version-greater? "17.10.0" "17.10.0")
        "msvc version equal compare")
      (assert-msvc-setup-paths)
      (if (msvc-host-windows?)
        unit
        (assert-unsupported
          (test-msvc-find-tool-from-setup "x86_64-pc-windows-msvc" "link.exe")
          "msvc setup unsupported host"))
      ;; An unsupported target yields `MsvcUnsupported` on every host: a
      ;; non-Windows host rejects first, a Windows host rejects the target.
      (assert-unsupported
        (test-msvc-find-tool "x86_64-unknown-linux-gnu" "link.exe")
        "msvc unsupported target or non-Windows host")
      (assert-link-help-if-windows)
      42)))