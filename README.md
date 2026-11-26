# Exherbo Forge

A guided, `archinstall`-style installer for [Exherbo Linux](https://www.exherbo.org), run from any Linux live USB (Arch ISO works). It is a fork of [oddlama/gentoo-install](https://github.com/oddlama/gentoo-install) with a new TUI and an Exherbo-specific install back end (Paludis/`cave`, systemd).

> **Status: untested on real hardware.** The install flow follows the official [Exherbo install guide](https://www.exherbo.org/docs/install-guide.html) and was dry-run against stubbed tools (including the failure paths), but it has not been run on a real Exherbo install. Package names were checked against the [Exherbo package browser](https://summer.exherbo.org/packages/) (they exist there), but that does not prove the options and service names below work. Try it in a VM first, and expect to fix things; issues and PRs welcome.

## What it does

1. Partitions the disk (auto layout or your own), formats and mounts it.
2. Downloads the current Exherbo stage and checks its sha256.
3. Configures Paludis (repositories, `*/* systemd`, MAKEOPTS), syncs, rebuilds the stage with the chosen options and installs systemd.
4. Builds the latest stable Linux kernel (Exherbo has no distribution kernel), generates an initramfs with dracut and installs systemd-boot or GRUB on the EFI partition.
5. Sets up the network (wired / iwd / NetworkManager), a user with sudo and the root account.
6. Optionally installs KDE Plasma and its Plasma Login Manager, plus any extra packages you list.

## Usage

```
git clone https://github.com/netsukukuku/exherbo-forge
cd exherbo-forge
./configure      # TUI, writes exherbo.conf
./install        # or "Review and install" in the TUI
```

You can also copy `exherbo.conf.example` to `exherbo.conf`, edit it and run `./install`.

## Scope and limits

- **EFI only**, one disk, ext4 or btrfs (btrfs gets `home`, `snapshots`, `log`, `cache` subvolumes). No encryption, RAID or ZFS yet.
- **Everything compiles from source.** There are no binary packages. The world rebuild and the kernel take a long time; Plasma takes hours.
- **Kernel:** the live system's config is used as the base. `live` trims it to the modules loaded right now (fast; hardware not active in the live system may be missing), `full` keeps all of them (slow). It is built by hand, so `cave` never updates it; see below.
- **Packages** (all looked up in the Exherbo package browser): `firmware/linux-firmware`, `sys-kernel/linux-headers`, `sys-boot/dracut`, `sys-boot/grub` (with its `efi` option), `app-admin/sudo`, `net-wireless/iwd`, `net-apps/NetworkManager` (with its `wifi` option), `kde/plasma-login-manager`, plus `sys-apps/bc`, `sys-devel/flex`, `sys-devel/bison` and `dev-util/elfutils` for the kernel build. systemd-boot needs no package: `bootctl` comes with `sys-apps/systemd` and its `efi` option.
- **Still unverified:** that the Plasma Login Manager unit is called `plasmalogin.service` on Exherbo (that is the upstream name), and that the default Wi-Fi provider of NetworkManager resolves without an extra choice. I found no `sddm` package, so it is only a fallback. Optional packages are installed best-effort: a failure prints a warning and the install continues. Wi-Fi/NetworkManager failure falls back to wired DHCP; failed dracut falls back to booting without an initramfs (root by PARTUUID); failed sudo keeps root unlocked so you are never locked out.
- No SSH server is installed.

## Updating the kernel

```
cd /usr/src && sudo tar xf linux-X.Y.Z.tar.xz && cd linux-X.Y.Z
sudo cp ../linux/.config . && sudo make olddefconfig
sudo make -j"$(nproc)" && sudo make modules_install
sudo cp arch/x86/boot/bzImage /boot/vmlinuz-X.Y.Z
sudo dracut --force --kver X.Y.Z /boot/initramfs-X.Y.Z.img
```
Then add an entry (systemd-boot: `/boot/loader/entries/`, GRUB: `/boot/grub/grub.cfg`) and keep the old one until the new kernel boots.

## Extras

`contrib/quickshell/shell.qml` is a lavender/black Quickshell bar for niri. It is not installed by the installer, and Quickshell/niri availability on Exherbo is unverified.

## License

MIT, like the upstream project (see LICENSE).
