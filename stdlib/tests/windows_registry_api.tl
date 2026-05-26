(import "stdlib/test.tl")

(import "stdlib/windows_registry.tl")

(import "stdlib/windows_sdk.tl")

(define (assert-windows-registry-error-message
  [result : ResultWindowsRegistrySdkInstall]
  [expected : String]
  [message : String]) : unit
  (match result
    [(ErrWindowsRegistrySdkInstall error)
      (assert-string-eq (windows-registry-error-message error) expected message)]
    [(OkWindowsRegistrySdkInstall _) (panic message)]))

(define (assert-windows-sdk-registry-ok [result : ResultWindowsSdkLayout]) : WindowsSdkLayout
  (match result
    [(OkWindowsSdkLayout layout) layout]
    [(ErrWindowsSdkLayout error) (panic (windows-sdk-error-message error))]))

(define (assert-non-empty [value : String] [message : String]) : unit
  (assert-true (> (string-length value) 0) message))

(define (main) : i64
  (if (windows-sdk-host-windows?)
    (let
      [layout : WindowsSdkLayout
        (assert-windows-sdk-registry-ok (windows-sdk-discover-from-registry))]
      (begin
        (assert-non-empty (windows-sdk-root layout) "registry sdk root")
        (assert-non-empty (windows-sdk-version layout) "registry sdk version")
        (assert-non-empty
          (windows-sdk-include-ucrt layout)
          "registry sdk include ucrt")
        (assert-non-empty
          (windows-sdk-lib-ucrt-x64 layout)
          "registry sdk lib ucrt")
        42))
    (begin
      (assert-windows-registry-error-message
        (windows-registry-sdk-install)
        "windows registry: unsupported on non-Windows targets"
        "registry unsupported host")
      42)))