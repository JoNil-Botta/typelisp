;; Branch-only native Windows evidence for #8831.
(import stdlib.io)
(import stdlib.fs)
(import stdlib.string)
(import stdlib.str_cat)
(import stdlib.byte_buf)
(import stdlib.iterator)

(unsafe
  (extern (set-last-error [code : i32]) : unit (:symbol "SetLastError")))

(unsafe
  (extern (set-file-attributes [path : (Ptr u8)] [attributes : i32]) : i32 (:symbol "SetFileAttributesA")))

(unsafe
  (extern (set-file-information
    [handle : i64]
    [class : i32]
    [info : (Ptr u8)]
    [length : u32]) : i32 (:symbol "SetFileInformationByHandle")))

(defstruct MoveResult
  (result i32)
  (raw i64))

;; This diagnostic has only ASCII paths. Production must use full UTF-16 paths.
;; FILE_RENAME_INFO x64: flags0, root8, name-length16, UTF-16 name20.
(define (posix-move [source : (Ptr u8)] [destination : (& destination str)]) : MoveResult
  (let
    [cwd : String (fs.current-dir)]
    [full : String (fs.path-join (& cwd) destination)]
    [n : i64 (string.string-length (& full))]
    [info : (__tl_dyn-array u8) (__tl_make-array u8 (+ 22 (* n 2)))]
    (for [i (iterator.range 0 (array-length info))]
      (set! (array-ref info i) (cast 0 : u8)))
    (unsafe
      (ptr-write!
        (ptr-cast (__tl_array-data info) : (MutPtr u32))
        (cast 3 : u32))
      (ptr-write!
        (ptr-cast (ptr-offset (__tl_array-data info) 16) : (MutPtr u32))
        (cast (* n 2) : u32)))
    (for [i (iterator.range 0 n)]
      (let
        [c : char (string.char-at (& full) i)]
        (when (> (cast c : i64) 127) (return (MoveResult (cast 0 : i32) 123)))
        (unsafe
          (ptr-write!
            (ptr-cast
              (ptr-offset (__tl_array-data info) (+ 20 (* i 2)))
              : (MutPtr u16))
            (cast
              (if (= c '/')
                92
                (cast c : i64))
              : u16)))))
    (let
      [handle : i64
        (unsafe
          (fs.fs-win-create-file source 0x10000 7 0 3 0x80 0))]
      (when
        (= handle -1)
        (return
          (MoveResult (cast 0 : i32) (cast (fs.fs-win-get-last-error) : i64))))
      (let
        [result : i32
          (unsafe
            (set-file-information
              handle
              (cast 22 : i32)
              (ptr-cast (__tl_array-data info) : (Ptr u8))
              (cast (array-length info) : u32)))]
        [raw : i64
          (if (= result (cast 0 : i32))
            (cast (fs.fs-win-get-last-error) : i64)
            0)]
        [_closed : i32
          (unsafe
            (fs.fs-win-close-handle handle))]
        (MoveResult result raw)))))

(define (write-text [path : (& path str)] [text : String]) : bool
  (match (io.try-write-file path (byte_buf.str-as-bytes (& text)))
    [(OkIoUnit) true]
    [(ErrIoUnit error)
      (io.println "{}" (io.error-message error))
      false]))

(define (contents-eq? [path : (& path str)] [expected : (& expected str)]) : bool
  (match (io.try-read-file path)
    [(OkIoBytes contents) (string.eq (byte_buf.to-string contents) expected)]
    [(ErrIoBytes _) false]))

(define (report-number [label : String] [value : i64]) : unit
  (io.println "{}" (str_cat.str-cat label (string.int->string value))))

(define (reader-old? [handle : i64]) : bool
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 3)]
    [count : (__tl_dyn-array i32) (__tl_make-array i32 1)]
    [result : i32
      (unsafe
        (io.io-win-read-file
          handle
          (ptr-cast (__tl_array-data bytes) : (MutPtr u8))
          (cast 3 : i32)
          (ptr-cast (__tl_array-data count) : (MutPtr i32))
          0))]
    (and
      (= result (cast 1 : i32))
      (= (array-ref count 0) (cast 3 : i32))
      (= (array-ref bytes 0) (cast 111 : u8))
      (= (array-ref bytes 1) (cast 108 : u8))
      (= (array-ref bytes 2) (cast 100 : u8)))))

;; mode0 has no reader; 3/7 hold a reader with that exact share mask;
;; mode8 makes the destination read-only. All handles stay live across rename.
(define (probe [label : String] [mode : i64] [posix : bool]) : bool
  (let
    [source : String "target/exp/w2-8831-probe/source.txt"]
    [destination : String "target/exp/w2-8831-probe/destination.txt"]
    [old : String "old"]
    [new : String "new"]
    [_reset : io.ResultIoUnit (fs.try-remove-file-if-exists (& source))]
    [_reset-destination : io.ResultIoUnit
      (fs.try-remove-file-if-exists (& destination))]
    [prepared : bool
      (and
        (write-text (& source) (string.copy new))
        (write-text (& destination) (string.copy old)))]
    [source-bytes : (__tl_dyn-array u8) (io.c-string source)]
    [destination-bytes : (__tl_dyn-array u8) (io.c-string destination)]
    (unless prepared (return false))
    (when
      (= mode 8)
      (unless
        (=
          (unsafe
            (set-file-attributes
              (ptr-cast (__tl_array-data destination-bytes) : (Ptr u8))
              (cast 1 : i32)))
          (cast 1 : i32))
        (return false)))
    (let
      [reader : i64
        (if (or (= mode 3) (= mode 7))
          (unsafe
            (fs.fs-win-create-file
              (ptr-cast (__tl_array-data destination-bytes) : (Ptr u8))
              0x80000000
              mode
              0
              3
              0x80
              0))
          0)]
      (when (= reader -1) (return false))
      (unsafe
        (set-last-error (cast 0 : i32)))
      (let
        [observed : MoveResult
          (if posix
            (posix-move
              (unsafe
                (ptr-cast (__tl_array-data source-bytes) : (Ptr u8)))
              (& destination))
            (let
              [result : i32
                (unsafe
                  (fs.fs-win-move-file-ex
                    (ptr-cast (__tl_array-data source-bytes) : (Ptr u8))
                    (ptr-cast (__tl_array-data destination-bytes) : (Ptr u8))
                    (cast 9 : i32)))]
              [raw : i64
                (if (= result (cast 0 : i32))
                  (cast (fs.fs-win-get-last-error) : i64)
                  0)]
              (MoveResult result raw)))]
        [result : i32 observed.result]
        [raw : i64 observed.raw]
        [_restore-error : unit
          (unsafe
            (set-last-error (cast raw : i32)))]
        [mapped : i64 (fs.fs-windows-last-error-status)]
        [succeeded : bool (!= result (cast 0 : i32))]
        [reader-valid : bool
          (if (!= reader 0)
            (reader-old? reader)
            true)]
        (io.println "{}" label)
        (report-number "move-result=" (cast result : i64))
        (report-number "raw-win32=" raw)
        (report-number "mapped-status=" mapped)
        (when
          (not succeeded)
          (io.println
            "{}"
            (io.error-message (io.error-from-status (& destination) mapped)))
          (match (fs.try-atomic-replace (& source) (& destination))
            [(OkIoUnit) (io.println "production-repeat=success")]
            [(ErrIoUnit error)
              (io.println
                "{}"
                (str_cat.str-cat "production-repeat=" (io.error-message error)))]))
        (when
          (!= reader 0)
          (io.println
            "{}"
            (if reader-valid
              "reader-retains-old=success"
              "reader-retains-old=FAIL"))
          (unless
            (=
              (unsafe
                (fs.fs-win-close-handle reader))
              (cast 1 : i32))
            (return false)))
        (when
          (= mode 8)
          (unless
            (=
              (unsafe
                (set-file-attributes
                  (ptr-cast (__tl_array-data destination-bytes) : (Ptr u8))
                  (cast 0x80 : i32)))
              (cast 1 : i32))
            (return false)))
        (let
          [expected : String
            (if succeeded
              (string.copy new)
              (string.copy old))]
          [valid : bool
            (and
              reader-valid
              (= succeeded (or (= mode 0) (and posix (= mode 7))))
              (contents-eq? (& destination) (& expected)))]
          (when
            (and (= mode 3) (not succeeded))
            (match (fs.try-atomic-replace (& source) (& destination))
              [(OkIoUnit)
                (io.println "after-reader-close=success")
                (set! valid (and valid (contents-eq? (& destination) (& new))))]
              [(ErrIoUnit error)
                (io.println "{}" (io.error-message error))
                (set! valid false)]))
          valid)))))

(define (main) : i64
  (let
    [a : bool (probe "legacy-no-reader" 0 false)]
    [b : bool (probe "legacy-reader-share3" 3 false)]
    [c : bool (probe "legacy-reader-share7" 7 false)]
    [d : bool (probe "legacy-readonly-destination" 8 false)]
    [e : bool (probe "posix-no-reader" 0 true)]
    [f : bool (probe "posix-reader-share3" 3 true)]
    [g : bool (probe "posix-reader-share7" 7 true)]
    [h : bool (probe "posix-readonly-destination" 8 true)]
    (if (and a b c d e f g h)
      42
      1)))