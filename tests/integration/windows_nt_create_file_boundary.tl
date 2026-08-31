(import stdlib.byte_buf)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.process)
(import stdlib.str_cat)
(import stdlib.string)

(define (fixture-path-join [left : (& left str)] [right : String]) : String
  (fs.path-join left (& right)))

(define (fixture-wide-name [text : (& text str)]) : (__tl_dyn-array u16)
  (let
    [n : i64 (string.string-length text)]
    [out : (__tl_dyn-array u16) (__tl_make-array u16 n)]
    [index : i64 0]
    (begin
      (while (< index n)
        (begin
          (set!
            (array-ref out index)
            (cast (string.string-ref text index) : u16))
          (set! index (+ index 1))))
      out)))

(define (fixture-open-directory [path : (& path str)]) : i64
  (let
    [path-bytes : (__tl_dyn-array u8) (io.c-string path)]
    (fs.fs-win-create-file
      (io.array-const-ptr path-bytes)
      2147483648
      7
      0
      3
      33554432
      0)))

(define (fixture-create-junction
  [junction : (& junction str)]
  [target : (& target str)]) : bool
  (process.result-success?
    (process.output
      (process.command
        "cmd.exe"
        (process.args-cons
          "/d"
          (process.args-cons
            "/c"
            (process.args-cons
              "mklink"
              (process.args-cons
                "/J"
                (process.args-cons
                  (string.copy junction)
                  (process.args-cons (string.copy target) (process.args-empty)))))))))))

(define (fixture-write-handle [handle : i64]) : bool
  (let
    [contents : String "ok"]
    [bytes : (__tl_dyn-array u8) (io.c-string (& contents))]
    [written : i32 (cast 0 : i32)]
    (and
      (not
        (=
          (io.io-win-write-file
            handle
            (io.array-const-ptr bytes)
            (cast 2 : i32)
            (unsafe
              (ptr-addr-of written))
            0)
          (cast 0 : i32)))
      (= written (cast 2 : i32)))))

(define (fixture-close [handle : i64]) : bool
  (not (= (fs.fs-win-close-handle handle) (cast 0 : i32))))

(define (fixture-cleanup
  [created : String]
  [sentinel : String]
  [junction : String]
  [root : String]
  [outside : String]
  [base : String]) : bool
  (let
    [created-status : i64 (fs.remove-file-status (& created))]
    [sentinel-status : i64 (fs.remove-file-status (& sentinel))]
    [junction-status : i64 (fs.remove-dir-status (& junction))]
    [root-status : i64 (fs.remove-dir-status (& root))]
    [outside-status : i64 (fs.remove-dir-status (& outside))]
    [base-status : i64 (fs.remove-dir-status (& base))]
    (and
      (= created-status 0)
      (= sentinel-status 0)
      (= junction-status 0)
      (= root-status 0)
      (= outside-status 0)
      (= base-status 0))))

(define (main) : i64
  (let
    [cwd : String (fs.current-dir)]
    [base-name : String
      (str_cat.str-cat
        "typelisp-nt-create-file-boundary-"
        (string.int->string (fs.process-id)))]
    [base : String (fixture-path-join (& cwd) base-name)]
    [root : String (fixture-path-join (& base) "root")]
    [outside : String (fixture-path-join (& base) "outside")]
    [junction : String (fixture-path-join (& root) "link")]
    [created : String (fixture-path-join (& root) "created.txt")]
    [sentinel : String (fixture-path-join (& outside) "sentinel.txt")]
    (cond
      [(not (= (fs.mkdir-status (& base)) 0)) 1]
      [(not (= (fs.mkdir-status (& root)) 0)) 2]
      [(not (= (fs.mkdir-status (& outside)) 0)) 3]
      [else
        (let
          [sentinel-contents : String "outside"]
          (if (not
            (=
              (io.write-file-status
                (& sentinel)
                (byte_buf.str-as-bytes (& sentinel-contents)))
              0))
            4
            (if (not (fixture-create-junction (& junction) (& outside)))
              5
              (let
                [root-handle : i64 (fixture-open-directory (& root))]
                (if (= root-handle -1)
                  6
                  (let
                    [create-name : String "created.txt"]
                    [create-wide : (__tl_dyn-array u16)
                      (fixture-wide-name (& create-name))]
                    [create-result : fs.FsWindowsNtCreateResult
                      (fs.windows-nt-create-file-relative
                        root-handle
                        (unsafe
                          (__tl_array-data create-wide))
                        (cast
                          (* (string.string-length (& create-name)) 2)
                          : u16)
                        (bit-or
                          fs.fs-windows-file-write-data
                          fs.fs-windows-synchronize)
                        (cast 0 : u32)
                        fs.fs-windows-file-create
                        (bit-or
                          fs.fs-windows-file-non-directory-file
                          fs.fs-windows-file-synchronous-io-nonalert))]
                    (if (not (fs.windows-nt-create-ok? create-result))
                      7
                      (let
                        [created-handle : i64
                          (fs.windows-nt-create-handle-or create-result -1)]
                        [write-ok : bool (fixture-write-handle created-handle)]
                        [close-ok : bool (fixture-close created-handle)]
                        (if (not (and write-ok close-ok))
                          8
                          (if (not
                            (and
                              (= (fs.file-size-status (& created)) 0)
                              (= (fs.file-size (& created)) 2)))
                            9
                            (let
                              [collision-result : fs.FsWindowsNtCreateResult
                                (fs.windows-nt-create-file-relative
                                  root-handle
                                  (unsafe
                                    (__tl_array-data create-wide))
                                  (cast
                                    (* (string.string-length (& create-name)) 2)
                                    : u16)
                                  (bit-or
                                    fs.fs-windows-file-write-data
                                    fs.fs-windows-synchronize)
                                  (cast 0 : u32)
                                  fs.fs-windows-file-create
                                  (bit-or
                                    fs.fs-windows-file-non-directory-file
                                    fs.fs-windows-file-synchronous-io-nonalert))]
                              (if (not
                                (fs.windows-nt-create-already-exists?
                                  collision-result))
                                10
                                (let
                                  [reparse-name : String "link\\sentinel.txt"]
                                  [reparse-wide : (__tl_dyn-array u16)
                                    (fixture-wide-name (& reparse-name))]
                                  [reparse-result : fs.FsWindowsNtCreateResult
                                    (fs.windows-nt-create-file-relative
                                      root-handle
                                      (unsafe
                                        (__tl_array-data reparse-wide))
                                      (cast
                                        (*
                                          (string.string-length
                                            (& reparse-name))
                                          2)
                                        : u16)
                                      (bit-or
                                        fs.fs-windows-file-read-data
                                        fs.fs-windows-synchronize)
                                      (bit-or
                                        fs.fs-windows-file-share-read
                                        (bit-or
                                          fs.fs-windows-file-share-write
                                          fs.fs-windows-file-share-delete))
                                      fs.fs-windows-file-open
                                      (bit-or
                                        fs.fs-windows-file-non-directory-file
                                        fs.fs-windows-file-synchronous-io-nonalert))]
                                  [root-close-ok : bool
                                    (fixture-close root-handle)]
                                  (if (not
                                    (and
                                      (fs.windows-nt-create-reparse-point?
                                        reparse-result)
                                      root-close-ok))
                                    11
                                    (if (fixture-cleanup
                                      created
                                      sentinel
                                      junction
                                      root
                                      outside
                                      base)
                                      42
                                      12)))))))))))))))])))