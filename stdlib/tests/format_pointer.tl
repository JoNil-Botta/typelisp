(import stdlib.format)
(import stdlib.io)
(import stdlib.string)

(define (pointer-shape? [text : (& text str)]) : bool
  (let
    [len : i64 (string.string-length text)]
    [index : i64 2]
    [ok : bool
      (if (>= len 3)
        (if (= (cast (string.string-ref text 0) : i64) 48)
          (= (cast (string.string-ref text 1) : i64) 120)
          false)
        false)]
    (begin
      (while (and ok (< index len))
        (let
          [code : i64 (cast (string.string-ref text index) : i64)]
          (begin
            (set!
              ok
              (if (and (>= code 48) (<= code 57))
                true
                (and (>= code 97) (<= code 102))))
            (set! index (+ index 1)))))
      ok)))

(define (format-borrowed-pointer [pointer : (& pointer (Ptr i64))]) : String
  (unsafe
    (format.format "{:p}" pointer)))

(define (format-borrowed-mut-pointer [pointer : (& pointer (MutPtr i64))]) : String
  (unsafe
    (format.format "{:p}" pointer)))

(define (main) : i64
  (let
    [slot : i64 42]
    [null : (Ptr i64) (ptr-null : (Ptr i64))]
    [mut-null : (MutPtr i64) (ptr-null : (MutPtr i64))]
    [mut-pointer : (MutPtr i64)
      (unsafe
        (ptr-addr-of slot))]
    [pointer : (Ptr i64)
      (unsafe
        (ptr-cast mut-pointer : (Ptr i64)))]
    [plain : String
      (unsafe
        (format.format "{:p}" null))]
    [mut-plain : String
      (unsafe
        (format.format "{:p}" mut-null))]
    [alternate : String
      (unsafe
        (format.format "{:#p}" null))]
    [width : String
      (unsafe
        (format.format "{:20p}" null))]
    [alternate-short-width : String
      (unsafe
        (format.format "{:#10p}" null))]
    [alternate-wide : String
      (unsafe
        (format.format "{:#20p}" null))]
    [zero : String
      (unsafe
        (format.format "{:020p}" null))]
    [left : String
      (unsafe
        (format.format "{:<20p}" null))]
    [center : String
      (unsafe
        (format.format "{:^20p}" null))]
    [fill-right : String
      (unsafe
        (format.format "{:*>20p}" null))]
    [zero-fill-right : String
      (unsafe
        (format.format "{:0>20p}" null))]
    [alternate-aligned : String
      (unsafe
        (format.format "{:*^#20p}" null))]
    [plus : String
      (unsafe
        (format.format "{:+p}" null))]
    [plus-alternate : String
      (unsafe
        (format.format "{:+#p}" null))]
    [precision-ignored : String
      (unsafe
        (format.format "{:.0p}" null))]
    [dynamic-width : String
      (unsafe
        (format.format "{:1$p}" null (cast 6 : i64)))]
    [dynamic-alternate-width : String
      (unsafe
        (format.format "{:#1$p}" null (cast 20 : i64)))]
    [direct-nonnull : String
      (unsafe
        (format.format "{:p}" pointer))]
    [mut-nonnull : String
      (unsafe
        (format.format "{:p}" mut-pointer))]
    [borrowed-nonnull : String (format-borrowed-pointer (& pointer))]
    [borrowed-mut-nonnull : String
      (format-borrowed-mut-pointer (& mut-pointer))]
    (begin
      ;; The stdout macro and direct stderr String path share format.format.
      (unsafe
        (io.print-format "{:p}\n" null))
      (io.print-error alternate)
      (if (and
        (string.eq plain "0x0")
        (string.eq mut-plain "0x0")
        (string.eq alternate "0x0000000000000000")
        (string.eq width "                 0x0")
        (string.eq alternate-short-width "0x00000000")
        (string.eq alternate-wide "0x000000000000000000")
        (string.eq zero "0x000000000000000000")
        (string.eq left "0x0                 ")
        (string.eq center "        0x0         ")
        (string.eq fill-right "*****************0x0")
        (string.eq zero-fill-right "000000000000000000x0")
        (string.eq alternate-aligned "0x000000000000000000")
        (string.eq plus "+0x0")
        (string.eq plus-alternate "+0x000000000000000")
        (string.eq precision-ignored "0x0")
        (string.eq dynamic-width "   0x0")
        (string.eq dynamic-alternate-width "0x000000000000000000")
        (not (string.eq direct-nonnull "0x0"))
        (pointer-shape? (& direct-nonnull))
        (pointer-shape? (& mut-nonnull))
        (string.eq direct-nonnull mut-nonnull)
        (string.eq direct-nonnull borrowed-nonnull)
        (string.eq direct-nonnull borrowed-mut-nonnull))
        42
        1))))