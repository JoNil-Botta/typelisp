; Offline conversion of the hash-pinned official public CAVP inputs.
(import stdlib.byte_buf as buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat)

(defstruct Record
  (key String)
  (iv String)
  (aad String)
  (pt String)
  (ct String)
  (tag String)
  (failure bool))

(define (field [line : (& line str)] [prefix : String]) : String
  (let
    [length : i64 (string.string-length (& prefix))]
    (if (and
      (>= (string.string-length line) length)
      (string.eq (string.substring-view line 0 length) (& prefix)))
      (string.substring line length (- (string.string-length line) length))
      "")))

(define (hex? [text : (& text str)] [length : i64]) : bool
  (let
    [ok : bool (= (string.string-length text) length)]
    [index : i64 0]
    (while (< index (string.string-length text))
      (let
        [c : char (string.string-ref text index)]
        (unless
          (or (and (>= c '0') (<= c '9')) (and (>= c 'a') (<= c 'f')))
          (set! ok false)))
      (set! index (+ index 1)))
    ok))

;: The pinned archive has exactly these public length groups.
(define (length-index [text : String] [aad : bool]) : i64
  (cond
    [(string.eq text "0]") 0]
    [(string.eq text "128]") 1]
    [(string.eq
        text
        (if aad
          "160]"
          "256]"))
      2]
    [(string.eq
        text
        (if aad
          "384]"
          "104]"))
      3]
    [(string.eq
        text
        (if aad
          "720]"
          "408]"))
      4]
    [else (io.panic "unexpected pinned CAVP length group")]))

(define (emit [record : (& record Record)] [decrypt : bool]) : String
  (str_cat.str-cat
    "    (vectors.vector "
    (if decrypt
      "true"
      "false")
    " "
    (if record.failure
      "true"
      "false")
    " \""
    (string.copy (& record.key))
    "\" \""
    (string.copy (& record.iv))
    "\" \""
    (string.copy (& record.aad))
    "\" \""
    (string.copy (& record.pt))
    "\" \""
    (string.copy (& record.ct))
    "\" \""
    (string.copy (& record.tag))
    "\")\n"))

(define (section [path : String] [decrypt : bool]) : String
  (let
    [text : String (buf.to-string (io.read-file path))]
    [offset : i64 0]
    [iv96 : bool false]
    [tag128 : bool false]
    [p : i64 0]
    [a : i64 0]
    [active : bool false]
    [record : Record (Record "" "" "" "" "" "" false)]
    [seen : (Array bool 50) (make-array bool 50)]
    [selected : i64 0]
    [output : String ""]
    (while (< offset (string.string-length (& text)))
      (let
        [end : i64 (string.index-of-byte (& text) offset (cast 10 : u8))]
        (when (< end 0) (set! end (string.string-length (& text))))
        (let
          [line : String
            (string.trim (string.substring-view (& text) offset (- end offset)))]
          [iv-field : String (field (& line) "[IVlen = ")]
          [tag-field : String (field (& line) "[Taglen = ")]
          [pt-field : String (field (& line) "[PTlen = ")]
          [aad-field : String (field (& line) "[AADlen = ")]
          [count-field : String (field (& line) "Count = ")]
          (cond
            [(string.eq (& line) "")
              (when
                active
                (when
                  (and iv96 tag128)
                  (let
                    [group : i64 (+ (* a 5) p)]
                    [pt-lengths : (Array i64 5) (array 0 32 64 26 102)]
                    [aad-lengths : (Array i64 5) (array 0 32 40 96 180)]
                    (when record.failure (set! group (+ group 25)))
                    (unless
                      (and
                        (hex? (& record.key) 32)
                        (hex? (& record.iv) 24)
                        (hex? (& record.tag) 32)
                        (hex? (& record.ct) (array-ref pt-lengths p))
                        (hex? (& record.aad) (array-ref aad-lengths a))
                        (or
                          record.failure
                          (hex? (& record.pt) (array-ref pt-lengths p))))
                      (io.panic "invalid pinned GCM record"))
                    (unless
                      (array-ref seen group)
                      (set! (array-ref seen group) true)
                      (set! selected (+ selected 1))
                      (set!
                        output
                        (str_cat.str-cat output (emit (& record) decrypt))))))
                (set! active false))]
            [(string.eq (& iv-field) "96]") (set! iv96 true)]
            [(> (string.string-length (& iv-field)) 0) (set! iv96 false)]
            [(> (string.string-length (& tag-field)) 0)
              (set! tag128 (string.eq (& line) "[Taglen = 128]"))]
            [(> (string.string-length (& pt-field)) 0)
              (set! p (length-index pt-field false))]
            [(> (string.string-length (& aad-field)) 0)
              (set! a (length-index aad-field true))]
            [(> (string.string-length (& count-field)) 0)
              (when active (io.panic "unterminated pinned CAVP record"))
              (set! active true)
              (set! record (Record "" "" "" "" "" "" false))]
            [(and active iv96 tag128)
              (cond
                [(string.eq (& line) "FAIL") (set! record.failure true)]
                [(string.eq (string.substring-view (& line) 0 3) "Key")
                  (set! record.key (field (& line) "Key = "))]
                [(string.eq (string.substring-view (& line) 0 2) "IV")
                  (set! record.iv (field (& line) "IV = "))]
                [(string.eq (string.substring-view (& line) 0 3) "AAD")
                  (set! record.aad (field (& line) "AAD ="))
                  (set! record.aad (string.trim (& record.aad)))]
                [(string.eq (string.substring-view (& line) 0 2) "PT")
                  (set! record.pt (field (& line) "PT ="))
                  (set! record.pt (string.trim (& record.pt)))]
                [(string.eq (string.substring-view (& line) 0 2) "CT")
                  (set! record.ct (field (& line) "CT ="))
                  (set! record.ct (string.trim (& record.ct)))]
                [(string.eq (string.substring-view (& line) 0 3) "Tag")
                  (set! record.tag (field (& line) "Tag = "))]
                [else (io.panic "unexpected pinned GCM field")])]
            [else unit]))
        (set! offset (+ end 1))))
    (unless
      (=
        selected
        (if decrypt
          50
          25))
      (io.panic "incomplete pinned GCM selection"))
    output))

(define (main) : i64
  (unless
    (= (io.arg-count) 3)
    (io.panic "usage: generate <rsp-directory> <output.tl>"))
  (let
    [output : String
      (str_cat.str-cat
        "; Generated from hash-pinned NIST CAVS 14.0 files; regenerate-crypto-gcm-kat.sh.\n"
        "(import stdlib.tests.crypto_aes128_gcm_support as vectors)\n"
        "(import stdlib.tests.crypto_aes_core_inline as aes-vectors)\n"
        "(define (self-test) : unit\n"
        "  (aes-vectors.vector false \"000102030405060708090a0b0c0d0e0f\" \"00112233445566778899aabbccddeeff\" \"69c4e0d86a7b0430d8cdb78070b4c55a\")\n"
        (section (str_cat.str-cat (io.arg 1) "/gcmEncryptExtIV128.rsp") false)
        (section (str_cat.str-cat (io.arg 1) "/gcmDecrypt128.rsp") true)
        ")\n(test gcm-nist-cavp (self-test))\n")]
    (io.write-file (io.arg 2) (buf.str-as-bytes (& output)))
    0))