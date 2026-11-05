# Third-party notices

EveryAI includes code and files from the projects below. Each entry says what
was taken, where it lives in this repository, and the license it is under.

## Mermaid 11.17.2

- **What:** `mermaid.min.js`, unmodified, from jsDelivr (`https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js`).
- **Where:** `frontend/assets/web/mermaid.min.js`
- **License:** MIT

```
The MIT License (MIT)

Copyright (c) 2014 - 2022 Knut Sveidqvist

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

### Libraries bundled inside `mermaid.min.js`

The Mermaid build bundles its dependencies into the same file, so the app
ships them too. The first three carry their notices inside the bundle (kept
there, unmodified); the rest are Mermaid 11.17.2's runtime dependencies.
Where a license below says "MIT", its text is the MIT license above with the
copyright line given here.

- **DOMPurify 3.4.12** — (c) Cure53 and other contributors. Dual-licensed
  under the Apache License 2.0 or the Mozilla Public License 2.0; EveryAI
  uses it under the Apache License 2.0
  (https://www.apache.org/licenses/LICENSE-2.0). Source:
  https://github.com/cure53/DOMPurify/tree/3.4.12
- **lodash-es 4.18** — Copyright OpenJS Foundation and other contributors
  <https://openjsf.org/>. Based on Underscore.js 1.8.3, Copyright Jeremy
  Ashkenas, DocumentCloud and Investigative Reporters & Editors. MIT.
- **Cytoscape.js** — Copyright (c) 2016-2024, The Cytoscape Consortium. MIT.
  It includes: Embeddable Minimum Strictly-Compliant Promises/A+ 1.1.1
  Thenable, Copyright (c) 2013-2014 Ralf S. Engelschall (MIT); an event object
  based on jQuery events (MIT, https://jquery.org/license/); a Bezier curve
  function generator, Copyright Gaetan Renaudeau (MIT); a Runge-Kutta spring
  physics function generator adapted from Framer.js, copyright Koen Bok (MIT).
- **cytoscape-cose-bilkent** and **cytoscape-fcose** — Copyright (c) 2016-present,
  iVis@Bilkent. MIT.
- **D3** (d3 and its modules) — Copyright 2010-2023 Mike Bostock. ISC:

  ```
  Permission to use, copy, modify, and/or distribute this software for any
  purpose with or without fee is hereby granted, provided that the above
  copyright notice and this permission notice appear in all copies.

  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ```
- **d3-sankey** — Copyright 2015, Mike Bostock. BSD-3-Clause:

  ```
  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.
  * Neither the name of the author nor the names of contributors may be used
    to endorse or promote products derived from this software without
    specific prior written permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
  POSSIBILITY OF SUCH DAMAGE.
  ```
- **dagre-d3-es** — Copyright (c) 2013 Chris Pettitt. MIT.
- **khroma** — Copyright (c) 2019-present Fabio Spampinato, Andrew Maney. MIT.
- **roughjs** — Copyright (c) 2019 Preet Shihn. MIT.
- **KaTeX** — Copyright (c) 2013-2020 Khan Academy and other contributors. MIT.
- **marked** — Copyright (c) 2018+, MarkedJS; Copyright (c) 2011-2018,
  Christopher Jeffrey. MIT.
- **Day.js** — Copyright (c) 2018-present, iamkun. MIT.
- **stylis** — Copyright (c) 2016-present Sultan Tarimo. MIT.
- **@braintree/sanitize-url** — Copyright (c) 2017 Braintree. MIT.
- **@iconify/utils** — Copyright (c) 2021-PRESENT Vjacheslav Trushkin. MIT.
- **@mermaid-js/parser** (Mermaid, MIT, as above), built on **Langium**
  (Copyright 2021 TypeFox GmbH, MIT) and **Chevrotain** (Copyright (c) 2021
  the Chevrotain authors, Apache License 2.0,
  https://www.apache.org/licenses/LICENSE-2.0).
- **uuid** — Copyright (c) 2010-2020 Robert Kieffer and other contributors. MIT.
- **ts-dedent** — Copyright (c) 2018 Tamino Martinius. MIT.

## LibreChat v0.8.8

- **What:** the Mermaid SVG fix-up (`processMermaidSvg`, `applyMermaidBackground`,
  `fixSubgraphTitleContrast`) and the 2x canvas PNG export, ported from
  `client/src/utils/diagram/export.ts` and `client/src/utils/mermaid.ts`.
- **Where:** `frontend/assets/web/mermaid_export.js`
- **License:** MIT

```
MIT License

Copyright (c) 2026 LibreChat

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

## Excalidraw 0.18.1 and mermaid-to-excalidraw 3.1.0

- **What:** the Excalidraw editor (`@excalidraw/excalidraw@0.18.1`) and the
  Mermaid converter (`@excalidraw/mermaid-to-excalidraw@3.1.0`, which uses
  `pele@1.8.0`), with React 19.2.5 (`react`, `react-dom`). They are not copied
  into the repository: the drawing page loads these pinned versions from
  jsDelivr (`https://cdn.jsdelivr.net/npm/…/+esm`) inside the web sandbox, and
  Excalidraw's fonts come from the same package. Their own dependencies (also
  from jsDelivr) carry their own licenses.
- **Where:** `frontend/lib/features/artifacts/ui/renderers/drawing_page.dart`
- **License:** MIT, for each package, with these copyright lines:
  - Excalidraw: Copyright (c) 2020 Excalidraw
  - mermaid-to-excalidraw: Copyright (c) 2023 Excalidraw
  - pele: Copyright (c) 2026 kepano
  - React: Copyright (c) Meta Platforms, Inc. and affiliates.

```
MIT License

Copyright (c) <year> <copyright holders>

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

## Agent Skills `skills-ref` (agentskills/agentskills @ 69ef37e)

- **What:** the validation rules of the reference validator
  (`skills-ref/src/skills_ref/validator.py`, `parser.py`): the allowed front
  matter fields, the name rules (lowercase letters, digits and single hyphens,
  at most 64 characters, matching the folder), and the description (1024) and
  compatibility (500) limits. Re-implemented in Dart; no code was copied.
- **Where:** `frontend/lib/features/skills/domain/skill_format.dart`
- **License:** Apache License 2.0 (https://www.apache.org/licenses/LICENSE-2.0),
  from https://github.com/agentskills/agentskills.

## Deno 2.9.8 (denoland/deno @ v2.9.8)

- **What:** the `deno` release binary, unmodified, from
  https://github.com/denoland/deno/releases/tag/v2.9.8 (checked against the
  release's `.sha256sum`). The Code harness runs `run_script` programs in it
  with no permissions. The binary carries V8 and other components under their
  own licenses.
- **Where:** downloaded by `frontend/tool/fetch_deno.sh` into `frontend/.deno/`
  (`scripts/dev.sh` and `scripts/launch.sh` pass it as `DENO_BIN`); the macOS build copies it into
  `EveryAI.app/Contents/Resources/deno` (`frontend/macos/scripts/bundle_deno.sh`).
- **License:** MIT

```
MIT License

Copyright 2018-2026 the Deno authors

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## opencode v2.2 (anomalyco/opencode)

- **What:** the design of the EveryAI harness's tool set (read/write/edit with a
  read-before-edit check and a line-trimmed fallback match, grep/glob over
  ripgrep, background shells, the todo list), ported in Dart; no prompt text
  was copied.
- **Where:** `frontend/lib/features/code/harness/everyai/`
- **License:** MIT

```
MIT License

Copyright (c) 2025 opencode

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

## T3 Code (pingdotgg/t3code @ 8b44f42b)

- **What:** logic and protocol knowledge from T3 Code's provider adapters,
  rewritten in Dart (no files copied verbatim; no prompt text was taken). So
  far: Kiro CLI's ACP launch arguments (`--agent-engine=v3`,
  `--auth-method=cli`) and the reading of `kiro-cli whoami --format json`
  (`packages/provider-kiro/src/server/acpSupport.ts`, `status.ts`); Grok
  Build's ACP launch flags, `initialize`/`session/cancel` `_meta`, sign-in
  method pick and `grok models` sign-in reading
  (`packages/provider-grok/src/server/acpSupport.ts`, `status.ts`), and its
  `x.ai/*` extension mapping: prompt completion, background tasks,
  subagents, the usage-limit code (`xaiAcpExtension.ts`; test payloads
  adapted from `xaiAcpExtension.test.ts` in
  `frontend/test/fixtures/drivers/grok/`). The replies Grok reads are our
  own words. The ACP registry install rules: the index checks (https only,
  pinned npx/uvx packages, bounded fields, the 1 MiB cap), the command path
  check, the platform pick with its windows-aarch64 fallback, the archive
  kind by URL suffix, and the checksum and stays-inside checks of a
  download (`packages/provider-acp-registry/src/server/AcpRegistrySupport.ts`).
  Source:
  https://github.com/pingdotgg/t3code at commit
  8b44f42b14c8e273156474a924ccf29680dd7857.
- **Where:** `frontend/lib/features/code/drivers/` (the parts marked "Ported
  from T3 Code", and `drivers/registry_install/`)
- **License:** MIT

```
MIT License

Copyright (c) 2026 T3 Tools Inc.

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

## Sparkle 2.9.6 (sparkle-project/Sparkle)

- **What:** the Sparkle update framework, unmodified, from CocoaPods (`pod 'Sparkle', '~> 2.6'`). The signed macOS
  release uses it to download, verify (EdDSA and code signature) and install its own updates.
- **Where:** `frontend/macos/Podfile`; embedded as `EveryAI.app/Contents/Frameworks/Sparkle.framework`; driven by
  `UpdaterBridge` in `frontend/macos/Runner/MainFlutterWindow.swift`.
- **License:** MIT, with the external licenses listed in Sparkle's own LICENSE (below, in full).

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions 
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```
