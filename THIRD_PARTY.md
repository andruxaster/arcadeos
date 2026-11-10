# Third-party components

## Linux Loader (linuxloader)

- **Authors:** Linux Loader Development Team
- **Source:** https://github.com/lindbergh-loader/linuxloader
- **In this repository:** git submodule `vendor/linuxloader`, pinned to a release tag.
  Not modified. Built from source by `build/05-linuxloader.sh`.
- **License:** [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
  (CC BY-NC-SA 4.0)](https://creativecommons.org/licenses/by-nc-sa/4.0/)

Upstream notice:

> Our project is open source, and our primary goal is to preserve and maintain arcade
> machines, ensuring they continue to operate in arcades. We encourage individuals to use
> the information provided for their own open source projects and contribute to the
> development of the loader to improve it for the benefit of the community. However, we do
> not permit the use of any of our code in pay-to-play/subscription/commercial ventures
> without prior consent from the Linux Loader Development Team.

What this means for ArcadeOS images (ISO/installed systems), which contain a build of
linuxloader:

- **Non-commercial only.** Do not sell ArcadeOS builds, do not use them in pay-to-play
  machines, subscriptions or other commercial ventures without the team's consent.
- **Attribution** is kept: `/usr/share/doc/linuxloader/` in the installed system contains
  this file and `LICENSE-NOTICE` with the exact upstream revision.
- **ShareAlike:** if you modify linuxloader's code, publish those changes under
  CC BY-NC-SA 4.0. Contribute fixes upstream where possible.

`ll-deps/` additionally contains libraries shipped by upstream's build (Cg, OpenAL,
OpenSSL 0.9.7, libstdc++5, ncurses5, zlib, pcsclite) and SDL3 / SDL3_ttf / SDL3_image
built from source (zlib license). Each remains under its own license.

## Other components

- **Debian** packages (incl. non-free NVIDIA driver and firmware): their own licenses.
- **shim** (https://github.com/rhboot/shim): BSD-2-Clause, built from source.
- **Games** are not part of this project. Use only dumps you have the rights to.
