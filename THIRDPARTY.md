# Third-party notices

godot-cli is released under the MIT License (see [LICENSE](LICENSE)). Parts of it
are derived from third-party sources that carry their own terms. Those terms are
reproduced here, and the notices below travel with any copy of this software.

Nothing in this file is legal advice; it records what the code is derived from so
that redistributors can comply.

---

## Godot Engine — MIT (Expat)

Several modules reimplement algorithms from the Godot Engine source so that files
written by this tool match what Godot itself would write. The Zig code is an
independent implementation, but it is a direct port of Godot's logic and constants
and is treated as a derivative work.

Derived files:

| File | Ported from |
|------|-------------|
| `src/godot/hash.zig` | `core/templates/hashfuncs.h`, `core/string/ustring.cpp` |
| `src/godot/resource_uid.zig` | `core/io/resource_uid.cpp` |
| `src/godot/scene_id.zig`, `src/godot/node_id.zig` | Godot scene/resource ID seeding behaviour |

Upstream: <https://github.com/godotengine/godot>

```
Copyright (c) 2014-present Godot Engine contributors.
Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.

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

---

## PCG Random Number Generation — Apache License 2.0

`src/godot/pcg.zig` is a port of the minimal PCG32 implementation that Godot
vendors as `thirdparty/misc/pcg.cpp`. Godot's `COPYRIGHT.txt` records that file as
**Apache-2.0**, not Expat, so this portion carries Apache-2.0 obligations even
though the project as a whole is MIT.

Upstream: <https://www.pcg-random.org/>

```
Copyright 2014 M.E. O'Neill

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

The full license text is included at
[`third_party/licenses/Apache-2.0.txt`](third_party/licenses/Apache-2.0.txt), as
Apache-2.0 section 4(a) requires.

**Changes made** (Apache-2.0 section 4(b)): the C implementation was translated to
Zig as `Pcg32`, using Zig's wrapping arithmetic operators and explicit integer
types. The algorithm, constants, and output sequence are unchanged.

---

## Godot trademark

"Godot" and the Godot Engine logo are trademarks of the Godot Foundation. This
project is not affiliated with, endorsed by, or sponsored by the Godot Foundation
or the Godot Engine project. The name is used only to describe what the tool is
compatible with.
