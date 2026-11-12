# m5-omarchy-install

One script that moves a 14-inch M5 Max MacBook Pro, already booting Linux from m1n1, onto the Omarchy edge channel. It follows what the official Mac image does, over Ethernet, and it never lets a package touch the boot chain.

```
./m5-omarchy-install.sh check      # read-only survey, no root, changes nothing
./m5-omarchy-install.sh install    # full install, re-runs itself through sudo -n
```

## What it does

1. Writes `pacman.conf` and the mirrorlist from the runtime's own channel templates (`omarchy-apply-pacman edge`).
2. Installs the edge runtime: `omarchy-dev`, `omarchy-settings-dev` and `omarchy-mac`. The two edge packages replace the stable pair.
3. Installs the Apple Silicon package lists the runtime ships (`omarchy-base`, `omarchy-aarch64`, `omarchy-aarch64-apple`), skipping any name the edge repository does not carry and any package you already have.
4. Runs the runtime's own system and user provisioning phases, and sets the first-login provisioning to run.
5. Checks at the end that no kernel or boot-chain package is installed, that the channel reads `edge`, that sshd and networkd are enabled, and that the Ethernet port still has its address.

Every phase is marked, so a second run resumes. A snapshot of `/etc/pacman*`, the network config, `fstab` and the package list goes to `/var/lib/omarchy/backups/`.

## Key pins

The script checks two public signing keys against fixed fingerprints before it trusts them:

| Key | Fingerprint |
|---|---|
| Omarchy packages | `40DFB630FF42BCFFB047046CF0134EE680CAC571` |
| Apple Silicon ARM keyring (`asahi-alarm`) | `12CE6799A94A3F1B5DDFFE88F576553597FB8FEB` |

Put `omarchy-pkgs.gpg` and `asahi-alarm.gpg` in a `keys/` directory next to the script, or point `M5_KEYS_DIR` at one. They are not in this repo. A key whose fingerprint differs stops the run. The script then adds both keys to `pacman-key` and signs them locally.

## Edge channel

The edge repository serves from `pkgs.omarchy.org`. The script reads its definition from the installed runtime (`/usr/bin/omarchy-apply-pacman`) and does not write its own mirror list. It also checks that the user pacman downloads as can resolve that host, because a failure there looks like a signature error.

## Packages kept off pacman

pacman is told to ignore these, and the final check fails if any is installed:

```
linux-aurora*  linux-asahi*  m1n1*  grub  limine*  uboot-asahi  omarchy-mac-boot
```

The deny list in the final check also covers `dracut` and `systemd-boot*`. The Mac boots m1n1 into a kernel under `/boot/m1n1`, so no package may own the kernel, m1n1, the bootloader or the ESP. Two services that would break that boot are masked: `first-boot.service` (it would randomise the root UUID) and `linux-modules-cleanup.service` (it would delete kernel modules that no package owns).

## Needs

An aarch64 Mac with an Apple device tree, booted into the K114c kernel from `/boot/m1n1` (it refuses any other kernel, a mounted ESP at `/boot/efi`, under 25 GiB free on `/`, or swap on a disk). It also needs an Omarchy runtime already installed, working Ethernet, and `bsdtar gpg curl vercmp sha256sum pacman pacman-key sudo`. It is written for one machine. Read it before you run it on yours.

## Not included

No keys, no Apple firmware or image files, no credentials. Set `M5_USER` to choose the account that becomes the Omarchy owner. The default is the user who ran `sudo`.

Run it as a user with passwordless `sudo` (it needs `sudo -n`). When the account has that, the script installs a `wheel` passwordless-sudo drop-in in `/etc/sudoers.d/` and validates it with `visudo`, so the Omarchy account keeps it.
