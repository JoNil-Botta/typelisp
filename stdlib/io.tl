;; stdlib/io.tl - File I/O utility library for TypeLisp (#702).

;;

;; Provides higher-level file helpers built on the compiler/runtime file

;; primitives, mirroring how stdlib/string.tl wraps the string primitives.

;;

;; Primitives required from the compiler/runtime:

;;

;;   read-file, write-file, file-exists?, string-append, string-length

;;

;; All helpers inherit the V1 panic-on-error semantics of the underlying

;; primitives (e.g. read-file panics on a missing path); recoverable file-error

;; handling is deferred until the Result/Option model is settled.

;;

;; Usage: (import "stdlib/io.tl")

;; Read the contents of `path` if it exists, otherwise return `fallback`.

;; A non-panicking read for optional files: `read-file` itself panics when the

;; path is missing, so guard it with `file-exists?` first.

(define (read-file-or [path : String] [fallback : String]) : String
  (if (file-exists? path)
    (read-file path)
    fallback))

;; Append `contents` to the file at `path`, creating it when absent.

;; Implemented as a read-modify-write because there is no append primitive, so

;; it is not atomic and rewrites the whole file.

(define (append-file [path : String] [contents : String]) : unit
  (write-file path (string-append (read-file-or path "") contents)))

;; Return true when `path` exists and its contents are non-empty.

;; `read-file` is guarded behind an `if` (not `and`) so it is only called when

;; the file exists: `and` evaluates both operands, which would panic `read-file`

;; on a missing path.

(define (file-nonempty? [path : String]) : bool
  (if (file-exists? path)
    (> (string-length (read-file path)) 0)
    false))