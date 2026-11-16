# Security

## Report a problem

Please do not open a public issue for a security problem. Use GitHub's private report form:
**Security > Report a vulnerability** on the [repository page](https://github.com/esoteric-frog/nasty3ds/security/advisories/new).

You get an answer within 7 days. Only the newest version on `main` gets fixes.

## What the app opens on your network

- **Phone screen** (only while you use it): two TLS ports on your Mac. A pairing secret in the QR code is needed to get the page or to send touch. The certificate authority is made on your Mac, is limited to your Mac's `.local` name, and its key never leaves the Mac.
- **Local play room** (only after you select Host a Room): one UDP port, no password. Each device on the local network can connect while the room is open. The engine's room and local wireless code got input checks (see `patches/`), and `scripts/check-room.sh` sends hostile packets to a real room. Some checks in the wireless frame code have no automated test yet.

Nothing listens when no game runs, and the app makes no connection to the internet.
