(import stdlib.clone)

(defstruct HTTPItem
  (label String)
  (count i64))

(clone.gen-clone HTTPItem)

(defstruct RawBuf
  (data (MutPtr u8))
  (count i64))

(define (clone-raw-buf [source : (& RawBuf)]) : RawBuf
  (RawBuf source.data (+ source.count 1)))

(defstruct CopyStamp
  (count i64))

(define (clone-copy-stamp [source : (& CopyStamp)]) : CopyStamp
  (CopyStamp (+ source.count 1)))