# Third-party notices — LGKit

LGKit has no third-party code dependencies. It does, however, rely on interoperability data and protocol
knowledge published by the following open-source projects.

## webOS SSAP registration manifest (permission list)

`Sources/LGKit/WebOS/RegistrationManifest.swift` embeds the SSAP registration manifest (`manifestVersion` 1,
`appVersion` "1.1" and its permission list) in the open, unsigned format used by LG's own
**LG Connect SDK** (`WebOSTVService`, © LG Electronics, Apache License 2.0) and by community webOS client
libraries derived from it, such as **aiowebostv** (© Home Assistant contributors, Apache License 2.0) and
**LGWebOSRemote** (MIT). The manifest is a list of capability names that the TV checks against; it is
reproduced unchanged so that client keys issued for it stay valid.

Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0

## Protocol knowledge

SSAP URIs, payload shapes and the pointer-input socket frame format were cross-checked against the public
source of the projects above and verified on a real LG TV (webOS 4.5). No code from these projects is included.

"LG", "webOS" and related marks are trademarks of LG Electronics. Open Remote for LG TV is not affiliated with or
endorsed by LG Electronics.
