;; Branch-only native Windows evidence for #8831.
(import stdlib.io)
(import stdlib.fs)
(import stdlib.string)
(import stdlib.str_cat)
(import stdlib.byte_buf)

(unsafe
  (extern (set-last-error [code : i32]) : unit (:symbol "SetLastError")))

(unsafe
  (extern (set-file-attributes [path : (Ptr u8)] [attributes : i32]) : i32 (:symbol "SetFileAttributesA")))

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

;; mode0 has no reader; 3/7 hold a reader with that exact share mask;
;; mode8 makes the destination read-only. All handles stay live across rename.
(define (probe [label : String] [mode : i64]) : bool
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
        [result : i32
          (unsafe
            (fs.fs-win-move-file-ex
              (ptr-cast (__tl_array-data source-bytes) : (Ptr u8))
              (ptr-cast (__tl_array-data destination-bytes) : (Ptr u8))
              (cast 9 : i32)))]
        ;; Capture before any formatter, allocator, close or other Win32 call.
        [raw : i64
          (if (= result (cast 0 : i32))
            (cast (fs.fs-win-get-last-error) : i64)
            0)]
        [_restore-error : unit
          (unsafe
            (set-last-error (cast raw : i32)))]
        [mapped : i64 (fs.fs-windows-last-error-status)]
        [succeeded : bool (!= result (cast 0 : i32))]
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
              (= succeeded (or (= mode 0) (= mode 7)))
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
  (if (and
    (probe "no-reader" 0)
    (probe "reader-share3" 3)
    (probe "reader-share7" 7)
    (probe "readonly-destination" 8))
    42
    1))