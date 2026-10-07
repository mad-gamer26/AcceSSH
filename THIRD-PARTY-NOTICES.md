# Third-Party Notices

AcceSSH itself is MIT-licensed (see `LICENSE`). Builds of the app also include the following
libraries, which `Scripts/build-libssh2.sh` downloads (verified by SHA-256) and compiles. Their
source code is not stored in this repository.

| Library | Version | License |
|---|---|---|
| [libssh2](https://libssh2.org) | main branch, commit `232c9516fff9758427eb79861b51a6e3fde56d6d` | BSD 3-Clause |
| [OpenSSL](https://openssl.org) | 3.5.9 | Apache License 2.0 |
| [zlib](https://zlib.net) | provided by the iOS SDK | zlib License |

Anyone distributing a build of AcceSSH must include these libraries' license texts, for
example on an About or Acknowledgements screen.
