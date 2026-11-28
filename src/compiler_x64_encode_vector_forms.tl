;; Opcode forms for the final AT&T vector dialect. Rows are sorted by
;; mnemonic, with VEX forms preceding their EVEX equivalents.
;;
;; Operand signatures are in AT&T order: x/y/z are 128/256/512-bit vector
;; registers, d/q are 32/64-bit GPRs, k is an opmask register, i is an imm8,
;; m is ordinary memory, and s/t/u are memory with a 128/256/512-bit VSIB index.
;; Each row shares one opcode, map, mandatory prefix (0/66/F3/F2), and W bit.
;; Fields select operand positions (zero-based) for ModRM.reg, ModRM.r/m,
;; and vvvv. A negative reg position means /digit (-1 is /0). A vvvv of -1
;; leaves the reserved prefix bits set. The immediate is -1 for absent, 0
;; for an imm8 at operand zero, or a positive one-based /is4 register slot.
;; L of -1 follows the widest vector operand or VSIB index. Displacement
;; scale -1 is the full vector width. Mask modes are none, merge, merge or
;; zero, and required merge (gather), respectively.
(defenum VectorPrefix
  (Legacy)
  (Vex)
  (Evex))

(defstruct Fields
  (reg i64)
  (rm i64)
  (vvvv i64)
  (immediate i64)
  (length i64)
  (disp-scale i64)
  (mask i64))

(defstruct VectorForm
  (name String)
  (signatures String)
  (kind VectorPrefix)
  (map i64)
  (pp i64)
  (w i64)
  (opcode i64)
  (fields Fields))

(define vector-forms : (Array VectorForm 467)
  (array
    (VectorForm "addpd" "mx xx" (Legacy) 1 1 0 0x58 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "addps" "mx xx" (Legacy) 1 0 0 0x58 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "addsd" "mx xx" (Legacy) 1 3 0 0x58 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "addss" "mx xx" (Legacy) 1 2 0 0x58 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cmppd" "imx ixx" (Legacy) 1 1 0 0xc2 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "cmpps" "imx ixx" (Legacy) 1 0 0 0xc2 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "comiss" "mx xx" (Legacy) 1 0 0 0x2f (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvtsd2ss" "mx xx" (Legacy) 1 3 0 0x5a (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvtsi2sd" "dx mx" (Legacy) 1 3 0 0x2a (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvtsi2sd" "qx" (Legacy) 1 3 1 0x2a (Fields 1 0 -1 -1 0 1 0))
    (VectorForm
      "cvtsi2sdl"
      "dx mx"
      (Legacy)
      1
      3
      0
      0x2a
      (Fields 1 0 -1 -1 0 1 0))
    (VectorForm
      "cvtsi2sdq"
      "mx qx"
      (Legacy)
      1
      3
      1
      0x2a
      (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvtsi2ss" "dx mx" (Legacy) 1 2 0 0x2a (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvtsi2ss" "qx" (Legacy) 1 2 1 0x2a (Fields 1 0 -1 -1 0 1 0))
    (VectorForm
      "cvtsi2ssl"
      "dx mx"
      (Legacy)
      1
      2
      0
      0x2a
      (Fields 1 0 -1 -1 0 1 0))
    (VectorForm
      "cvtsi2ssq"
      "mx qx"
      (Legacy)
      1
      2
      1
      0x2a
      (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvtss2sd" "mx xx" (Legacy) 1 2 0 0x5a (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvttsd2si" "xd" (Legacy) 1 3 0 0x2c (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvttsd2si" "xq" (Legacy) 1 3 1 0x2c (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvttsd2sil" "xd" (Legacy) 1 3 0 0x2c (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvttsd2siq" "xq" (Legacy) 1 3 1 0x2c (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvttss2si" "xd" (Legacy) 1 2 0 0x2c (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvttss2si" "xq" (Legacy) 1 2 1 0x2c (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvttss2sil" "xd" (Legacy) 1 2 0 0x2c (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "cvttss2siq" "xq" (Legacy) 1 2 1 0x2c (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "divpd" "mx xx" (Legacy) 1 1 0 0x5e (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "divps" "mx xx" (Legacy) 1 0 0 0x5e (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "divsd" "mx xx" (Legacy) 1 3 0 0x5e (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "divss" "mx xx" (Legacy) 1 2 0 0x5e (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kandb" "kkk" (Vex) 1 1 0 0x41 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kandd" "kkk" (Vex) 1 1 1 0x41 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kandnb" "kkk" (Vex) 1 1 0 0x42 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kandnd" "kkk" (Vex) 1 1 1 0x42 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kandnq" "kkk" (Vex) 1 0 1 0x42 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kandnw" "kkk" (Vex) 1 0 0 0x42 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kandq" "kkk" (Vex) 1 0 1 0x41 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kandw" "kkk" (Vex) 1 0 0 0x41 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kmovb" "kk mk" (Vex) 1 1 0 0x90 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kmovb" "km" (Vex) 1 1 0 0x91 (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "kmovb" "dk" (Vex) 1 1 0 0x92 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kmovb" "kd" (Vex) 1 1 0 0x93 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kmovd" "kk mk" (Vex) 1 1 1 0x90 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kmovd" "km" (Vex) 1 1 1 0x91 (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "kmovd" "dk" (Vex) 1 3 0 0x92 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kmovd" "kd" (Vex) 1 3 0 0x93 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kmovq" "kk mk" (Vex) 1 0 1 0x90 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kmovq" "km" (Vex) 1 0 1 0x91 (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "kmovq" "qk" (Vex) 1 3 1 0x92 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kmovq" "kq" (Vex) 1 3 1 0x93 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kmovw" "kk mk" (Vex) 1 0 0 0x90 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kmovw" "km" (Vex) 1 0 0 0x91 (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "kmovw" "dk" (Vex) 1 0 0 0x92 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kmovw" "kd" (Vex) 1 0 0 0x93 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "knotb" "kk" (Vex) 1 1 0 0x44 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "knotd" "kk" (Vex) 1 1 1 0x44 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "knotq" "kk" (Vex) 1 0 1 0x44 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "knotw" "kk" (Vex) 1 0 0 0x44 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "korb" "kkk" (Vex) 1 1 0 0x45 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kord" "kkk" (Vex) 1 1 1 0x45 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "korq" "kkk" (Vex) 1 0 1 0x45 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kortestb" "kk" (Vex) 1 1 0 0x98 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kortestd" "kk" (Vex) 1 1 1 0x98 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kortestq" "kk" (Vex) 1 0 1 0x98 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kortestw" "kk" (Vex) 1 0 0 0x98 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "korw" "kkk" (Vex) 1 0 0 0x45 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kshiftlb" "ikk" (Vex) 3 1 0 0x32 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "kshiftld" "ikk" (Vex) 3 1 0 0x33 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "kshiftlq" "ikk" (Vex) 3 1 1 0x33 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "kshiftlw" "ikk" (Vex) 3 1 1 0x32 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "kshiftrb" "ikk" (Vex) 3 1 0 0x30 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "kshiftrd" "ikk" (Vex) 3 1 0 0x31 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "kshiftrq" "ikk" (Vex) 3 1 1 0x31 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "kshiftrw" "ikk" (Vex) 3 1 1 0x30 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "ktestb" "kk" (Vex) 1 1 0 0x99 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "ktestd" "kk" (Vex) 1 1 1 0x99 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "ktestq" "kk" (Vex) 1 0 1 0x99 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "ktestw" "kk" (Vex) 1 0 0 0x99 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "kxnorb" "kkk" (Vex) 1 1 0 0x46 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kxnord" "kkk" (Vex) 1 1 1 0x46 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kxnorq" "kkk" (Vex) 1 0 1 0x46 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kxnorw" "kkk" (Vex) 1 0 0 0x46 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kxorb" "kkk" (Vex) 1 1 0 0x47 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kxord" "kkk" (Vex) 1 1 1 0x47 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kxorq" "kkk" (Vex) 1 0 1 0x47 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "kxorw" "kkk" (Vex) 1 0 0 0x47 (Fields 2 0 1 -1 1 1 0))
    (VectorForm "maxps" "mx xx" (Legacy) 1 0 0 0x5f (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "maxsd" "mx xx" (Legacy) 1 3 0 0x5f (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "maxss" "mx xx" (Legacy) 1 2 0 0x5f (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "minps" "mx xx" (Legacy) 1 0 0 0x5d (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "minsd" "mx xx" (Legacy) 1 3 0 0x5d (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "minss" "mx xx" (Legacy) 1 2 0 0x5d (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movapd" "mx xx" (Legacy) 1 1 0 0x28 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movapd" "xm" (Legacy) 1 1 0 0x29 (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "movaps" "mx xx" (Legacy) 1 0 0 0x28 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movaps" "xm" (Legacy) 1 0 0 0x29 (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "movd" "dx mx" (Legacy) 1 1 0 0x6e (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movd" "xd xm" (Legacy) 1 1 0 0x7e (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "movd" "qx" (Legacy) 1 1 1 0x6e (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movd" "xq" (Legacy) 1 1 1 0x7e (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "movdqa" "mx xx" (Legacy) 1 1 0 0x6f (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movdqa" "xm" (Legacy) 1 1 0 0x7f (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "movdqu" "mx xx" (Legacy) 1 2 0 0x6f (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movdqu" "xm" (Legacy) 1 2 0 0x7f (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "movmskpd" "xd xq" (Legacy) 1 1 0 0x50 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movmskps" "xd xq" (Legacy) 1 0 0 0x50 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movq" "xm" (Legacy) 1 1 0 0xd6 (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "movq" "qx" (Legacy) 1 1 1 0x6e (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movq" "xq" (Legacy) 1 1 1 0x7e (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "movq" "mx xx" (Legacy) 1 2 0 0x7e (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movsd" "mx xx" (Legacy) 1 3 0 0x10 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movsd" "xm" (Legacy) 1 3 0 0x11 (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "movss" "mx xx" (Legacy) 1 2 0 0x10 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movss" "xm" (Legacy) 1 2 0 0x11 (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "movupd" "mx xx" (Legacy) 1 1 0 0x10 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movupd" "xm" (Legacy) 1 1 0 0x11 (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "movups" "mx xx" (Legacy) 1 0 0 0x10 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "movups" "xm" (Legacy) 1 0 0 0x11 (Fields 0 1 -1 -1 0 1 0))
    (VectorForm "mulpd" "mx xx" (Legacy) 1 1 0 0x59 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "mulps" "mx xx" (Legacy) 1 0 0 0x59 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "mulsd" "mx xx" (Legacy) 1 3 0 0x59 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "mulss" "mx xx" (Legacy) 1 2 0 0x59 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "packuswb" "mx xx" (Legacy) 1 1 0 0x67 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "paddb" "mx xx" (Legacy) 1 1 0 0xfc (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "paddd" "mx xx" (Legacy) 1 1 0 0xfe (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "paddq" "mx xx" (Legacy) 1 1 0 0xd4 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "paddw" "mx xx" (Legacy) 1 1 0 0xfd (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pand" "mx xx" (Legacy) 1 1 0 0xdb (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pandn" "mx xx" (Legacy) 1 1 0 0xdf (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pcmpeqb" "mx xx" (Legacy) 1 1 0 0x74 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pcmpeqd" "mx xx" (Legacy) 1 1 0 0x76 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pcmpeqw" "mx xx" (Legacy) 1 1 0 0x75 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pcmpgtb" "mx xx" (Legacy) 1 1 0 0x64 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pcmpgtd" "mx xx" (Legacy) 1 1 0 0x66 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pcmpgtw" "mx xx" (Legacy) 1 1 0 0x65 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm
      "pextrb"
      "ixd ixm ixq"
      (Legacy)
      3
      1
      0
      0x14
      (Fields 1 2 -1 0 0 1 0))
    (VectorForm "pextrd" "ixd ixm" (Legacy) 3 1 0 0x16 (Fields 1 2 -1 0 0 1 0))
    (VectorForm "pextrq" "ixm ixq" (Legacy) 3 1 1 0x16 (Fields 1 2 -1 0 0 1 0))
    (VectorForm "pextrw" "ixd ixq" (Legacy) 1 1 0 0xc5 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "pextrw" "ixm" (Legacy) 3 1 0 0x15 (Fields 1 2 -1 0 0 1 0))
    (VectorForm
      "pinsrb"
      "idx imx iqx"
      (Legacy)
      3
      1
      0
      0x20
      (Fields 2 1 -1 0 0 1 0))
    (VectorForm "pinsrd" "idx imx" (Legacy) 3 1 0 0x22 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "pinsrq" "imx iqx" (Legacy) 3 1 1 0x22 (Fields 2 1 -1 0 0 1 0))
    (VectorForm
      "pinsrw"
      "idx imx iqx"
      (Legacy)
      1
      1
      0
      0xc4
      (Fields 2 1 -1 0 0 1 0))
    (VectorForm "pmovmskb" "xd xq" (Legacy) 1 1 0 0xd7 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pmovsxbd" "mx xx" (Legacy) 2 1 0 0x21 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pmovsxbw" "mx xx" (Legacy) 2 1 0 0x20 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pmovzxbd" "mx xx" (Legacy) 2 1 0 0x31 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pmovzxbw" "mx xx" (Legacy) 2 1 0 0x30 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pmullw" "mx xx" (Legacy) 1 1 0 0xd5 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pmuludq" "mx xx" (Legacy) 1 1 0 0xf4 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "por" "mx xx" (Legacy) 1 1 0 0xeb (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pshufb" "mx xx" (Legacy) 2 1 0 0x00 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pshufd" "imx ixx" (Legacy) 1 1 0 0x70 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "pslld" "ix" (Legacy) 1 1 0 0x72 (Fields -7 1 -1 0 0 1 0))
    (VectorForm "pslld" "mx xx" (Legacy) 1 1 0 0xf2 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pslldq" "ix" (Legacy) 1 1 0 0x73 (Fields -8 1 -1 0 0 1 0))
    (VectorForm "psllq" "ix" (Legacy) 1 1 0 0x73 (Fields -7 1 -1 0 0 1 0))
    (VectorForm "psllq" "mx xx" (Legacy) 1 1 0 0xf3 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "psllw" "ix" (Legacy) 1 1 0 0x71 (Fields -7 1 -1 0 0 1 0))
    (VectorForm "psllw" "mx xx" (Legacy) 1 1 0 0xf1 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "psrad" "ix" (Legacy) 1 1 0 0x72 (Fields -5 1 -1 0 0 1 0))
    (VectorForm "psrad" "mx xx" (Legacy) 1 1 0 0xe2 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "psraw" "ix" (Legacy) 1 1 0 0x71 (Fields -5 1 -1 0 0 1 0))
    (VectorForm "psraw" "mx xx" (Legacy) 1 1 0 0xe1 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "psrld" "ix" (Legacy) 1 1 0 0x72 (Fields -3 1 -1 0 0 1 0))
    (VectorForm "psrld" "mx xx" (Legacy) 1 1 0 0xd2 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "psrldq" "ix" (Legacy) 1 1 0 0x73 (Fields -4 1 -1 0 0 1 0))
    (VectorForm "psrlq" "ix" (Legacy) 1 1 0 0x73 (Fields -3 1 -1 0 0 1 0))
    (VectorForm "psrlq" "mx xx" (Legacy) 1 1 0 0xd3 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "psrlw" "ix" (Legacy) 1 1 0 0x71 (Fields -3 1 -1 0 0 1 0))
    (VectorForm "psrlw" "mx xx" (Legacy) 1 1 0 0xd1 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "psubb" "mx xx" (Legacy) 1 1 0 0xf8 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "psubd" "mx xx" (Legacy) 1 1 0 0xfa (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "psubq" "mx xx" (Legacy) 1 1 0 0xfb (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "psubw" "mx xx" (Legacy) 1 1 0 0xf9 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "ptest" "mx xx" (Legacy) 2 1 0 0x17 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm
      "punpcklbw"
      "mx xx"
      (Legacy)
      1
      1
      0
      0x60
      (Fields 1 0 -1 -1 0 1 0))
    (VectorForm
      "punpckldq"
      "mx xx"
      (Legacy)
      1
      1
      0
      0x62
      (Fields 1 0 -1 -1 0 1 0))
    (VectorForm
      "punpcklqdq"
      "mx xx"
      (Legacy)
      1
      1
      0
      0x6c
      (Fields 1 0 -1 -1 0 1 0))
    (VectorForm
      "punpcklwd"
      "mx xx"
      (Legacy)
      1
      1
      0
      0x61
      (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "pxor" "mx xx" (Legacy) 1 1 0 0xef (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "shufps" "imx ixx" (Legacy) 1 0 0 0xc6 (Fields 2 1 -1 0 0 1 0))
    (VectorForm "sqrtsd" "mx xx" (Legacy) 1 3 0 0x51 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "sqrtss" "mx xx" (Legacy) 1 2 0 0x51 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "subpd" "mx xx" (Legacy) 1 1 0 0x5c (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "subps" "mx xx" (Legacy) 1 0 0 0x5c (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "subsd" "mx xx" (Legacy) 1 3 0 0x5c (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "subss" "mx xx" (Legacy) 1 2 0 0x5c (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "ucomisd" "mx xx" (Legacy) 1 1 0 0x2e (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "ucomiss" "mx xx" (Legacy) 1 0 0 0x2e (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "unpckhpd" "mx xx" (Legacy) 1 1 0 0x15 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "unpckhps" "mx xx" (Legacy) 1 0 0 0x15 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "unpcklpd" "mx xx" (Legacy) 1 1 0 0x14 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "unpcklps" "mx xx" (Legacy) 1 0 0 0x14 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm
      "vaddpd"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0x58
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vaddpd"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      1
      0x58
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vaddps"
      "mxx myy xxx yyy"
      (Vex)
      1
      0
      0
      0x58
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vaddps"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      0
      0
      0x58
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm "vaddsd" "mxx xxx" (Vex) 1 3 0 0x58 (Fields 2 0 1 -1 -1 1 0))
    (VectorForm "vaddsd" "mxx xxx" (Evex) 1 3 1 0x58 (Fields 2 0 1 -1 -1 8 2))
    (VectorForm "vaddss" "mxx xxx" (Vex) 1 2 0 0x58 (Fields 2 0 1 -1 -1 1 0))
    (VectorForm "vaddss" "mxx xxx" (Evex) 1 2 0 0x58 (Fields 2 0 1 -1 -1 4 2))
    (VectorForm
      "valignd"
      "imxx imyy imzz ixxx iyyy izzz"
      (Evex)
      3
      1
      0
      0x03
      (Fields 3 1 2 0 -1 -1 2))
    (VectorForm
      "valignq"
      "imxx imyy imzz ixxx iyyy izzz"
      (Evex)
      3
      1
      1
      0x03
      (Fields 3 1 2 0 -1 -1 2))
    (VectorForm
      "vblendvpd"
      "xmxx xxxx ymyy yyyy"
      (Vex)
      3
      1
      0
      0x4b
      (Fields 3 1 2 1 -1 1 0))
    (VectorForm
      "vbroadcastf128"
      "my"
      (Vex)
      2
      1
      0
      0x1a
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vbroadcasti128"
      "my"
      (Vex)
      2
      1
      0
      0x5a
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vbroadcastsd"
      "my xy"
      (Vex)
      2
      1
      0
      0x19
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vbroadcastsd"
      "my mz xy xz"
      (Evex)
      2
      1
      1
      0x19
      (Fields 1 0 -1 -1 -1 8 2))
    (VectorForm
      "vbroadcastss"
      "mx my xx xy"
      (Vex)
      2
      1
      0
      0x18
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vbroadcastss"
      "mx my mz xx xy xz"
      (Evex)
      2
      1
      0
      0x18
      (Fields 1 0 -1 -1 -1 4 2))
    (VectorForm
      "vcmppd"
      "imxx imyy ixxx iyyy"
      (Vex)
      1
      1
      0
      0xc2
      (Fields 3 1 2 0 -1 1 0))
    (VectorForm
      "vcmppd"
      "imxk imyk imzk ixxk iyyk izzk"
      (Evex)
      1
      1
      1
      0xc2
      (Fields 3 1 2 0 -1 -1 1))
    (VectorForm
      "vcmpps"
      "imxx imyy ixxx iyyy"
      (Vex)
      1
      0
      0
      0xc2
      (Fields 3 1 2 0 -1 1 0))
    (VectorForm
      "vcmpps"
      "imxk imyk imzk ixxk iyyk izzk"
      (Evex)
      1
      0
      0
      0xc2
      (Fields 3 1 2 0 -1 -1 1))
    (VectorForm
      "vextractf128"
      "iym iyx"
      (Vex)
      3
      1
      0
      0x19
      (Fields 1 2 -1 0 -1 1 0))
    (VectorForm
      "vextractf32x8"
      "izm"
      (Evex)
      3
      1
      0
      0x1b
      (Fields 1 2 -1 0 -1 32 1))
    (VectorForm
      "vextractf32x8"
      "izy"
      (Evex)
      3
      1
      0
      0x1b
      (Fields 1 2 -1 0 -1 1 2))
    (VectorForm
      "vextractf64x4"
      "izm"
      (Evex)
      3
      1
      1
      0x1b
      (Fields 1 2 -1 0 -1 32 1))
    (VectorForm
      "vextractf64x4"
      "izy"
      (Evex)
      3
      1
      1
      0x1b
      (Fields 1 2 -1 0 -1 1 2))
    (VectorForm
      "vextracti128"
      "iym iyx"
      (Vex)
      3
      1
      0
      0x39
      (Fields 1 2 -1 0 -1 1 0))
    (VectorForm
      "vextracti32x4"
      "iym izm"
      (Evex)
      3
      1
      0
      0x39
      (Fields 1 2 -1 0 -1 16 1))
    (VectorForm
      "vextracti32x4"
      "iyx izx"
      (Evex)
      3
      1
      0
      0x39
      (Fields 1 2 -1 0 -1 1 2))
    (VectorForm
      "vextracti64x4"
      "izm"
      (Evex)
      3
      1
      1
      0x3b
      (Fields 1 2 -1 0 -1 32 1))
    (VectorForm
      "vextracti64x4"
      "izy"
      (Evex)
      3
      1
      1
      0x3b
      (Fields 1 2 -1 0 -1 1 2))
    (VectorForm
      "vgatherqpd"
      "xsx yty"
      (Vex)
      2
      1
      1
      0x93
      (Fields 2 1 0 -1 -1 1 0))
    (VectorForm
      "vgatherqpd"
      "sx ty uz"
      (Evex)
      2
      1
      1
      0x93
      (Fields 1 0 -1 -1 -1 8 3))
    (VectorForm
      "vgatherqps"
      "xsx xtx"
      (Vex)
      2
      1
      0
      0x93
      (Fields 2 1 0 -1 -1 1 0))
    (VectorForm
      "vgatherqps"
      "sx tx uy"
      (Evex)
      2
      1
      0
      0x93
      (Fields 1 0 -1 -1 -1 4 3))
    (VectorForm "vmaskmovdqu" "xx" (Vex) 1 1 0 0xf7 (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vmaskmovpd"
      "mxx myy"
      (Vex)
      2
      1
      0
      0x2d
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vmaskmovpd"
      "xxm yym"
      (Vex)
      2
      1
      0
      0x2f
      (Fields 0 2 1 -1 -1 1 0))
    (VectorForm
      "vmaskmovps"
      "mxx myy"
      (Vex)
      2
      1
      0
      0x2c
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vmaskmovps"
      "xxm yym"
      (Vex)
      2
      1
      0
      0x2e
      (Fields 0 2 1 -1 -1 1 0))
    (VectorForm "vmovd" "dx mx" (Vex) 1 1 0 0x6e (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm "vmovd" "xd xm" (Vex) 1 1 0 0x7e (Fields 0 1 -1 -1 -1 1 0))
    (VectorForm "vmovd" "qx" (Vex) 1 1 1 0x6e (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm "vmovd" "xq" (Vex) 1 1 1 0x7e (Fields 0 1 -1 -1 -1 1 0))
    (VectorForm "vmovd" "dx mx" (Evex) 1 1 0 0x6e (Fields 1 0 -1 -1 -1 4 0))
    (VectorForm "vmovd" "xd xm" (Evex) 1 1 0 0x7e (Fields 0 1 -1 -1 -1 4 0))
    (VectorForm "vmovd" "xx" (Evex) 1 2 0 0x7e (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vmovdqa"
      "mx my xx yy"
      (Vex)
      1
      1
      0
      0x6f
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm "vmovdqa" "xm ym" (Vex) 1 1 0 0x7f (Fields 0 1 -1 -1 -1 1 0))
    (VectorForm
      "vmovdqa64"
      "mx my mz xx yy zz"
      (Evex)
      1
      1
      1
      0x6f
      (Fields 1 0 -1 -1 -1 -1 2))
    (VectorForm
      "vmovdqa64"
      "xm ym zm"
      (Evex)
      1
      1
      1
      0x7f
      (Fields 0 1 -1 -1 -1 -1 1))
    (VectorForm
      "vmovdqu"
      "mx my xx yy"
      (Vex)
      1
      2
      0
      0x6f
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm "vmovdqu" "xm ym" (Vex) 1 2 0 0x7f (Fields 0 1 -1 -1 -1 1 0))
    (VectorForm
      "vmovdqu16"
      "mx my mz xx yy zz"
      (Evex)
      1
      3
      1
      0x6f
      (Fields 1 0 -1 -1 -1 -1 2))
    (VectorForm
      "vmovdqu16"
      "xm ym zm"
      (Evex)
      1
      3
      1
      0x7f
      (Fields 0 1 -1 -1 -1 -1 1))
    (VectorForm
      "vmovdqu32"
      "mx my mz xx yy zz"
      (Evex)
      1
      2
      0
      0x6f
      (Fields 1 0 -1 -1 -1 -1 2))
    (VectorForm
      "vmovdqu32"
      "xm ym zm"
      (Evex)
      1
      2
      0
      0x7f
      (Fields 0 1 -1 -1 -1 -1 1))
    (VectorForm
      "vmovdqu64"
      "mx my mz xx yy zz"
      (Evex)
      1
      2
      1
      0x6f
      (Fields 1 0 -1 -1 -1 -1 2))
    (VectorForm
      "vmovdqu64"
      "xm ym zm"
      (Evex)
      1
      2
      1
      0x7f
      (Fields 0 1 -1 -1 -1 -1 1))
    (VectorForm
      "vmovdqu8"
      "mx my mz xx yy zz"
      (Evex)
      1
      3
      0
      0x6f
      (Fields 1 0 -1 -1 -1 -1 2))
    (VectorForm
      "vmovdqu8"
      "xm ym zm"
      (Evex)
      1
      3
      0
      0x7f
      (Fields 0 1 -1 -1 -1 -1 1))
    (VectorForm "vmovq" "xm" (Vex) 1 1 0 0xd6 (Fields 0 1 -1 -1 -1 1 0))
    (VectorForm "vmovq" "qx" (Vex) 1 1 1 0x6e (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm "vmovq" "xq" (Vex) 1 1 1 0x7e (Fields 0 1 -1 -1 -1 1 0))
    (VectorForm "vmovq" "mx xx" (Vex) 1 2 0 0x7e (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm "vmovq" "mx qx" (Evex) 1 1 1 0x6e (Fields 1 0 -1 -1 -1 8 0))
    (VectorForm "vmovq" "xm xq" (Evex) 1 1 1 0x7e (Fields 0 1 -1 -1 -1 8 0))
    (VectorForm "vmovq" "xx" (Evex) 1 2 1 0x7e (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vmovupd"
      "mx my xx yy"
      (Vex)
      1
      1
      0
      0x10
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm "vmovupd" "xm ym" (Vex) 1 1 0 0x11 (Fields 0 1 -1 -1 -1 1 0))
    (VectorForm
      "vmovupd"
      "mx my mz xx yy zz"
      (Evex)
      1
      1
      1
      0x10
      (Fields 1 0 -1 -1 -1 -1 2))
    (VectorForm
      "vmovupd"
      "xm ym zm"
      (Evex)
      1
      1
      1
      0x11
      (Fields 0 1 -1 -1 -1 -1 1))
    (VectorForm
      "vmovups"
      "mx my xx yy"
      (Vex)
      1
      0
      0
      0x10
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm "vmovups" "xm ym" (Vex) 1 0 0 0x11 (Fields 0 1 -1 -1 -1 1 0))
    (VectorForm
      "vmovups"
      "mx my mz xx yy zz"
      (Evex)
      1
      0
      0
      0x10
      (Fields 1 0 -1 -1 -1 -1 2))
    (VectorForm
      "vmovups"
      "xm ym zm"
      (Evex)
      1
      0
      0
      0x11
      (Fields 0 1 -1 -1 -1 -1 1))
    (VectorForm
      "vmulpd"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0x59
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vmulpd"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      1
      0x59
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vmulps"
      "mxx myy xxx yyy"
      (Vex)
      1
      0
      0
      0x59
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vmulps"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      0
      0
      0x59
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpabsb"
      "mx my xx yy"
      (Vex)
      2
      1
      0
      0x1c
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vpabsb"
      "mx my mz xx yy zz"
      (Evex)
      2
      1
      0
      0x1c
      (Fields 1 0 -1 -1 -1 -1 2))
    (VectorForm
      "vpackusdw"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      0
      0x2b
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpackusdw"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      0
      0x2b
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpackuswb"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0x67
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpackuswb"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0x67
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpaddb"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xfc
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpaddb"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0xfc
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpaddd"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xfe
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpaddd"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0xfe
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpaddq"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xd4
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpaddq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      1
      0xd4
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpaddw"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xfd
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpaddw"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0xfd
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpand"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xdb
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpandd"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0xdb
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpandn"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xdf
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpandnd"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0xdf
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpandnq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      1
      0xdf
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpandq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      1
      0xdb
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpblendd"
      "imxx imyy ixxx iyyy"
      (Vex)
      3
      1
      0
      0x02
      (Fields 3 1 2 0 -1 1 0))
    (VectorForm
      "vpblendvb"
      "xmxx xxxx ymyy yyyy"
      (Vex)
      3
      1
      0
      0x4c
      (Fields 3 1 2 1 -1 1 0))
    (VectorForm
      "vpbroadcastb"
      "mx my xx xy"
      (Vex)
      2
      1
      0
      0x78
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vpbroadcastb"
      "mx my mz xx xy xz"
      (Evex)
      2
      1
      0
      0x78
      (Fields 1 0 -1 -1 -1 1 2))
    (VectorForm
      "vpbroadcastb"
      "dx dy dz"
      (Evex)
      2
      1
      0
      0x7a
      (Fields 1 0 -1 -1 -1 1 2))
    (VectorForm
      "vpbroadcastd"
      "mx my xx xy"
      (Vex)
      2
      1
      0
      0x58
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vpbroadcastd"
      "mx my mz xx xy xz"
      (Evex)
      2
      1
      0
      0x58
      (Fields 1 0 -1 -1 -1 4 2))
    (VectorForm
      "vpbroadcastd"
      "dx dy dz"
      (Evex)
      2
      1
      0
      0x7c
      (Fields 1 0 -1 -1 -1 1 2))
    (VectorForm
      "vpbroadcastq"
      "mx my xx xy"
      (Vex)
      2
      1
      0
      0x59
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vpbroadcastq"
      "mx my mz xx xy xz"
      (Evex)
      2
      1
      1
      0x59
      (Fields 1 0 -1 -1 -1 8 2))
    (VectorForm
      "vpbroadcastq"
      "qx qy qz"
      (Evex)
      2
      1
      1
      0x7c
      (Fields 1 0 -1 -1 -1 1 2))
    (VectorForm
      "vpbroadcastw"
      "mx my xx xy"
      (Vex)
      2
      1
      0
      0x79
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vpbroadcastw"
      "mx my mz xx xy xz"
      (Evex)
      2
      1
      0
      0x79
      (Fields 1 0 -1 -1 -1 2 2))
    (VectorForm
      "vpbroadcastw"
      "dx dy dz"
      (Evex)
      2
      1
      0
      0x7b
      (Fields 1 0 -1 -1 -1 1 2))
    (VectorForm
      "vpcmpb"
      "imxk imyk imzk ixxk iyyk izzk"
      (Evex)
      3
      1
      0
      0x3f
      (Fields 3 1 2 0 -1 -1 1))
    (VectorForm
      "vpcmpd"
      "imxk imyk imzk ixxk iyyk izzk"
      (Evex)
      3
      1
      0
      0x1f
      (Fields 3 1 2 0 -1 -1 1))
    (VectorForm
      "vpcmpeqb"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0x74
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpcmpeqb"
      "mxk myk mzk xxk yyk zzk"
      (Evex)
      1
      1
      0
      0x74
      (Fields 2 0 1 -1 -1 -1 1))
    (VectorForm
      "vpcmpeqd"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0x76
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpcmpeqd"
      "mxk myk mzk xxk yyk zzk"
      (Evex)
      1
      1
      0
      0x76
      (Fields 2 0 1 -1 -1 -1 1))
    (VectorForm
      "vpcmpeqq"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      0
      0x29
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpcmpeqq"
      "mxk myk mzk xxk yyk zzk"
      (Evex)
      2
      1
      1
      0x29
      (Fields 2 0 1 -1 -1 -1 1))
    (VectorForm
      "vpcmpeqw"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0x75
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpcmpeqw"
      "mxk myk mzk xxk yyk zzk"
      (Evex)
      1
      1
      0
      0x75
      (Fields 2 0 1 -1 -1 -1 1))
    (VectorForm
      "vpcmpgtb"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0x64
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpcmpgtb"
      "mxk myk mzk xxk yyk zzk"
      (Evex)
      1
      1
      0
      0x64
      (Fields 2 0 1 -1 -1 -1 1))
    (VectorForm
      "vpcmpgtd"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0x66
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpcmpgtd"
      "mxk myk mzk xxk yyk zzk"
      (Evex)
      1
      1
      0
      0x66
      (Fields 2 0 1 -1 -1 -1 1))
    (VectorForm
      "vpcmpgtq"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      0
      0x37
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpcmpgtq"
      "mxk myk mzk xxk yyk zzk"
      (Evex)
      2
      1
      1
      0x37
      (Fields 2 0 1 -1 -1 -1 1))
    (VectorForm
      "vpcmpgtw"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0x65
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpcmpgtw"
      "mxk myk mzk xxk yyk zzk"
      (Evex)
      1
      1
      0
      0x65
      (Fields 2 0 1 -1 -1 -1 1))
    (VectorForm
      "vpcmpq"
      "imxk imyk imzk ixxk iyyk izzk"
      (Evex)
      3
      1
      1
      0x1f
      (Fields 3 1 2 0 -1 -1 1))
    (VectorForm
      "vpcmpub"
      "imxk imyk imzk ixxk iyyk izzk"
      (Evex)
      3
      1
      0
      0x3e
      (Fields 3 1 2 0 -1 -1 1))
    (VectorForm
      "vpcmpud"
      "imxk imyk imzk ixxk iyyk izzk"
      (Evex)
      3
      1
      0
      0x1e
      (Fields 3 1 2 0 -1 -1 1))
    (VectorForm
      "vpcmpuq"
      "imxk imyk imzk ixxk iyyk izzk"
      (Evex)
      3
      1
      1
      0x1e
      (Fields 3 1 2 0 -1 -1 1))
    (VectorForm
      "vpcmpuw"
      "imxk imyk imzk ixxk iyyk izzk"
      (Evex)
      3
      1
      1
      0x3e
      (Fields 3 1 2 0 -1 -1 1))
    (VectorForm
      "vpcmpw"
      "imxk imyk imzk ixxk iyyk izzk"
      (Evex)
      3
      1
      1
      0x3f
      (Fields 3 1 2 0 -1 -1 1))
    (VectorForm
      "vperm2i128"
      "imyy iyyy"
      (Vex)
      3
      1
      0
      0x46
      (Fields 3 1 2 0 -1 1 0))
    (VectorForm "vpermd" "myy yyy" (Vex) 2 1 0 0x36 (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpermd"
      "myy mzz yyy zzz"
      (Evex)
      2
      1
      0
      0x36
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm "vpermq" "imy iyy" (Vex) 3 1 1 0x00 (Fields 2 1 -1 0 -1 1 0))
    (VectorForm
      "vpermq"
      "myy mzz yyy zzz"
      (Evex)
      2
      1
      1
      0x36
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpermq"
      "imy imz iyy izz"
      (Evex)
      3
      1
      1
      0x00
      (Fields 2 1 -1 0 -1 -1 2))
    (VectorForm "vpextrd" "ixd ixm" (Vex) 3 1 0 0x16 (Fields 1 2 -1 0 -1 1 0))
    (VectorForm "vpextrd" "ixd ixm" (Evex) 3 1 0 0x16 (Fields 1 2 -1 0 -1 4 0))
    (VectorForm "vpextrq" "ixm ixq" (Vex) 3 1 1 0x16 (Fields 1 2 -1 0 -1 1 0))
    (VectorForm "vpextrq" "ixm ixq" (Evex) 3 1 1 0x16 (Fields 1 2 -1 0 -1 8 0))
    (VectorForm
      "vpgatherqd"
      "xsx xtx"
      (Vex)
      2
      1
      0
      0x91
      (Fields 2 1 0 -1 -1 1 0))
    (VectorForm
      "vpgatherqd"
      "sx tx uy"
      (Evex)
      2
      1
      0
      0x91
      (Fields 1 0 -1 -1 -1 4 3))
    (VectorForm
      "vpgatherqq"
      "xsx yty"
      (Vex)
      2
      1
      1
      0x91
      (Fields 2 1 0 -1 -1 1 0))
    (VectorForm
      "vpgatherqq"
      "sx ty uz"
      (Evex)
      2
      1
      1
      0x91
      (Fields 1 0 -1 -1 -1 8 3))
    (VectorForm
      "vpmaskmovd"
      "mxx myy"
      (Vex)
      2
      1
      0
      0x8c
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpmaskmovd"
      "xxm yym"
      (Vex)
      2
      1
      0
      0x8e
      (Fields 0 2 1 -1 -1 1 0))
    (VectorForm
      "vpmaskmovq"
      "mxx myy"
      (Vex)
      2
      1
      1
      0x8c
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpmaskmovq"
      "xxm yym"
      (Vex)
      2
      1
      1
      0x8e
      (Fields 0 2 1 -1 -1 1 0))
    (VectorForm
      "vpmaxsd"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      0
      0x3d
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpmaxsd"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      0
      0x3d
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpmaxsq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      1
      0x3d
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpminsb"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      0
      0x38
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpminsb"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      0
      0x38
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpminsd"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      0
      0x39
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpminsd"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      0
      0x39
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpminsq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      1
      0x39
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpminsw"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xea
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpminsw"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0xea
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpminub"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xda
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpminub"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0xda
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpminuw"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      0
      0x3a
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpminuw"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      0
      0x3a
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpmovmskb"
      "xd xq yd yq"
      (Vex)
      1
      1
      0
      0xd7
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vpmovsxbd"
      "mx my xx xy"
      (Vex)
      2
      1
      0
      0x21
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vpmovsxbd"
      "mx xx xy xz"
      (Evex)
      2
      1
      0
      0x21
      (Fields 1 0 -1 -1 -1 4 2))
    (VectorForm "vpmovsxbd" "my" (Evex) 2 1 0 0x21 (Fields 1 0 -1 -1 -1 8 2))
    (VectorForm "vpmovsxbd" "mz" (Evex) 2 1 0 0x21 (Fields 1 0 -1 -1 -1 16 2))
    (VectorForm
      "vpmovsxwd"
      "mx my xx xy"
      (Vex)
      2
      1
      0
      0x23
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vpmovsxwd"
      "mx xx xy yz"
      (Evex)
      2
      1
      0
      0x23
      (Fields 1 0 -1 -1 -1 8 2))
    (VectorForm "vpmovsxwd" "my" (Evex) 2 1 0 0x23 (Fields 1 0 -1 -1 -1 16 2))
    (VectorForm "vpmovsxwd" "mz" (Evex) 2 1 0 0x23 (Fields 1 0 -1 -1 -1 32 2))
    (VectorForm
      "vpmovzxbd"
      "mx my xx xy"
      (Vex)
      2
      1
      0
      0x31
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vpmovzxbd"
      "mx xx xy xz"
      (Evex)
      2
      1
      0
      0x31
      (Fields 1 0 -1 -1 -1 4 2))
    (VectorForm "vpmovzxbd" "my" (Evex) 2 1 0 0x31 (Fields 1 0 -1 -1 -1 8 2))
    (VectorForm "vpmovzxbd" "mz" (Evex) 2 1 0 0x31 (Fields 1 0 -1 -1 -1 16 2))
    (VectorForm
      "vpmovzxwd"
      "mx my xx xy"
      (Vex)
      2
      1
      0
      0x33
      (Fields 1 0 -1 -1 -1 1 0))
    (VectorForm
      "vpmovzxwd"
      "mx xx xy yz"
      (Evex)
      2
      1
      0
      0x33
      (Fields 1 0 -1 -1 -1 8 2))
    (VectorForm "vpmovzxwd" "my" (Evex) 2 1 0 0x33 (Fields 1 0 -1 -1 -1 16 2))
    (VectorForm "vpmovzxwd" "mz" (Evex) 2 1 0 0x33 (Fields 1 0 -1 -1 -1 32 2))
    (VectorForm
      "vpmulld"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      0
      0x40
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpmulld"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      0
      0x40
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpmullq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      1
      0x40
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpmullw"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xd5
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpmullw"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0xd5
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpmuludq"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xf4
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpmuludq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      1
      0xf4
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpor"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xeb
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpord"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0xeb
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vporq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      1
      0xeb
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpshufb"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      0
      0x00
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpshufb"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      0
      0x00
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpshufd"
      "imx imy ixx iyy"
      (Vex)
      1
      1
      0
      0x70
      (Fields 2 1 -1 0 -1 1 0))
    (VectorForm
      "vpshufd"
      "imx imy imz ixx iyy izz"
      (Evex)
      1
      1
      0
      0x70
      (Fields 2 1 -1 0 -1 -1 2))
    (VectorForm "vpslld" "ixx iyy" (Vex) 1 1 0 0x72 (Fields -7 1 2 0 -1 1 0))
    (VectorForm
      "vpslld"
      "mxx myy xxx xyy"
      (Vex)
      1
      1
      0
      0xf2
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpslld"
      "imx imy imz ixx iyy izz"
      (Evex)
      1
      1
      0
      0x72
      (Fields -7 1 2 0 -1 -1 2))
    (VectorForm
      "vpslld"
      "mxx xxx xyy xzz"
      (Evex)
      1
      1
      0
      0xf2
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm "vpslld" "myy mzz" (Evex) 1 1 0 0xf2 (Fields 2 0 1 -1 -1 16 2))
    (VectorForm "vpslldq" "ixx iyy" (Vex) 1 1 0 0x73 (Fields -8 1 2 0 -1 1 0))
    (VectorForm
      "vpslldq"
      "imx imy imz ixx iyy izz"
      (Evex)
      1
      1
      0
      0x73
      (Fields -8 1 2 0 -1 -1 0))
    (VectorForm "vpsllq" "ixx iyy" (Vex) 1 1 0 0x73 (Fields -7 1 2 0 -1 1 0))
    (VectorForm
      "vpsllq"
      "mxx myy xxx xyy"
      (Vex)
      1
      1
      0
      0xf3
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsllq"
      "imx imy imz ixx iyy izz"
      (Evex)
      1
      1
      1
      0x73
      (Fields -7 1 2 0 -1 -1 2))
    (VectorForm
      "vpsllq"
      "mxx xxx xyy xzz"
      (Evex)
      1
      1
      1
      0xf3
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm "vpsllq" "myy mzz" (Evex) 1 1 1 0xf3 (Fields 2 0 1 -1 -1 16 2))
    (VectorForm
      "vpsllvd"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      0
      0x47
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsllvd"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      0
      0x47
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpsllvq"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      1
      0x47
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsllvq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      1
      0x47
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpsllvw"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      1
      0x12
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm "vpsllw" "ixx iyy" (Vex) 1 1 0 0x71 (Fields -7 1 2 0 -1 1 0))
    (VectorForm
      "vpsllw"
      "mxx myy xxx xyy"
      (Vex)
      1
      1
      0
      0xf1
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsllw"
      "imx imy imz ixx iyy izz"
      (Evex)
      1
      1
      0
      0x71
      (Fields -7 1 2 0 -1 -1 2))
    (VectorForm
      "vpsllw"
      "mxx xxx xyy xzz"
      (Evex)
      1
      1
      0
      0xf1
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm "vpsllw" "myy mzz" (Evex) 1 1 0 0xf1 (Fields 2 0 1 -1 -1 16 2))
    (VectorForm
      "vpsravd"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      0
      0x46
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsravd"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      0
      0x46
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpsravq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      1
      0x46
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpsravw"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      1
      0x11
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm "vpsrld" "ixx iyy" (Vex) 1 1 0 0x72 (Fields -3 1 2 0 -1 1 0))
    (VectorForm
      "vpsrld"
      "mxx myy xxx xyy"
      (Vex)
      1
      1
      0
      0xd2
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsrld"
      "imx imy imz ixx iyy izz"
      (Evex)
      1
      1
      0
      0x72
      (Fields -3 1 2 0 -1 -1 2))
    (VectorForm
      "vpsrld"
      "mxx xxx xyy xzz"
      (Evex)
      1
      1
      0
      0xd2
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm "vpsrld" "myy mzz" (Evex) 1 1 0 0xd2 (Fields 2 0 1 -1 -1 16 2))
    (VectorForm "vpsrldq" "ixx iyy" (Vex) 1 1 0 0x73 (Fields -4 1 2 0 -1 1 0))
    (VectorForm
      "vpsrldq"
      "imx imy imz ixx iyy izz"
      (Evex)
      1
      1
      0
      0x73
      (Fields -4 1 2 0 -1 -1 0))
    (VectorForm "vpsrlq" "ixx iyy" (Vex) 1 1 0 0x73 (Fields -3 1 2 0 -1 1 0))
    (VectorForm
      "vpsrlq"
      "mxx myy xxx xyy"
      (Vex)
      1
      1
      0
      0xd3
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsrlq"
      "imx imy imz ixx iyy izz"
      (Evex)
      1
      1
      1
      0x73
      (Fields -3 1 2 0 -1 -1 2))
    (VectorForm
      "vpsrlq"
      "mxx xxx xyy xzz"
      (Evex)
      1
      1
      1
      0xd3
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm "vpsrlq" "myy mzz" (Evex) 1 1 1 0xd3 (Fields 2 0 1 -1 -1 16 2))
    (VectorForm
      "vpsrlvd"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      0
      0x45
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsrlvd"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      0
      0x45
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpsrlvq"
      "mxx myy xxx yyy"
      (Vex)
      2
      1
      1
      0x45
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsrlvq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      1
      0x45
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpsrlvw"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      2
      1
      1
      0x10
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm "vpsrlw" "ixx iyy" (Vex) 1 1 0 0x71 (Fields -3 1 2 0 -1 1 0))
    (VectorForm
      "vpsrlw"
      "mxx myy xxx xyy"
      (Vex)
      1
      1
      0
      0xd1
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsrlw"
      "imx imy imz ixx iyy izz"
      (Evex)
      1
      1
      0
      0x71
      (Fields -3 1 2 0 -1 -1 2))
    (VectorForm
      "vpsrlw"
      "mxx xxx xyy xzz"
      (Evex)
      1
      1
      0
      0xd1
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm "vpsrlw" "myy mzz" (Evex) 1 1 0 0xd1 (Fields 2 0 1 -1 -1 16 2))
    (VectorForm
      "vpsubb"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xf8
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsubb"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0xf8
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpsubd"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xfa
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsubd"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0xfa
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpsubq"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xfb
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsubq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      1
      0xfb
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpsubw"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xf9
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpsubw"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0xf9
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpternlogd"
      "imxx imyy imzz ixxx iyyy izzz"
      (Evex)
      3
      1
      0
      0x25
      (Fields 3 1 2 0 -1 -1 2))
    (VectorForm
      "vpunpckhqdq"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0x6d
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpunpckhqdq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      1
      0x6d
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpxor"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0xef
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vpxord"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      0
      0xef
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vpxorq"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      1
      0xef
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vshufps"
      "imxx imyy ixxx iyyy"
      (Vex)
      1
      0
      0
      0xc6
      (Fields 3 1 2 0 -1 1 0))
    (VectorForm
      "vshufps"
      "imxx imyy imzz ixxx iyyy izzz"
      (Evex)
      1
      0
      0
      0xc6
      (Fields 3 1 2 0 -1 -1 2))
    (VectorForm
      "vsubpd"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0x5c
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vsubpd"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      1
      0x5c
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vsubps"
      "mxx myy xxx yyy"
      (Vex)
      1
      0
      0
      0x5c
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vsubps"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      0
      0
      0x5c
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm
      "vunpckhpd"
      "mxx myy xxx yyy"
      (Vex)
      1
      1
      0
      0x15
      (Fields 2 0 1 -1 -1 1 0))
    (VectorForm
      "vunpckhpd"
      "mxx myy mzz xxx yyy zzz"
      (Evex)
      1
      1
      1
      0x15
      (Fields 2 0 1 -1 -1 -1 2))
    (VectorForm "xorpd" "mx xx" (Legacy) 1 1 0 0x57 (Fields 1 0 -1 -1 0 1 0))
    (VectorForm "xorps" "mx xx" (Legacy) 1 0 0 0x57 (Fields 1 0 -1 -1 0 1 0))))