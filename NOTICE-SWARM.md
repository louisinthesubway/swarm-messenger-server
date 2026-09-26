# NOTICE

SWARM Messenger server is based on Signal-Server by Signal Messenger, LLC, AGPL-3.0.

Upstream: https://github.com/signalapp/Signal-Server
Fork point: commit `bdf3e1aea` on `main`, 2026-09-25, preserved in this repository as the
branch `upstream-main` and the tag `upstream-bdf3e1a`.

## Licence

Copyright 2013 Signal Messenger, LLC
Copyright 2026 BRS Holding (SWARM), for the modifications listed in `docs/SWARM-CHANGES.md`

Licensed under the GNU Affero General Public License version 3. The full text is in
[`LICENSE`](LICENSE), unchanged from upstream. Every copyright header in the upstream source
files is preserved.

Because this is AGPL-3.0 software offered over a network, anyone interacting with a SWARM
Messenger server over a network is entitled to the corresponding source of the running
version, including the SWARM modifications. `docs/SWARM-CHANGES.md` lists every change from
upstream with file paths and reasons.

## Trademarks

"Signal" is a trademark of Signal Messenger, LLC. SWARM Messenger is not affiliated with,
endorsed by, or connected to Signal Messenger, LLC. The name "Signal" and the Signal logo and
other Signal brand assets are not used in SWARM Messenger's product name, icons, user
interface or marketing. They appear in this repository only where the licence requires
attribution and in unmodified upstream source files, copyright headers and documentation.

SWARM Messenger servers never contact Signal's production or staging infrastructure, and
SWARM Messenger clients never connect to it.

## Cryptography

The cryptographic protocol and its implementation are upstream's, unmodified. SWARM Messenger
uses `libsignal` as published by Signal Messenger, LLC, including PQXDH (X3DH combined with
ML-KEM) and the sparse post-quantum ratchet. No SWARM change touches a cryptographic
primitive, the protocol, or key handling. See `docs/SWARM-CHANGES.md`.

This distribution includes cryptographic software; see the Cryptography Notice in
[`README.md`](README.md) for the export-control statement, which is unchanged from upstream.
