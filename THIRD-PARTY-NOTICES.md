# Third-party notices

Pluto includes code from other projects. That code keeps its own license,
not the AGPL. The source files carry no Pluto license notice.

| Code                                                                                                 | Where                                                                                     | License                                 | License text                                                                  |
| ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | --------------------------------------- | ----------------------------------------------------------------------------- |
| CodeMirror 5.65.16                                                                                   | `pluto-console/main/default/staticresources/plutoJsonEditor/` (`addon/`, `lib/`, `mode/`) | MIT                                     | [LICENSE](pluto-console/main/default/staticresources/plutoJsonEditor/LICENSE) |
| micromark 3.2.0 and micromark-extension-gfm 3.0.0                                                    | `pluto-console/main/default/staticresources/micromark/js/`                                | MIT                                     | [LICENSE](pluto-console/main/default/staticresources/micromark/LICENSE)       |
| Toast UI Editor 3.2.2, with ProseMirror, orderedmap, rope-sequence, w3c-keyname, and DOMPurify 2.3.3 | `pluto-console/main/default/staticresources/toastUiEditor/`                               | MIT; DOMPurify is Apache 2.0 or MPL 2.0 | [LICENSE](pluto-console/main/default/staticresources/toastUiEditor/LICENSE)   |
| Salesforce Lightning test mocks                                                                      | `test/jest-mocks/lightning/modal.js`, `test/jest-mocks/lightning/uiRecordApi.js`          | MIT                                     | Below                                                                         |

The license text sits next to the code in each static resource, so it ships
inside the Pluto Console package.

## Salesforce Lightning test mocks

The two mock files say to see "the LICENSE file in the repo root". That
refers to the Salesforce repository they came from. This is that license.

```
Copyright (c) 2018, 2021, salesforce.com, inc.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
