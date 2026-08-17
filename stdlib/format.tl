;# Rust-style literal format-string macro returning a fresh String.
;#
;# `format` parses a string-literal template during macro expansion. Each `{}`
;# consumes one value and escapes use `{{` / `}}`. The generated expression is
;# one flat `str-cat` expansion, so the final string is allocated once.
;#
;# Nominal structs and enums participate through their canonical owner module.
;# A module's common primary type defines `to-string`; additional nominal types
;# use `to-string-<NominalName>`. A hook must have the exact shared-borrow
;# signature `(& T) -> String`. Defining both applicable spellings is rejected
;# as ambiguous.
;#
;# ```lisp test=run name=format-basic exit=42 stdout=""
;# (import stdlib.format)
;# (import stdlib.string)
;#
;# (define (main) : i64
;#   (let [name : String "Ada"]
;#     (if (string.eq (format.format "hello, {}" name) "hello, Ada") 42 1)))
;# ```
;#
;# Builtin placeholder values are `String`, `i64`, `bool`, `char`, `f64`, and
;# `f32`. Structural formatting is intentionally separate from this default
;# Display-style protocol.
(import stdlib.array)
(import stdlib.comptime)
(import stdlib.str_cat)
(import stdlib.string)

;: Runtime panic entry used by formatting without depending on `stdlib.io`.
;:
;: `tl_abort_string` accepts the same two-word string handle for owned `String`
;: and borrowed `str`; this declaration intentionally takes the owned form so
;: importing formatting does not introduce reference-typed runtime ABI state.
(extern (format-runtime-abort-string [message : String]) : never (:symbol "tl_abort_string"))

;: Render one supported ASCII/control character as a String for formatting.
(define (format-char-string [value : char]) : String
  (let
    [code : i64 (cast value : i64)]
    [printable : String
      " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"]
    (cond
      [(= code 9) "\t"]
      [(= code 10) "\n"]
      [(= code 13) "\r"]
      [(and (>= code 32) (<= code 126))
        (string.substring printable (- code 32) 1)]
      [else
        (format-runtime-abort-string "format: unsupported non-printable char")])))

;; The deterministic pure-TypeLisp f64 renderer is defined below the template
;; parser. Keeping it in this module makes `stdlib.format` independent of I/O.
;: Render one supported format placeholder through the shared dispatch path.
(defmacro (format-value [value : comptime.Expr]) : String
  (let
    [argument-type : comptime.Expr (comptime.expr-type value)]
    [argument-kind : String (type-kind argument-type)]
    [nominal? : bool
      (match argument-kind
        ["struct" true]
        ["enum" true]
        ["region" true]
        [_ false])]
    [value-key : String (type-key argument-type)]
    [owner : String
      (if nominal?
        (type-nominal-module argument-type)
        "")]
    [nominal-name : String
      (if nominal?
        (type-nominal-name argument-type)
        "")]
    [plain-name : String "to-string"]
    [qualified-name : String (comptime.string-append "to-string-" nominal-name)]
    [plain-present? : bool
      (if nominal?
        (comptime.module-value? owner plain-name)
        false)]
    [qualified-present? : bool
      (if nominal?
        (comptime.module-value? owner qualified-name)
        false)]
    [plain-contract : String
      (comptime.string-append
        owner
        (comptime.string-append
          ".to-string : (-> (& "
          (comptime.string-append value-key ") String)")))]
    [qualified-contract : String
      (comptime.string-append
        owner
        (comptime.string-append
          "."
          (comptime.string-append
            qualified-name
            (comptime.string-append
              " : (-> (& "
              (comptime.string-append value-key ") String)")))))]
    [expected-contract : String
      (comptime.string-append
        plain-contract
        (comptime.string-append " or " qualified-contract))]
    [plain-matches? : bool
      (if plain-present?
        (comptime.function-shared-borrow-returns-string?
          (comptime.module-value-type owner plain-name)
          argument-type)
        false)]
    [qualified-matches? : bool
      (if qualified-present?
        (comptime.function-shared-borrow-returns-string?
          (comptime.module-value-type owner qualified-name)
          argument-type)
        false)]
    [hook-dispatch : i64
      (+
        (if plain-matches?
          1
          0)
        (if qualified-matches?
          2
          0))]
    [hook-present? : bool
      (if plain-present?
        true
        qualified-present?)]
    (if nominal?
      (match hook-dispatch
        [3
          (comptime.comptime-error
            (comptime.string-append
              "format: ambiguous owner hooks for "
              (comptime.string-append
                value-key
                (comptime.string-append
                  " in canonical module "
                  (comptime.string-append
                    owner
                    (comptime.string-append
                      "; define only one of "
                      expected-contract))))))]
        [1
          (comptime.expr-shared-call1
            (comptime.module-value-expr owner plain-name)
            value)]
        [2
          (comptime.expr-shared-call1
            (comptime.module-value-expr owner qualified-name)
            value)]
        [_
          (if hook-present?
            (comptime.comptime-error
              (comptime.string-append
                "format: owner hook has wrong signature for "
                (comptime.string-append
                  value-key
                  (comptime.string-append
                    " in canonical module "
                    (comptime.string-append
                      owner
                      (comptime.string-append "; expected " expected-contract))))))
            (comptime.comptime-error
              (comptime.string-append
                "format: unsupported nominal type "
                (comptime.string-append
                  value-key
                  (comptime.string-append
                    " from canonical owner module "
                    (comptime.string-append
                      owner
                      (comptime.string-append "; expected " expected-contract)))))))])
      (match argument-kind
        ["string" value]
        ["i64" `(stdlib.string.int->string ,value)]
        ["bool"
          `(if ,value
            "true"
            "false")]
        ["char" `(stdlib.format.format-char-string ,value)]
        ["f64" `(stdlib.format.format-float-core ,value)]
        ["f32" `(stdlib.format.format-float-core (cast ,value : f64))]
        [_
          (comptime.comptime-error
            (comptime.string-append
              "format: unsupported argument type "
              value-key))]))))

;: Append one generated String expression to the internal format carrier.
(defmacro (format-push [carrier : comptime.Expr] [piece : comptime.Expr]) : comptime.Expr
  (match carrier
    [(comptime.Expr.Call callee pieces) `(,callee ,@pieces ,piece)]
    [_ carrier]))

;: Turn the completed internal carrier into the public single-allocation concat.
(defmacro (format-finish [carrier : comptime.Expr]) : String
  (match carrier
    [(comptime.Expr.Call _ pieces) `(stdlib.str_cat.str-cat ,@pieces)]
    [_ `""]))

;: Parse one byte of a literal format template and extend the output carrier.
(defmacro (format-from
  [template : comptime.Expr]
  [output-carrier : comptime.Expr]
  [offset : comptime.Expr]
  [arg-index : comptime.Expr]
  [args : comptime.Expr ...]) : String
  (match offset
    [(comptime.Expr.Int index)
      (match arg-index
        [(comptime.Expr.Int next-arg)
          (let
            [text : String (comptime.expr-string-value template)]
            [template-len : i64 (string.string-length text)]
            [arg-count : i64 (comptime.expr-list-length args)]
            (if (>= index template-len)
              (if (= next-arg arg-count)
                `(stdlib.format.format-finish ,output-carrier)
                (comptime.comptime-error
                  "format: not enough placeholders for arguments"))
              (let
                [ch : char (string.string-ref text index)]
                (if (= (cast ch : i64) 123)
                  (if (>= (+ index 1) template-len)
                    (comptime.comptime-error "format: unmatched '{'")
                    (let
                      [following : char (string.string-ref text (+ index 1))]
                      (if (= (cast following : i64) 123)
                        `(stdlib.format.format-from
                          ,(comptime.expr-string text)
                          (stdlib.format.format-push
                            ,output-carrier
                            ,(comptime.expr-string
                              (comptime.string-slice text index 1)))
                          ,(comptime.expr-int (+ index 2))
                          ,(comptime.expr-int next-arg)
                          ,@args)
                        (if (= (cast following : i64) 125)
                          (if (>= next-arg arg-count)
                            (comptime.comptime-error
                              "format: not enough arguments for placeholders")
                            `(stdlib.format.format-from
                              ,(comptime.expr-string text)
                              (stdlib.format.format-push
                                ,output-carrier
                                (stdlib.format.format-value
                                  ,(comptime.expr-list-nth args next-arg)))
                              ,(comptime.expr-int (+ index 2))
                              ,(comptime.expr-int (+ next-arg 1))
                              ,@args))
                          (comptime.comptime-error
                            "format: format specifiers are not supported")))))
                  (if (= (cast ch : i64) 125)
                    (if (>= (+ index 1) template-len)
                      (comptime.comptime-error "format: unmatched '}'")
                      (if (=
                        (cast (string.string-ref text (+ index 1)) : i64)
                        125)
                        `(stdlib.format.format-from
                          ,(comptime.expr-string text)
                          (stdlib.format.format-push
                            ,output-carrier
                            ,(comptime.expr-string
                              (comptime.string-slice text index 1)))
                          ,(comptime.expr-int (+ index 2))
                          ,(comptime.expr-int next-arg)
                          ,@args)
                        (comptime.comptime-error "format: unmatched '}'")))
                    `(stdlib.format.format-from
                      ,(comptime.expr-string text)
                      (stdlib.format.format-push
                        ,output-carrier
                        ,(comptime.expr-string
                          (comptime.string-slice text index 1)))
                      ,(comptime.expr-int (+ index 1))
                      ,(comptime.expr-int next-arg)
                      ,@args))))))]
        [_
          (comptime.comptime-error
            "format: internal argument index is not an integer")])]
    [_ (comptime.comptime-error "format: internal offset is not an integer")]))

;: Format a literal template and positional values into a freshly allocated String.
(defmacro (format [template : comptime.Expr] [args : comptime.Expr ...]) : String
  (if (comptime.expr-string? template)
    `(stdlib.format.format-from
      ,(comptime.expr-string (comptime.expr-string-value template))
      (__format-output)
      0
      0
      ,@args)
    (comptime.comptime-error "format: template must be a string literal")))

;: Fixed-capacity base-2^32 bignum backing the pure-TL f64 formatter.
(defstruct BigNum
  (limbs (__tl_dyn-array u64))
  (len i64))

;: Limb capacity of formatter bignum scratch buffers.
(define ftoa-cap : i64
  96)

;: Low 32-bit mask isolating a base-2^32 limb.
(define ftoa-mask32 : u64
  0xffffffff)

;: A zero-valued formatter BigNum.
(define (bn-zero) : BigNum
  (BigNum (array.make-array u64 stdlib.format.ftoa-cap) 0))

;: BigNum holding the u64 value x.
(define (bn-from-u64 [x : u64]) : BigNum
  (let
    [r : BigNum (bn-zero)]
    [lo : u64 (bit-and x stdlib.format.ftoa-mask32)]
    [hi : u64 (shr x 32)]
    (begin
      (set! (array-ref r.limbs 0) lo)
      (set! (array-ref r.limbs 1) hi)
      (if (> hi (cast 0 : u64))
        (BigNum r.limbs 2)
        (if (> lo (cast 0 : u64))
          (BigNum r.limbs 1)
          (BigNum r.limbs 0))))))

;: Compare BigNums a and b; -1 if a<b, 0 if equal, 1 if a>b.
(define (bn-cmp [a : (& a BigNum)] [b : (& b BigNum)]) : i64
  (let
    [la : i64 a.len]
    [lb : i64 b.len]
    (if (> la lb)
      1
      (if (< la lb)
        -1
        (let
          [i : i64 (- la 1)]
          [res : i64 0]
          [done : bool false]
          (begin
            (while (and (not done) (>= i 0))
              (let
                [av : u64 (array-ref a.limbs i)]
                [bv : u64 (array-ref b.limbs i)]
                (begin
                  (if (> av bv)
                    (begin
                      (set! res 1)
                      (set! done true))
                    (if (< av bv)
                      (begin
                        (set! res -1)
                        (set! done true))
                      unit))
                  (set! i (- i 1)))))
            res))))))

;: Limb count of arr with high zero limbs trimmed, starting from hint.
(define (bn-norm-len [arr : (& arr (__tl_dyn-array u64))] [hint : i64]) : i64
  (let
    [i : i64 hint]
    (begin
      (while (and (> i 0) (= (array-ref arr (- i 1)) (cast 0 : u64)))
        (set! i (- i 1)))
      i)))

;: Sum of BigNums a and b.
(define (bn-add [a : (& a BigNum)] [b : (& b BigNum)]) : BigNum
  (let
    [r : (__tl_dyn-array u64) (array.make-array u64 stdlib.format.ftoa-cap)]
    [la : i64 a.len]
    [lb : i64 b.len]
    [n : i64
      (if (> la lb)
        la
        lb)]
    [carry : u64 (cast 0 : u64)]
    [i : i64 0]
    (begin
      (while (< i n)
        (let
          [av : u64
            (if (< i la)
              (array-ref a.limbs i)
              (cast 0 : u64))]
          [bv : u64
            (if (< i lb)
              (array-ref b.limbs i)
              (cast 0 : u64))]
          [s : u64 (+ (+ av bv) carry)]
          (begin
            (set! (array-ref r i) (bit-and s stdlib.format.ftoa-mask32))
            (set! carry (shr s 32))
            (set! i (+ i 1)))))
      (when
        (> carry (cast 0 : u64))
        (begin
          (set! (array-ref r i) carry)
          (set! n (+ n 1))))
      (let
        [norm : i64 (bn-norm-len (& r) n)]
        (BigNum r norm)))))

;: Product of BigNum a and a value m that fits in 32 bits.
(define (bn-mul-u32 [a : (& a BigNum)] [m : u64]) : BigNum
  (let
    [r : (__tl_dyn-array u64) (array.make-array u64 stdlib.format.ftoa-cap)]
    [la : i64 a.len]
    [carry : u64 (cast 0 : u64)]
    [i : i64 0]
    (begin
      (while (< i la)
        (let
          [p : u64 (+ (* (array-ref a.limbs i) m) carry)]
          (begin
            (set! (array-ref r i) (bit-and p stdlib.format.ftoa-mask32))
            (set! carry (shr p 32))
            (set! i (+ i 1)))))
      (while (> carry (cast 0 : u64))
        (begin
          (set! (array-ref r i) (bit-and carry stdlib.format.ftoa-mask32))
          (set! carry (shr carry 32))
          (set! i (+ i 1))))
      (let
        [norm : i64 (bn-norm-len (& r) i)]
        (BigNum r norm)))))

;: BigNum a shifted left by n bits.
(define (bn-shl-bits [a : BigNum] [n : i64]) : BigNum
  (if (= a.len 0)
    a
    (let
      [limb-shift : i64 (/ n 32)]
      [bit-shift : i64 (% n 32)]
      [r : (__tl_dyn-array u64) (array.make-array u64 stdlib.format.ftoa-cap)]
      [la : i64 a.len]
      [carry : u64 (cast 0 : u64)]
      [i : i64 0]
      (begin
        (if (= bit-shift 0)
          (while (< i la)
            (begin
              (set! (array-ref r (+ i limb-shift)) (array-ref a.limbs i))
              (set! i (+ i 1))))
          (while (< i la)
            (let
              [v : u64 (array-ref a.limbs i)]
              [shifted : u64
                (bit-or
                  (bit-and (shl v bit-shift) stdlib.format.ftoa-mask32)
                  carry)]
              (begin
                (set! (array-ref r (+ i limb-shift)) shifted)
                (set! carry (shr v (- 32 bit-shift)))
                (set! i (+ i 1))))))
        (when
          (and (not (= bit-shift 0)) (> carry (cast 0 : u64)))
          (set! (array-ref r (+ la limb-shift)) carry))
        (let
          [norm : i64 (bn-norm-len (& r) (+ la (+ limb-shift 1)))]
          (BigNum r norm))))))

;: Product of BigNum a and the 64-bit value m.
(define (bn-mul-u64 [a : (& a BigNum)] [m : u64]) : BigNum
  (let
    [lo : u64 (bit-and m stdlib.format.ftoa-mask32)]
    [hi : u64 (shr m 32)]
    [low : BigNum (bn-mul-u32 a lo)]
    (if (= hi (cast 0 : u64))
      low
      (let
        [high : BigNum (bn-shl-bits (bn-mul-u32 a hi) 32)]
        (bn-add (& low) (& high))))))

;: BigNum a multiplied by ten raised to p.
(define (bn-mul-pow10 [a : BigNum] [p : i64]) : BigNum
  (let
    [r : BigNum a]
    [i : i64 0]
    (begin
      (while (< i p)
        (begin
          (set! r (bn-mul-u32 (& r) (cast 10 : u64)))
          (set! i (+ i 1))))
      r)))

;: floor(num/den) as u64, assuming the quotient fits in 60 bits.
(define (bn-div-floor-u64 [num : (& num BigNum)] [den : (& den BigNum)]) : u64
  (let
    [q : u64 (cast 0 : u64)]
    [bit : i64 59]
    (begin
      (while (>= bit 0)
        (let
          [cand : u64 (+ q (shl (cast 1 : u64) bit))]
          [prod : BigNum (bn-mul-u64 den cand)]
          (begin
            (if (<= (bn-cmp (& prod) num) 0)
              (set! q cand)
              unit)
            (set! bit (- bit 1)))))
      q)))

;: floor(a / b) for b > 0 (TL `/` truncates toward zero).
(define (ftoa-floor-div [a : i64] [b : i64]) : i64
  (if (>= a 0)
    (/ a b)
    (- 0 (/ (+ (- 0 a) (- b 1)) b))))

;: Index of the highest set bit of m.
(define (ftoa-msb-index [m : u64]) : i64
  (let
    [i : i64 0]
    [v : u64 m]
    (begin
      (while (> v (cast 1 : u64))
        (begin
          (set! v (shr v 1))
          (set! i (+ i 1))))
      i)))

;: Significant-digit string of d with trailing zeros removed (>= 1 digit).
(define (ftoa-strip-zeros [d : i64]) : String
  (let
    [dd : i64 d]
    (begin
      (while (and (> dd 9) (= (% dd 10) 0))
        (set! dd (/ dd 10)))
      (string.int->string dd))))

;: Exponent k formatted with sign and at least two digits.
(define (ftoa-pad-exp [k : i64]) : String
  (let
    [mag : i64
      (if (< k 0)
        (- 0 k)
        k)]
    [digits : String (string.int->string mag)]
    [sign : String
      (if (< k 0)
        "-"
        "+")]
    (str_cat.str-cat
      sign
      (if (< (string-length digits) 2)
        (str_cat.str-cat "0" digits "")
        digits)
      "")))

;: A string of n zero characters.
(define (format-array-const-ptr [buf : (__tl_dyn-array u8)]) : (Ptr u8)
  (unsafe
    (ptr-cast (array-data buf) : (Ptr u8))))

;: A string of n zero characters.
(define (ftoa-zeros [n : i64]) : String
  (let
    [out : (__tl_dyn-array u8) (array.make-array u8 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref out i) (cast '0' : u8))
          (set! i (+ i 1))))
      (unsafe
        (string-from-bytes (format-array-const-ptr out) n)))))

;: Format significant-digit string s whose leading digit has decimal exponent k.
(define (ftoa-render [neg : bool] [s : String] [k : i64]) : String
  (let
    [body : String ""]
    [ndig : i64 (string-length s)]
    (begin
      (cond
        [(or (< k -4) (>= k 17))
          (set!
            body
            (str_cat.str-cat
              (string.substring s 0 1)
              (if (> ndig 1)
                (str_cat.str-cat "." (string.substring s 1 (- ndig 1)) "")
                "")
              "e"
              (stdlib.format.ftoa-pad-exp k)))]
        [(< k 0)
          (set!
            body
            (str_cat.str-cat "0." (stdlib.format.ftoa-zeros (- (- 0 k) 1)) s))]
        [(>= (+ k 1) ndig)
          (set!
            body
            (str_cat.str-cat s (stdlib.format.ftoa-zeros (- (+ k 1) ndig)) ""))]
        [else
          (set!
            body
            (str_cat.str-cat
              (string.substring s 0 (+ k 1))
              "."
              (string.substring s (+ k 1) (- ndig (+ k 1)))))])
      (if neg
        (str_cat.str-cat "-" body "")
        body))))

;: Render an f64 as a shortest round-tripping decimal string.
(define (format-float-core [value : f64]) : String
  (let
    [buf : (__tl_dyn-array f64) (array.make-array f64 1)]
    (begin
      (set! (array-ref buf 0) value)
      (let
        [bits : u64
          (unsafe
            (ptr-read (ptr-cast (array-data buf) : (Ptr u64))))]
        [neg : bool (= (bit-and (shr bits 63) (cast 1 : u64)) (cast 1 : u64))]
        [expf : u64 (bit-and (shr bits 52) (cast 0x7ff : u64))]
        [frac : u64 (bit-and bits 0xfffffffffffff)]
        (begin
          (when
            (= expf (cast 0x7ff : u64))
            (return
              (if (= frac (cast 0 : u64))
                (if neg
                  "-inf"
                  "inf")
                (if neg
                  "-nan"
                  "nan"))))
          (when
            (and (= expf (cast 0 : u64)) (= frac (cast 0 : u64)))
            (return
              (if neg
                "-0"
                "0")))
          (let
            [m : u64
              (if (= expf (cast 0 : u64))
                frac
                (bit-or frac 0x10000000000000))]
            [e2 : i64
              (if (= expf (cast 0 : u64))
                -1074
                (- (cast expf : i64) 1075))]
            [msb : i64 (stdlib.format.ftoa-msb-index m)]
            [kest : i64
              (stdlib.format.ftoa-floor-div (* (+ msb e2) 30103) 100000)]
            [d : u64 (cast 0 : u64)]
            [iters : i64 0]
            [settled : bool false]
            (begin
              (while (if (not settled)
                (< iters 6)
                false)
                (let
                  [p : i64 (- 16 kest)]
                  [num : BigNum (stdlib.format.bn-from-u64 m)]
                  [den : BigNum (stdlib.format.bn-from-u64 (cast 1 : u64))]
                  (begin
                    (if (>= e2 0)
                      (set! num (stdlib.format.bn-shl-bits num e2))
                      (set! den (stdlib.format.bn-shl-bits den (- 0 e2))))
                    (if (>= p 0)
                      (set! num (stdlib.format.bn-mul-pow10 num p))
                      (set! den (stdlib.format.bn-mul-pow10 den (- 0 p))))
                    (let
                      [q : u64 (stdlib.format.bn-div-floor-u64 (& num) (& den))]
                      [two-num : BigNum (stdlib.format.bn-shl-bits num 1)]
                      [t : BigNum
                        (stdlib.format.bn-mul-u64
                          (& den)
                          (+ (* (cast 2 : u64) q) (cast 1 : u64)))]
                      [c : i64 (stdlib.format.bn-cmp (& two-num) (& t))]
                      (begin
                        (set! d q)
                        (if (> c 0)
                          (set! d (+ q (cast 1 : u64)))
                          (if (= c 0)
                            (if (= (bit-and q (cast 1 : u64)) (cast 1 : u64))
                              (set! d (+ q (cast 1 : u64)))
                              unit)
                            unit))
                        (if (>= d 100000000000000000)
                          (set! kest (+ kest 1))
                          (if (< d 10000000000000000)
                            (set! kest (- kest 1))
                            (set! settled true)))
                        (set! iters (+ iters 1)))))))
              (let
                [s0 : String (string.int->string (cast d : i64))]
                [k : i64 (+ (- (string-length s0) 17) kest)]
                (stdlib.format.ftoa-render
                  neg
                  (stdlib.format.ftoa-strip-zeros (cast d : i64))
                  k)))))))))