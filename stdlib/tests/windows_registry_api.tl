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

(define (assert-windows-sdk-registry-error-structured [error : WindowsSdkError]) : unit
  (match error
    [(WindowsSdkRegistryUnavailable message)
      (assert-true (> (string-length message) 0) "registry unavailable message")]
    [(WindowsSdkInvalidLayout message)
      (assert-true
        (> (string-length message) 0)
        "registry invalid layout message")]
    [_ (panic (windows-sdk-error-message error))]))

(define (assert-non-empty [value : String] [message : String]) : unit
  (assert-true (> (string-length value) 0) message))

(define (main) : i64
  (if (windows-sdk-host-windows?)
    (match (windows-sdk-discover-from-registry)
      [(OkWindowsSdkLayout layout)
        (begin
          (assert-non-empty (windows-sdk-root layout) "registry sdk root")
          (assert-non-empty (windows-sdk-version layout) "registry sdk version")
          (assert-non-empty
            (windows-sdk-include-ucrt layout)
            "registry sdk include ucrt")
          (assert-non-empty
            (windows-sdk-lib-ucrt-x64 layout)
            "registry sdk lib ucrt")
          42)]
      [(ErrWindowsSdkLayout error)
        (begin
          (assert-windows-sdk-registry-error-structured error)
          42)])
    (begin
      (assert-windows-registry-error-message
        (windows-registry-sdk-install)
        "windows registry: unsupported on non-Windows targets"
        "registry unsupported host")
      42)))