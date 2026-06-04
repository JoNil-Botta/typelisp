(import "stdlib/windows_setup.tl")

(import "stdlib/test.tl")

(define (assert-windows-setup-unsupported
  [result : ResultWindowsSetupInstances]
  [message : String]) : unit
  (match result
    [(ErrWindowsSetupInstances error)
      (begin
        (assert-true (windows-setup-error-unsupported? error) message)
        (assert-string-eq (windows-setup-error-message error) message message))]
    [(OkWindowsSetupInstances _) (panic message)]))

(define (assert-windows-setup-runtime-result
  [result : ResultWindowsSetupInstances]
  [message : String]) : unit
  (match result
    [(OkWindowsSetupInstances instances)
      (assert-true (>= (windows-setup-instance-list-count instances) 0) message)]
    [(ErrWindowsSetupInstances error)
      (begin
        (assert-true
          (or
            (windows-setup-error-unsupported? error)
            (or
              (windows-setup-error-unavailable? error)
              (windows-setup-error-query-failed? error)))
          message)
        (assert-true
          (> (string-length (windows-setup-error-message error)) 0)
          message))]))

(define (assert-windows-setup-error-message
  [error : WindowsSetupError]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (windows-setup-error-message error) expected message))

(define (test-windows-setup-string-list-cons
  [value : String]
  [rest : WindowsSetupStringList]) : WindowsSetupStringList
  (windows-setup-string-list-cons (& value) rest))

(define (test-windows-setup-string-list-contains?
  [items : WindowsSetupStringList]
  [package-id : String]) : bool
  (windows-setup-string-list-contains? items (& package-id)))

(define (test-windows-setup-instance-has-package?
  [instance : WindowsSetupInstance]
  [package-id : String]) : bool
  (windows-setup-instance-has-package? instance (& package-id)))

(define (main) : i64
  (let
    [packages : WindowsSetupStringList
      (test-windows-setup-string-list-cons
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
        (test-windows-setup-string-list-cons
          "Microsoft.VisualStudio.Workload.VCTools"
          (windows-setup-string-list-empty)))]
    [instance : WindowsSetupInstance
      (WindowsSetupInstance
        "C:\\VS\\BuildTools"
        "17.10.0"
        "Visual Studio Build Tools"
        "Microsoft.VisualStudio.Product.BuildTools"
        packages)]
    [instances : WindowsSetupInstanceList
      (windows-setup-instance-list-cons
        instance
        (windows-setup-instance-list-empty))]
    (begin
      (assert-i64-eq
        (windows-setup-string-list-count packages)
        2
        "windows setup package count")
      (assert-true
        (test-windows-setup-string-list-contains?
          packages
          "Microsoft.VisualStudio.Workload.VCTools")
        "windows setup package contains")
      (assert-false
        (test-windows-setup-string-list-contains? packages "missing")
        "windows setup package missing")
      (assert-i64-eq
        (windows-setup-instance-list-count instances)
        1
        "windows setup instance count")
      (assert-string-eq
        (windows-setup-instance-installation-path instance)
        "C:\\VS\\BuildTools"
        "windows setup installation path")
      (assert-string-eq
        (windows-setup-instance-installation-version instance)
        "17.10.0"
        "windows setup installation version")
      (assert-string-eq
        (windows-setup-instance-display-name instance)
        "Visual Studio Build Tools"
        "windows setup display name")
      (assert-string-eq
        (windows-setup-instance-product-id instance)
        "Microsoft.VisualStudio.Product.BuildTools"
        "windows setup product id")
      (assert-true
        (test-windows-setup-instance-has-package?
          instance
          "Microsoft.VisualStudio.Component.VC.Tools.x86.x64")
        "windows setup instance package")
      (assert-true
        (windows-setup-result-success? (OkWindowsSetupInstances instances))
        "windows setup result ok")
      (assert-false
        (windows-setup-result-success?
          (ErrWindowsSetupInstances (WindowsSetupUnavailable "missing")))
        "windows setup result error")
      (assert-windows-setup-error-message
        (WindowsSetupUnavailable "setup unavailable")
        "setup unavailable"
        "windows setup unavailable message")
      (assert-true
        (windows-setup-error-unavailable?
          (WindowsSetupUnavailable "setup unavailable"))
        "windows setup unavailable predicate")
      (assert-true
        (windows-setup-error-query-failed? (WindowsSetupQueryFailed "failed"))
        "windows setup query failed predicate")
      (assert-windows-setup-unsupported
        (ErrWindowsSetupInstances
          (WindowsSetupUnsupported
            "windows setup: SetupConfiguration is only supported on windows-x86_64 targets"))
        "windows setup: SetupConfiguration is only supported on windows-x86_64 targets")
      (assert-windows-setup-runtime-result
        (windows-setup-instances)
        "windows setup runtime result")
      42)))