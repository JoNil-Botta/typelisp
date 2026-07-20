# Freestanding math notices

Parts of `stdlib/math.tl` are derived from musl libc revision
`b306b16af15c89a04d8e0c55cac2dadbeb39c083`, including the operation order of
`src/math/scalbn.c` and `src/math/scalbnf.c`.

The `f64-exp` and `f32-exp` implementations, coefficient bit patterns, and
table data derive from musl's `exp.c`, `expf.c`, `exp_data.c`, and
`exp2f_data.c` at that revision:

> Copyright (c) 2017-2018, Arm Limited.
>
> SPDX-License-Identifier: MIT

The `f64-sin`/`f64-cos`/`f64-tan` and binary32 counterparts also derive from
musl's `sin.c`, `cos.c`, `tan.c`, float variants, `__sin.c`, `__cos.c`,
`__tan.c`, float kernels, `__rem_pio2.c`, `__rem_pio2f.c`, and
`__rem_pio2_large.c` at that revision. Those files originate in the
FreeBSD/Sun fdlibm family. Their required notices are preserved below.

> Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
>
> Developed at SunPro and SunSoft, Sun Microsystems, Inc. businesses.
> Permission to use, copy, modify, and distribute this software is freely
> granted, provided that this notice is preserved.

The tangent kernels carry the corresponding 2004 notice:

> Copyright 2004 Sun Microsystems, Inc. All Rights Reserved.
>
> Permission to use, copy, modify, and distribute this software is freely
> granted, provided that this notice is preserved.

The binary32 conversions are credited in the upstream files to Ian Lance
Taylor (Cygnus Support) and were optimized/debugged by Bruce D. Evans.

musl as a whole is licensed under the following standard MIT license:

> Copyright © 2005-2020 Rich Felker, et al.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.
