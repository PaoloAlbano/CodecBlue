# Third-party notices

| Component | License | How it is used | Shipped |
|---|---|---|---|
| [AOSP libldac](https://android.googlesource.com/platform/external/libldac/) @ `eeee1a3f` | Apache-2.0 | LDAC encoder, compiled into the app from the unmodified git submodule (`third_party/libldac`) | yes (LICENSE + NOTICE included) |
| [Blue Bloom](https://github.com/jonathanlu98/bluebloom) | MIT | Reference for bluetoothd's classic XPC protocol, the headphone takeover sequence and timing constants. Files derived from Blue Bloom code carry its copyright notice in their header. | where noted |
| AOSP SBC encoder (planned) | Apache-2.0 | SBC / SBC XQ encoder | planned |
| libfreeaptx (planned) | LGPL-2.1+ | aptX / aptX HD encoder, as an **optional, dynamically loaded** component | optional |
| libldacdec (planned) | MIT | LDAC decoder, used **only in tests** | no |

Blue Bloom is distributed under the following license:

```
MIT License

Copyright (c) 2026 Blue Bloom contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

LDAC is a trademark of Sony Corporation. aptX is a trademark of Qualcomm Technologies, Inc.
Bluetooth is a registered trademark of Bluetooth SIG, Inc. This project is not affiliated
with or endorsed by them; the names are used only to describe codec compatibility.
