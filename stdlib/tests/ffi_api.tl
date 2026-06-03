(import "stdlib/ffi.tl")

(import "stdlib/test.tl")

(extern tl_alloc : (-> i64 (MutPtr u8)))

(define (ffi-test-read-u8 [ptr : (MutPtr u8)] [index : i64]) : u8
  (unsafe (ptr-read (ptr-offset ptr index))))

(define (ffi-test-write-u8! [ptr : (MutPtr u8)] [index : i64] [value : i64]) : unit
  (unsafe (ptr-write! (ptr-offset ptr index) (cast value : u8))))

(define (ffi-test-assert-u8-eq
  [actual : u8]
  [expected : i64]
  [message : String]) : unit
  (assert-i64-eq (cast actual : i64) expected message))

(define (ffi-test-assert-copy-ok
  [result : FfiCStringCopyResult]
  [expected : i64]
  [message : String]) : unit
  (match result
    [(FfiCStringCopyOk written) (assert-i64-eq written expected message)]
    [_ (panic message)]))

(define (ffi-test-assert-too-small
  [result : FfiCStringCopyResult]
  [expected : i64]
  [message : String]) : unit
  (match result
    [(FfiCStringBufferTooSmall required)
      (assert-i64-eq required expected message)]
    [_ (panic message)]))

(define (ffi-test-assert-interior-nul
  [result : FfiCStringCopyResult]
  [message : String]) : unit
  (match result
    [(FfiCStringInteriorNul) unit]
    [_ (panic message)]))

(define (ffi-test-string-with-nul) : String
  (unsafe
    (let
      [data : (MutPtr u8) (tl_alloc 3)]
      [record : (MutPtr u8) (tl_alloc 16)]
      [cell : (MutPtr u8) (tl_alloc 8)]
      [record-u64 : (MutPtr u64) (ptr-cast record : (MutPtr u64))]
      [cell-u64 : (MutPtr u64) (ptr-cast cell : (MutPtr u64))]
      (begin
        (ptr-write! (ptr-offset data 0) (cast #a' : u8))
        (ptr-write! (ptr-offset data 1) (cast #\nul' : u8))
        (ptr-write! (ptr-offset data 2) (cast #b' : u8))
        (ptr-write! record-u64 (ptr->int (ptr-cast data : (Ptr u8))))
        (ptr-write! (ptr-offset record-u64 1) (cast 3 : u64))
        (ptr-write! cell-u64 (ptr->int (ptr-cast record : (Ptr u8))))
        (ptr-read (ptr-cast cell : (Ptr String)))))))

(define (main) : i64
  (begin
    (assert-i64-eq
      (ffi-c-string-required-bytes "")
      1
      "empty c string needs only NUL")
    (assert-i64-eq
      (ffi-c-string-required-bytes "abc")
      4
      "abc c string needs trailing NUL")
    (assert-false
      (ffi-c-string-interior-nul? "abc")
      "normal ASCII has no interior NUL")
    (let
      [empty-buf : (MutPtr u8) (tl_alloc 1)]
      (begin
        (ffi-test-assert-copy-ok
          (ffi-c-string-copy! "" empty-buf 1)
          1
          "empty copy succeeds")
        (ffi-test-assert-u8-eq
          (ffi-test-read-u8 empty-buf 0)
          0
          "empty copy writes trailing NUL")))
    (let
      [exact : (MutPtr u8) (tl_alloc 4)]
      (begin
        (ffi-test-assert-copy-ok
          (ffi-c-string-copy! "abc" exact 4)
          4
          "exact-capacity copy succeeds")
        (ffi-test-assert-u8-eq (ffi-test-read-u8 exact 0) 97 "copied a")
        (ffi-test-assert-u8-eq (ffi-test-read-u8 exact 1) 98 "copied b")
        (ffi-test-assert-u8-eq (ffi-test-read-u8 exact 2) 99 "copied c")
        (ffi-test-assert-u8-eq
          (ffi-test-read-u8 exact 3)
          0
          "copy writes trailing NUL")))
    (let
      [small : (MutPtr u8) (tl_alloc 3)]
      (begin
        (ffi-test-write-u8! small 0 77)
        (ffi-test-assert-too-small
          (ffi-c-string-copy! "abc" small 3)
          4
          "too-small reports required size")
        (ffi-test-assert-u8-eq
          (ffi-test-read-u8 small 0)
          77
          "too-small does not write prefix")))
    (let
      [with-nul : String (ffi-test-string-with-nul)]
      [nul-buf : (MutPtr u8) (tl_alloc 4)]
      (begin
        (ffi-test-write-u8! nul-buf 0 88)
        (assert-true
          (ffi-c-string-interior-nul? with-nul)
          "unsafe fixture contains interior NUL")
        (ffi-test-assert-interior-nul
          (ffi-c-string-copy! with-nul nul-buf 4)
          "interior NUL reports deterministic error")
        (ffi-test-assert-u8-eq
          (ffi-test-read-u8 nul-buf 0)
          88
          "interior NUL does not write prefix")))
    42))