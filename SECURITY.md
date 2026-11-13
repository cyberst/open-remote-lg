# Security policy

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them privately through
GitHub instead:

1. Open this repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Describe the problem, how to reproduce it, and its impact. Include the app version, iOS
   version, and your TV model and webOS version if they're relevant.

Only the maintainers can see the report. We'll discuss it with you there, agree on a fix, and
credit you in the published advisory unless you'd rather stay anonymous.

This is a volunteer project, so we can't promise fixed response times. We aim to acknowledge
reports within a week.

## Supported versions

We fix security issues in the latest App Store release and on the `main` branch.

## Scope

In scope: anything in this repository, for example:

- pairing with the TV and how the TV's client key is stored in the Keychain
- the WebSocket (SSAP) and pointer-input connections to the TV
- TV discovery (SSDP and Bonjour), including handling of malicious responses on the local network
- the local media server that streams chosen photos and videos to the TV
- anything that sends data off the local network, which the app promises not to do except
  for Apple's speech service

Out of scope: vulnerabilities in LG's TV firmware or webOS itself (please report those to
LG Electronics), and issues in iOS or other Apple software (report those to Apple).
