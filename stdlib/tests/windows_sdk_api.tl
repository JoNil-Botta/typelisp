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

(define (test-windows-sdk-path-join2 [left : String] [right : String]) : String
  (windows-sdk-path-join2 (& left) (& right)))

(define (test-windows-sdk-path-join4
  [a : String]
  [b : String]
  [c : String]
  [d : String]) : String
  (windows-sdk-path-join4 (& a) (& b) (& c) (& d)))

(define (test-windows-sdk-path-join5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (windows-sdk-path-join5 (& a) (& b) (& c) (& d) (& e)))

(define (test-windows-sdk-layout-from-root-version-checked
  [root : String]
  [version : String]) : ResultWindowsSdkLayout
  (windows-sdk-layout-from-root-version-checked (& root) (& version)))

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
        (test-windows-sdk-path-join4 root "Include" "10.0.99999.0" "ucrt")
        "sdk include ucrt")
      (assert-string-eq
        (windows-sdk-include-um layout)
        (test-windows-sdk-path-join4 root "Include" "10.0.99999.0" "um")
        "sdk include um")
      (assert-string-eq
        (windows-sdk-include-shared layout)
        (test-windows-sdk-path-join4 root "Include" "10.0.99999.0" "shared")
        "sdk include shared")
      (assert-string-eq
        (windows-sdk-lib-ucrt-x64 layout)
        (test-windows-sdk-path-join5 root "Lib" "10.0.99999.0" "ucrt" "x64")
        "sdk lib ucrt")
      (assert-string-eq
        (windows-sdk-lib-um-x64 layout)
        (test-windows-sdk-path-join5 root "Lib" "10.0.99999.0" "um" "x64")
        "sdk lib um")
      (assert-string-eq
        (windows-sdk-bin-x64 layout)
        (test-windows-sdk-path-join4 root "bin" "10.0.99999.0" "x64")
        "sdk bin")
      (assert-windows-sdk-error-message
        (test-windows-sdk-layout-from-root-version-checked
          (test-windows-sdk-path-join2 root "missing")
          "10.0.99999.0")
        (string-append
          "windows-sdk: missing SDK path: "
          (test-windows-sdk-path-join2 root "missing"))
        "sdk invalid layout")
      (if (windows-sdk-host-windows?)
        unit
        (assert-windows-sdk-error-message
          (windows-sdk-discover)
          "windows-sdk: unsupported on non-Windows hosts"
          "sdk unsupported host"))
      42)))