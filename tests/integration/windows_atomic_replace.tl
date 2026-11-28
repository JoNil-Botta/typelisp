(cfg windows (import stdlib.byte_buf))
(cfg windows (import stdlib.fs))
(cfg windows (import stdlib.io))
(cfg windows (import stdlib.str_cat))
(cfg windows (import stdlib.string))
(cfg windows (import stdlib.test))

(cfg windows (extern (get-acp) : u32 (:symbol "GetACP")))

(cfg
  windows
  (unsafe
    (extern (set-file-attributes [path : (Ptr u8)] [attributes : u32]) : i32 (:symbol "SetFileAttributesA"))))

(cfg
  windows
  (define (write-text [path : (& str)] [text : (& str)]) : unit
    (test.assert-i64-eq
      (io.write-file-status path (byte_buf.str-as-bytes text))
      0
      "write fixture file")))

(cfg
  windows
  (define (check-text [path : (& str)] [expected : (& str)]) : unit
    (match (io.try-read-file path)
      [(OkIoBytes bytes)
        (test.assert-string-eq
          (byte_buf.to-string bytes)
          expected
          "named file bytes")]
      [(ErrIoBytes error) (io.panic (io.error-message error))])))

(cfg
  windows
  (define (replace-status [source : (& str)] [destination : (& str)]) : i64
    (match (fs.try-atomic-replace source destination)
      [(OkIoUnit) 0]
      [(ErrIoUnit (IoPermissionDenied _)) 5]
      [(ErrIoUnit (IoNotFound _)) 2]
      [(ErrIoUnit (IoInvalidPath _)) 87]
      [(ErrIoUnit (IoSystemCode code _)) code]
      [(ErrIoUnit error) (io.panic (io.error-message error))])))

(cfg
  windows
  (define (legacy-status [source : (& str)] [destination : (& str)]) : i64
    (let
      [from : (__tl_dyn-array u8) (io.c-string source)]
      [to : (__tl_dyn-array u8) (io.c-string destination)]
      (unsafe
        (if (=
          (fs.fs-win-move-file-ex
            (io.array-const-ptr from)
            (io.array-const-ptr to)
            9)
          0)
          (cast (fs.fs-win-get-last-error) : i64)
          0)))))

(cfg
  windows
  (define (set-attributes [path : (& str)] [attributes : u32]) : unit
    (let
      [bytes : (__tl_dyn-array u8) (io.c-string path)]
      [result : i32
        (unsafe
          (set-file-attributes (io.array-const-ptr bytes) attributes))]
      (test.assert-i64-eq (cast result : i64) 1 "set fixture file attributes"))))

(cfg
  windows
  (define (open-reader [path : (& str)] [sharing : i64]) : i64
    (let
      [bytes : (__tl_dyn-array u8) (io.c-string path)]
      (unsafe
        (fs.fs-win-create-file
          (io.array-const-ptr bytes)
          0x80000000
          sharing
          0
          3
          0x80
          0)))))

(cfg
  windows
  (define (check-old-native-reader [reader : i64]) : unit
    (let
      [bytes : (Array u8 4) (make-array u8 4)]
      [count : i32 0]
      [result : i32
        (unsafe
          (io.io-win-read-file
            reader
            (ptr-addr-of (array-ref bytes 0))
            4
            (ptr-addr-of count)
            0))]
      [closed : i32
        (unsafe
          (fs.fs-win-close-handle reader))]
      (test.assert-i64-eq (cast closed : i64) 1 "close native reader")
      (test.assert-i64-eq
        (cast result : i64)
        1
        "read from original native handle")
      (test.assert-i64-eq
        (cast count : i64)
        3
        "original native handle byte count")
      (test.assert-string-eq
        (unsafe
          (string-from-bytes (ptr-addr-of (array-ref bytes 0)) 3))
        "old"
        "original native handle bytes"))))

(cfg
  windows
  (define (check-public-reader-replacement
    [source : (& str)]
    [destination : (& str)]) : unit
    (match (io.file-open destination (OpenRead))
      [(ErrIoFile error) (io.panic (io.error-message error))]
      [(OkIoFile reader)
        (let
          [status : i64 (replace-status source destination)]
          [result : io.ResultIoRead (io.file-read-chunk reader 32)]
          (when
            (= status 0)
            (check-text destination "new payload")
            (test.assert-true
              (not (io.file-exists? (string.copy source)))
              "stage disappeared while old handle is live"))
          (let
            [closed : io.ResultIoUnit (io.file-close reader)]
            (test.assert-i64-eq
              status
              0
              "public replacement with a live public reader")
            (test.assert-true (io.result-unit-ok? closed) "close public reader")
            (match result
              [(OkIoRead read)
                (test.assert-string-eq
                  (byte_buf.to-string (io.file-read-bytes read))
                  "old"
                  "original public handle bytes")]
              [(ErrIoRead error) (io.panic (io.error-message error))])))])))

;; Run the measured legacy and production controls with the same setup.
(cfg
  windows
  (define (check-control
    [source : (& str)]
    [destination : (& str)]
    [legacy : bool]
    [sharing : i64]
    [readonly : bool]
    [expected : i64]) : unit
    (write-text source "new payload")
    (write-text destination "old")
    (when readonly (set-attributes destination (cast 1 : u32)))
    (if (and (not legacy) (= sharing 7))
      (check-public-reader-replacement source destination)
      (let
        [reader : i64
          (if (= sharing 0)
            0
            (open-reader destination sharing))]
        (test.assert-true (not (= reader -1)) "open native reader")
        (let
          [status : i64
            (if legacy
              (legacy-status source destination)
              (replace-status source destination))]
          (when (not (= sharing 0)) (check-old-native-reader reader))
          (test.assert-i64-eq
            status
            expected
            "replace status under fixture sharing mode"))))
    (when readonly (set-attributes destination (cast 0x80 : u32)))
    (when
      (not (= expected 0))
      (check-text destination "old")
      (check-text source "new payload")
      (test.assert-i64-eq
        (replace-status source destination)
        0
        "replace after clearing obstruction"))
    (check-text destination "new payload")
    (test.assert-true
      (not (io.file-exists? (string.copy source)))
      "stage disappeared")
    (test.assert-i64-eq
      (fs.remove-file-status destination)
      0
      "remove fixture destination")))

(cfg
  windows
  (define (repeat-a [count : i64]) : String
    (let
      [bytes : (__tl_dyn-array u8) (__tl_make-array u8 count)]
      [index : i64 0]
      (while (< index count)
        (set! (array-ref bytes index) (cast 97 : u8))
        (+= index 1))
      (unsafe
        (string-from-bytes (io.array-const-ptr bytes) count)))))

(cfg
  windows
  (define (check-invalid-paths [source : (& str)] [destination : (& str)]) : unit
    (let
      [limit : String (repeat-a 32766)]
      [path : (__tl_dyn-array u8) (io.c-string (& limit))]
      (test.assert-i64-eq
        (unsafe
          (fs.fs-windows-rename-path-units
            (cast 0 : u32)
            (io.array-const-ptr path)))
        32767
        "conversion size includes the terminal NUL"))
    (test.assert-i64-eq (replace-status source destination) 2 "missing source")
    (write-text source "stage")
    (let
      [nul-path : String (str_cat.str-cat destination "\0suffix")]
      (test.assert-i64-eq
        (replace-status source (& nul-path))
        87
        "embedded NUL destination")
      (test.assert-i64-eq
        (replace-status (& nul-path) destination)
        87
        "embedded NUL source"))
    (test.assert-i64-eq
      (replace-status source (repeat-a 32767))
      87
      "wide path overflow")
    (test.assert-i64-eq
      (replace-status source (repeat-a 131068))
      87
      "narrow path overflow")
    (when
      (and
        (= (fs.fs-win-are-file-apis-ansi) 1)
        (= (get-acp) (cast 65001 : u32)))
      (let
        [invalid : u8 (cast 0xff : u8)]
        [malformed : String
          (unsafe
            (string-from-bytes (ptr-addr-of invalid) 1))]
        (test.assert-i64-eq
          (replace-status source (& malformed))
          1113
          "malformed UTF-8")))
    (check-text source "stage")
    (test.assert-true
      (not (io.file-exists? (string.copy destination)))
      "invalid paths leave destination absent")
    (test.assert-i64-eq
      (replace-status source destination)
      0
      "replace at absent destination")
    (check-text destination "stage")
    (test.assert-i64-eq
      (fs.remove-file-status destination)
      0
      "remove fixture destination")))

(cfg
  windows
  (define (check-rename-completion) : unit
    (test.assert-i64-eq
      (comptime (size-of (type fs.FsWindowsRenameInfo)))
      24
      "rename info size")
    (test.assert-i64-eq
      (comptime (offset-of (type fs.FsWindowsRenameInfo) flags))
      0
      "flags offset")
    (test.assert-i64-eq
      (comptime (offset-of (type fs.FsWindowsRenameInfo) root-directory))
      8
      "root offset")
    (test.assert-i64-eq
      (comptime (offset-of (type fs.FsWindowsRenameInfo) name-bytes))
      16
      "length offset")
    (test.assert-i64-eq
      (comptime (offset-of (type fs.FsWindowsRenameInfo) first-unit))
      20
      "name offset")
    (let
      [calls : i64 0]
      [compat : i64
        (fs.fs-windows-finish-atomic-replace
          87
          0
          (begin
            (+= calls 1)
            17))]
      (test.assert-i64-eq
        compat
        17
        "return the compatibility operation's status")
      (test.assert-i64-eq calls 1 "call compatibility operation once"))
    (test.assert-i64-eq
      (fs.fs-windows-finish-atomic-replace
        87
        6
        (io.panic "fallback after failed close"))
      22
      "preserve primary failure when cleanup fails")
    (test.assert-i64-eq
      (fs.fs-windows-finish-atomic-replace 5 6 (io.panic "fallback on denial"))
      13
      "preserve permission denial when cleanup fails")
    (test.assert-i64-eq
      (fs.fs-windows-finish-atomic-replace
        50
        0
        (io.panic "fallback on unsupported operation"))
      50
      "preserve error 50")
    (test.assert-i64-eq
      (fs.fs-windows-finish-atomic-replace
        33
        0
        (io.panic "fallback on lock violation"))
      33
      "preserve lock violation")
    (test.assert-i64-eq
      (fs.fs-windows-finish-atomic-replace
        0
        32
        (io.panic "fallback after commit"))
      -32
      "report cleanup failure after commit")))

(cfg
  windows
  (define (check-path-forms [source : (& str)] [destination : (& str)]) : unit
    (let
      [cwd : String (fs.current-dir)]
      [absolute : String (fs.path-join (& cwd) destination)]
      (check-control source (& absolute) false 7 false 0)
      ;; Drive-relative paths use the current directory on the named drive.
      ;; Rooted paths begin at the root of the current drive.
      (when
        (= (string.char-at (& cwd) 1) ':')
        (let
          [drive : String (string.substring (& cwd) 0 2)]
          [drive-relative : String
            (str_cat.str-cat drive (string.copy destination))]
          [rooted : String
            (string.substring
              (& absolute)
              2
              (- (string.string-length (& absolute)) 2))]
          (check-control source (& drive-relative) false 7 false 0)
          (check-control source (& rooted) false 7 false 0))))))

;; The CLI suite releases this noncooperating reader after the package
;; transaction finishes, making retry exhaustion independent of scheduling.
(cfg
  windows
  (define (hold-reader) : i64
    (let
      [destination : String (io.arg 2)]
      [ready : String (io.arg 3)]
      [release : String (io.arg 4)]
      [reader : i64 (open-reader (& destination) 3)]
      [polls : i64 0]
      (test.assert-true
        (not (= reader -1))
        "open package lock without delete sharing")
      (write-text (& ready) "ready")
      (while (and
        (< polls 6000)
        (not (io.file-exists? (string.copy (& release)))))
        (fs.fs-win-sleep (cast 10 : u32))
        (+= polls 1))
      (let
        [closed : i32
          (unsafe
            (fs.fs-win-close-handle reader))]
        (test.assert-i64-eq (cast closed : i64) 1 "close held lock reader")
        (test.assert-true (< polls 6000) "reader received release signal"))
      0)))

(cfg
  windows
  (define (main) : i64
    (when
      (and (= (io.arg-count) 5) (string.eq (io.arg 1) "--hold-reader"))
      (return (hold-reader)))
    (check-rename-completion)
    (let
      [root : String
        (match (fs.try-create-temp-dir-in "." "rename-ex")
          [(OkIoString path) path]
          [(ErrIoString error) (io.panic (io.error-message error))])]
      [source : String (fs.path-join (& root) "stage")]
      [destination : String (fs.path-join (& root) "published")]
      (check-control (& source) (& destination) true 0 false 0)
      (check-control (& source) (& destination) true 3 false 5)
      (check-control (& source) (& destination) true 7 false 5)
      (check-control (& source) (& destination) true 0 true 5)
      (check-control (& source) (& destination) false 0 false 0)
      (check-control (& source) (& destination) false 3 false 32)
      (check-control (& source) (& destination) false 7 false 0)
      (check-control (& source) (& destination) false 0 true 5)
      (check-invalid-paths (& source) (& destination))
      (check-path-forms (& source) (& destination))
      (when
        (and
          (= (fs.fs-win-are-file-apis-ansi) 1)
          (= (get-acp) (cast 65001 : u32)))
        (let
          [unicode : String (fs.path-join (& root) "é-日本-😀")]
          (check-control (& source) (& unicode) false 7 false 0)))
      (test.assert-i64-eq
        (fs.remove-dir-status (& root))
        0
        "remove fixture directory")
      42)))