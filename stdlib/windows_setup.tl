;# Visual Studio SetupConfiguration discovery model (#1015).
;#
;# Defines the TypeLisp stdlib data model for enumerating Visual Studio /
;# Build Tools instances through the Windows SetupConfiguration API. The
;# backend runtime hook returns structured diagnostics on unsupported hosts or
;# COM failures, and returns instance metadata on Windows when
;# SetupConfiguration is available.
;#
;# Usage: `(import "stdlib/windows_setup.tl")`
;#
;# ```typelisp
;# (import "stdlib/windows_setup.tl")
;# (define empty-count : i64
;#   (windows-setup-instance-list-count (WindowsSetupInstanceNil)))
;# ```
(import "string.tl")

;: Immutable list of SetupConfiguration package/component identifiers.
(defenum WindowsSetupStringList
  (WindowsSetupStringNil)
  (WindowsSetupStringCons String (Box WindowsSetupStringList)))

;: Visual Studio / Build Tools instance metadata returned by setup discovery.
(defstruct WindowsSetupInstance
  (installation-path String)
  (installation-version String)
  (display-name String)
  (product-id String)
  (package-ids WindowsSetupStringList))

;: Immutable list of Visual Studio / Build Tools instances.
(defenum WindowsSetupInstanceList
  (WindowsSetupInstanceNil)
  (WindowsSetupInstanceCons WindowsSetupInstance (Box WindowsSetupInstanceList)))

;: Structured setup discovery failures.
(defenum WindowsSetupError
  (WindowsSetupUnsupported String)
  (WindowsSetupUnavailable String)
  (WindowsSetupQueryFailed String))

;: Result type for SetupConfiguration instance enumeration.
(defenum ResultWindowsSetupInstances
  (OkWindowsSetupInstances WindowsSetupInstanceList)
  (ErrWindowsSetupInstances WindowsSetupError))

;: Backend runtime hook used by `windows-setup-instances`.
(extern tl_windows_setup_instances : (-> ResultWindowsSetupInstances))

;: Copy a borrowed setup string into an owned active-arena `String`.
(define (windows-setup-copy-string [value : (& value str)]) : String
  (string-copy-borrowed value))

;: Return an empty package/component identifier list.
(define (windows-setup-string-list-empty) : WindowsSetupStringList
  (WindowsSetupStringNil))

;: Prepend a package/component identifier to a list.
(define (windows-setup-string-list-cons
  [value : (& value str)]
  [rest : WindowsSetupStringList]) : WindowsSetupStringList
  (WindowsSetupStringCons (windows-setup-copy-string value) (box rest)))

;: Return the number of strings in `items`.
(define (windows-setup-string-list-count [items : WindowsSetupStringList]) : i64
  (match items
    [(WindowsSetupStringNil) 0]
    [(WindowsSetupStringCons _ rest)
      (+ 1 (windows-setup-string-list-count (box-get rest)))]))

;: Return true when `items` contains `value`.
(define (windows-setup-string-list-contains?
  [items : WindowsSetupStringList]
  [package-id : (& package-id str)]) : bool
  (match items
    [(WindowsSetupStringNil) false]
    [(WindowsSetupStringCons head rest)
      (if (string-eq-borrowed (& head) package-id)
        true
        (windows-setup-string-list-contains? (box-get rest) package-id))]))

;: Return an empty Visual Studio instance list.
(define (windows-setup-instance-list-empty) : WindowsSetupInstanceList
  (WindowsSetupInstanceNil))

;: Prepend a Visual Studio instance to a list.
(define (windows-setup-instance-list-cons
  [instance : WindowsSetupInstance]
  [rest : WindowsSetupInstanceList]) : WindowsSetupInstanceList
  (WindowsSetupInstanceCons instance (box rest)))

;: Return the number of instances in `instances`.
(define (windows-setup-instance-list-count
  [instances : WindowsSetupInstanceList]) : i64
  (match instances
    [(WindowsSetupInstanceNil) 0]
    [(WindowsSetupInstanceCons _ rest)
      (+ 1 (windows-setup-instance-list-count (box-get rest)))]))

;: Return an instance's installation path.
(define (windows-setup-instance-installation-path
  [instance : WindowsSetupInstance]) : String
  (struct-get instance installation-path))

;: Return an instance's installation version string.
(define (windows-setup-instance-installation-version
  [instance : WindowsSetupInstance]) : String
  (struct-get instance installation-version))

;: Return an instance's display name.
(define (windows-setup-instance-display-name [instance : WindowsSetupInstance]) : String
  (struct-get instance display-name))

;: Return an instance's product identifier.
(define (windows-setup-instance-product-id [instance : WindowsSetupInstance]) : String
  (struct-get instance product-id))

;: Return an instance's package/component identifier list.
(define (windows-setup-instance-package-ids [instance : WindowsSetupInstance]) : WindowsSetupStringList
  (struct-get instance package-ids))

;: Return true when `instance` reports `package-id`.
(define (windows-setup-instance-has-package?
  [instance : WindowsSetupInstance]
  [package-id : (& package-id str)]) : bool
  (windows-setup-string-list-contains?
    (windows-setup-instance-package-ids instance)
    package-id))

;: Return the diagnostic message stored in `error`.
(define (windows-setup-error-message [error : WindowsSetupError]) : String
  (match error
    [(WindowsSetupUnsupported message) message]
    [(WindowsSetupUnavailable message) message]
    [(WindowsSetupQueryFailed message) message]))

;: Return true when `error` means setup discovery is unsupported.
(define (windows-setup-error-unsupported? [error : WindowsSetupError]) : bool
  (match error
    [(WindowsSetupUnsupported _) true]
    [_ false]))

;: Return true when SetupConfiguration is unavailable on the host.
(define (windows-setup-error-unavailable? [error : WindowsSetupError]) : bool
  (match error
    [(WindowsSetupUnavailable _) true]
    [_ false]))

;: Return true when SetupConfiguration returned an unexpected query failure.
(define (windows-setup-error-query-failed? [error : WindowsSetupError]) : bool
  (match error
    [(WindowsSetupQueryFailed _) true]
    [_ false]))

;: Return true when setup discovery returned an instance list.
(define (windows-setup-result-success? [result : ResultWindowsSetupInstances]) : bool
  (match result
    [(OkWindowsSetupInstances _) true]
    [(ErrWindowsSetupInstances _) false]))

;: Enumerate Visual Studio / Build Tools instances.
(define (windows-setup-instances) : ResultWindowsSetupInstances
  (tl_windows_setup_instances))