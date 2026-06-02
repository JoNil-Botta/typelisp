;# Narrow Windows registry helpers for SDK/toolchain discovery (#1016).
;#
;# This module intentionally exposes only the registry surface needed by the
;# Windows SDK discovery flow: read the Windows Kits `KitsRoot10` string value
;# and enumerate installed SDK version subkeys. It is not a general registry
;# editor API.
;#
;# Usage: `(import "stdlib/windows_registry.tl")`
;#
;# ```typelisp
;# (import "stdlib/windows_registry.tl")
;# (define install : ResultWindowsRegistrySdkInstall
;#   (windows-registry-sdk-install))
;# ```
;: SDK root/version metadata found under the Windows Kits Installed Roots key.
(defstruct WindowsRegistrySdkInstall
  (root String)
  (version String))

;: Structured registry discovery failures.
(defenum WindowsRegistryError
  (WindowsRegistryUnsupported String)
  (WindowsRegistryUnavailable String)
  (WindowsRegistryQueryFailed String))

;: Result type for the narrow Windows SDK registry probe.
(defenum ResultWindowsRegistrySdkInstall
  (OkWindowsRegistrySdkInstall WindowsRegistrySdkInstall)
  (ErrWindowsRegistrySdkInstall WindowsRegistryError))

;: Backend runtime hook used by `windows-registry-sdk-install`.
;:
;: On Windows targets this calls `RegOpenKeyExW`, `RegQueryValueExW`,
;: `RegEnumKeyExW`, and `RegCloseKey`, converting UTF-16 registry data into
;: freshly allocated TypeLisp UTF-8 strings. On other targets it returns
;: `WindowsRegistryUnsupported`.
(extern tl_windows_sdk_registry_install : (-> ResultWindowsRegistrySdkInstall))

;: Return the SDK root path.
(define (windows-registry-sdk-root [install : WindowsRegistrySdkInstall]) : String
  (struct-get install root))

;: Return the selected SDK version directory name.
(define (windows-registry-sdk-version [install : WindowsRegistrySdkInstall]) : String
  (struct-get install version))

;: Render a registry discovery error as a diagnostic message.
(define (windows-registry-error-message [error : WindowsRegistryError]) : String
  (match error
    [(WindowsRegistryUnsupported message) message]
    [(WindowsRegistryUnavailable message) message]
    [(WindowsRegistryQueryFailed message) message]))

;: Return true when `error` means registry probing is unsupported on this host.
(define (windows-registry-error-unsupported? [error : WindowsRegistryError]) : bool
  (match error
    [(WindowsRegistryUnsupported _) true]
    [_ false]))

;: Return true when the SDK registry key or value is unavailable.
(define (windows-registry-error-unavailable? [error : WindowsRegistryError]) : bool
  (match error
    [(WindowsRegistryUnavailable _) true]
    [_ false]))

;: Return true when the registry APIs returned an unexpected query failure.
(define (windows-registry-error-query-failed? [error : WindowsRegistryError]) : bool
  (match error
    [(WindowsRegistryQueryFailed _) true]
    [_ false]))

;: Probe the Windows Kits Installed Roots registry key for SDK root/version.
(define (windows-registry-sdk-install) : ResultWindowsRegistrySdkInstall
  (tl_windows_sdk_registry_install))