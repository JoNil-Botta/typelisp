(import "stdlib/env.tl")

(import "stdlib/test.tl")

(import "stdlib/windows_sdk.tl")

(define (assert-windows-sdk-ok [result : ResultWindowsSdkLayout]) : WindowsSdkLayout
  (match result
    [(OkWindowsSdkLayout layout) layout]
    [(ErrWindowsSdkLayout error) (panic (windows-sdk-error-message error))]))

(define (assert-windows-sdk-error-message
  [result : ResultWindowsSdkLayout]
  [expected : String]
  [message : String]) : unit
  (match result
    [(ErrWindowsSdkLayout error)
      (assert-string-eq (windows-sdk-error-message error) expected message)]
    [(OkWindowsSdkLayout _) (panic message)]))

(define (main) : i64
  (let
    [layout : WindowsSdkLayout
      (assert-windows-sdk-ok (windows-sdk-discover-from-env))]
    [root : String (env-var-value "WindowsSdkDir")]
    (begin
      (assert-string-eq (windows-sdk-root layout) root "sdk root")
      (assert-string-eq
        (windows-sdk-version layout)
        "10.0.99999.0"
        "sdk version")
      (assert-string-eq
        (windows-sdk-include-ucrt layout)
        (windows-sdk-path-join4 root "Include" "10.0.99999.0" "ucrt")
        "sdk include ucrt")
      (assert-string-eq
        (windows-sdk-include-um layout)
        (windows-sdk-path-join4 root "Include" "10.0.99999.0" "um")
        "sdk include um")
      (assert-string-eq
        (windows-sdk-include-shared layout)
        (windows-sdk-path-join4 root "Include" "10.0.99999.0" "shared")
        "sdk include shared")
      (assert-string-eq
        (windows-sdk-lib-ucrt-x64 layout)
        (windows-sdk-path-join5 root "Lib" "10.0.99999.0" "ucrt" "x64")
        "sdk lib ucrt")
      (assert-string-eq
        (windows-sdk-lib-um-x64 layout)
        (windows-sdk-path-join5 root "Lib" "10.0.99999.0" "um" "x64")
        "sdk lib um")
      (assert-string-eq
        (windows-sdk-bin-x64 layout)
        (windows-sdk-path-join4 root "bin" "10.0.99999.0" "x64")
        "sdk bin")
      (assert-windows-sdk-error-message
        (windows-sdk-layout-from-root-version-checked
          (windows-sdk-path-join2 root "missing")
          "10.0.99999.0")
        (string-append
          "windows-sdk: missing SDK path: "
          (windows-sdk-path-join2 root "missing"))
        "sdk invalid layout")
      (if (windows-sdk-host-windows?)
        unit
        (assert-windows-sdk-error-message
          (windows-sdk-discover)
          "windows-sdk: unsupported on non-Windows hosts"
          "sdk unsupported host"))
      42)))