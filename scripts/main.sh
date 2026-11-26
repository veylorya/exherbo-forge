# shellcheck source=./scripts/protection.sh
source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1


################################################
# Functions
#
# Exherbo notes: the package manager is Paludis (cave), everything is built from source, there is
# no binary package host and no distribution kernel. The steps follow the official Exherbo
# installation guide (https://www.exherbo.org/docs/install-guide.html). Optional packages whose
# exact names could not be verified are installed on a best-effort basis and never abort the install.

function install_stage3() {
	prepare_installation_environment
	apply_disk_configuration
	download_stage3
	extract_stage3
	mount_extra_mounts
	download_kernel_source
}

# The kernel source is downloaded from the live system (it has wget/python3) into the shared
# $TMP_DIR, which is also visible inside the chroot.
function download_kernel_source() {
	cd "$TMP_DIR" \
		|| die "Could not cd into '$TMP_DIR'"

	local version=""
	einfo "Looking up the latest stable Linux kernel"
	version="$(download_stdout "https://www.kernel.org/releases.json" 2>/dev/null \
		| python3 -c 'import json,sys; print(json.load(sys.stdin)["latest_stable"]["version"])' 2>/dev/null)" \
		|| version=""
	[[ $version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
		|| die "Could not determine the latest stable kernel version from kernel.org"

	local major="${version%%.*}"
	local base="https://cdn.kernel.org/pub/linux/kernel/v${major}.x"
	local tarball="linux-${version}.tar.xz"

	if [[ ! -e "$tarball.verified" ]]; then
		einfo "Downloading Linux $version"
		download "$base/$tarball" "$tarball" \
			|| die "Could not download '$base/$tarball'"
		download "$base/sha256sums.asc" "kernel-sha256sums.asc" \
			|| die "Could not download the kernel checksum list"
		local expected actual
		expected="$(awk -v f="$tarball" '$2 == f { print $1; exit }' "kernel-sha256sums.asc")"
		[[ $expected =~ ^[0-9a-f]{64}$ ]] \
			|| die "No sha256 checksum for '$tarball' in the kernel checksum list"
		actual="$(sha256sum "$tarball" | awk '{print $1}')"
		[[ $expected == "$actual" ]] \
			|| die "Checksum mismatch for '$tarball'!"
		touch_or_die 0644 "$tarball.verified"
	fi

	# Pass the live system's kernel configuration and loaded modules to the chroot.
	echo "$version" > "$TMP_DIR/kernel-version" \
		|| die "Could not write kernel-version"
	rm -f "$TMP_DIR/live-kernel-config" "$TMP_DIR/live-lsmod"
	if [[ -r /proc/config.gz ]]; then
		zcat /proc/config.gz > "$TMP_DIR/live-kernel-config" || rm -f "$TMP_DIR/live-kernel-config"
	elif modprobe configs &>/dev/null && [[ -r /proc/config.gz ]]; then
		zcat /proc/config.gz > "$TMP_DIR/live-kernel-config" || rm -f "$TMP_DIR/live-kernel-config"
	fi
	{ echo "Module Size Used by"; cat /proc/modules; } > "$TMP_DIR/live-lsmod" 2>/dev/null \
		|| rm -f "$TMP_DIR/live-lsmod"
}

# $1: "-j<jobs>"
function calculate_makeopts() {
	local cores mem_kb jobs
	cores="$(nproc)" || cores=1
	mem_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)" || mem_kb=0
	jobs=$((mem_kb / 1024 / 1024 / 2))
	[[ $jobs -gt $cores ]] && jobs=$cores
	[[ $jobs -lt 1 ]] && jobs=1
	echo "-j$jobs"
}

# ---- cave helpers -------------------------------------------------------

# Install packages with cave. A failure asks what to do (shell / retry / abort / continue).
# $@: package specs or sets
function cave_install() {
	try cave resolve --execute --skip-phase test --continue-on-failure if-satisfied "$@"
}

# Like cave_install, but never interrupts the install: returns 1 and prints a hint on failure.
# $@: package specs or sets
function cave_install_optional() {
	if ! cave resolve --execute --skip-phase test --continue-on-failure if-satisfied "$@"; then
		ewarn "Could not install: $*"
		ewarn "After the first boot you can try again with:  sudo cave resolve --execute $*"
		return 1
	fi
}

# Write the paludis configuration: extra repositories, options, build jobs.
function configure_paludis() {
	einfo "Configuring Paludis"
	mkdir_or_die 0755 /etc/paludis/repositories

	local repo
	for repo in $EXHERBO_REPOSITORIES; do
		[[ -e /etc/paludis/repositories/$repo.conf ]] && continue
		cat > "/etc/paludis/repositories/$repo.conf" <<EOF
format = e
location = \${root}/var/db/paludis/repositories/$repo
sync = git+https://gitlab.exherbo.org/exherbo/$repo.git
EOF
		chmod 644 "/etc/paludis/repositories/$repo.conf"
	done

	{
		echo ""
		echo "# Added by Exherbo Forge"
		echo "*/* systemd"
		# Plain "[[ ]] && echo" would make this group fail whenever the test is false.
		if [[ $IS_EFI == "true" ]]; then
			echo "sys-apps/systemd efi"
		fi
		# GRUB is only built for EFI systems with its efi option.
		if [[ $BOOTLOADER == "grub" ]]; then
			echo "sys-boot/grub efi"
		fi
		# Wi-Fi support in NetworkManager is an option (Wi-Fi daemon providers keep their defaults).
		if [[ $NETWORK_BACKEND == "networkmanager" ]]; then
			echo "net-apps/NetworkManager wifi"
		fi
	} >> /etc/paludis/options.conf \
		|| die "Could not write /etc/paludis/options.conf"

	# Later assignments win, so the jobs setting goes to the end of the paludis bashrc.
	{
		echo ""
		echo "# Added by Exherbo Forge"
		echo "MAKEOPTS=\"$(calculate_makeopts)\""
	} >> /etc/paludis/bashrc \
		|| die "Could not write /etc/paludis/bashrc"
}

# ---- base system --------------------------------------------------------

function configure_base_system() {
	einfo "Selecting hostname"
	echo "$HOSTNAME" > /etc/hostname \
		|| die "Could not write /etc/hostname"
	# The hosts file matters: some package test suites and builds fail under sandboxed networking without it.
	cat > /etc/hosts <<EOF
127.0.0.1    $HOSTNAME.localdomain    $HOSTNAME    localhost
::1          localhost
EOF

	einfo "Generating locales"
	local line locale charset name
	while IFS= read -r line; do
		[[ -z $line ]] && continue
		read -r name charset <<< "$line"
		# "xx_YY.UTF-8 UTF-8" -> input locale "xx_YY", charset "UTF-8"
		locale="${name%%.*}"
		[[ $locale == "C" ]] && continue
		try localedef -i "$locale" -f "${charset:-UTF-8}" "$name"
	done <<< "${LOCALES//;/$'\n'}"

	einfo "Selecting locale"
	mkdir_or_die 0755 /etc/env.d
	echo "LANG=\"$LOCALE\"" > /etc/env.d/99locale \
		|| die "Could not write /etc/env.d/99locale"
	echo "LANG=$LOCALE" > /etc/locale.conf \
		|| die "Could not write /etc/locale.conf"

	einfo "Selecting keymap"
	echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf \
		|| die "Could not write /etc/vconsole.conf"

	einfo "Selecting timezone"
	ln -sfn "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime \
		|| die "Could not change /etc/localtime link"
}

# systemd is the Exherbo default, but the stage has to be rebuilt with the systemd option first
# (see the install guide: "cave resolve world -c" followed by systemd).
function install_systemd() {
	einfo "Rebuilding the system with the chosen options (this takes a long time)"
	try cave resolve world --complete --execute --skip-phase test --continue-on-failure if-satisfied
	try cave resolve --execute --preserve-world --skip-phase test sys-apps/systemd
	try eclectic init set systemd

	einfo "Setting machine-id"
	systemd-machine-id-setup \
		|| die "Could not setup systemd machine id"
}

# ---- kernel -------------------------------------------------------------

function kernel_build_prerequisites() {
	# program -> package (names checked against https://summer.exherbo.org/packages/)
	local -A pkg_of=(
		[bc]="sys-apps/bc"
		[flex]="sys-devel/flex"
		[bison]="sys-devel/bison"
	)
	local tool
	for tool in bc flex bison; do
		command -v "$tool" &>/dev/null && continue
		einfo "Installing ${pkg_of[$tool]} (needed to build the kernel)"
		cave_install "${pkg_of[$tool]}"
	done
	if [[ -z $(find /usr -name libelf.h -print -quit 2>/dev/null) ]]; then
		einfo "Installing dev-util/elfutils (needed to build the kernel)"
		cave_install dev-util/elfutils
	fi
}

# Applies the options the installed system needs in every case: the filesystems and storage
# drivers are built in, so the system can mount its root even before the initramfs has loaded modules.
function kernel_force_options() {
	local cfg="./scripts/config" opt
	for opt in \
		EXT4_FS BTRFS_FS VFAT_FS FAT_FS MSDOS_FS NLS_CODEPAGE_437 NLS_ISO8859_1 NLS_UTF8 \
		DEVTMPFS DEVTMPFS_MOUNT TMPFS TMPFS_POSIX_ACL TMPFS_XATTR \
		BLK_DEV_NVME SCSI BLK_DEV_SD ATA SATA_AHCI VIRTIO_BLK VIRTIO_PCI \
		EFI EFI_STUB EFIVAR_FS \
		CGROUPS INOTIFY_USER SIGNALFD TIMERFD EPOLL FHANDLE UNIX NET AUTOFS_FS SECCOMP \
		BINFMT_ELF BINFMT_SCRIPT PROC_FS SYSFS; do
		"$cfg" --enable "$opt"
	done
	# Things that need extra host tools or break module loading without them.
	for opt in DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES MODULE_SIG MODULE_COMPRESS \
		SYSTEM_TRUSTED_KEYRING SYSTEM_REVOCATION_LIST; do
		"$cfg" --disable "$opt"
	done
	"$cfg" --set-str SYSTEM_TRUSTED_KEYS ""
	"$cfg" --set-str SYSTEM_REVOCATION_KEYS ""
}

# Sets KERNEL_RELEASE (e.g. 6.18.4) and builds + installs the kernel into /boot.
function install_kernel() {
	local version
	version="$(<"$TMP_DIR/kernel-version")" \
		|| die "Missing $TMP_DIR/kernel-version"

	kernel_build_prerequisites

	einfo "Unpacking Linux $version"
	mkdir_or_die 0755 /usr/src
	tar -xf "$TMP_DIR/linux-$version.tar.xz" -C /usr/src \
		|| die "Could not unpack the kernel source"
	ln -sfn "linux-$version" /usr/src/linux
	cd "/usr/src/linux-$version" \
		|| die "Could not enter the kernel source directory"

	einfo "Configuring the kernel"
	if [[ -s $TMP_DIR/live-kernel-config ]]; then
		cp "$TMP_DIR/live-kernel-config" .config \
			|| die "Could not copy the live kernel config"
		try make olddefconfig
		if [[ $KERNEL_CONFIG == "live" && -s $TMP_DIR/live-lsmod ]]; then
			# Keep only the modules the live system is using right now: a much faster build.
			einfo "Trimming the kernel config to the hardware of this machine (localmodconfig)"
			yes "" | make LSMOD="$TMP_DIR/live-lsmod" localmodconfig \
				|| ewarn "localmodconfig failed; keeping the full live configuration (slower build)."
		fi
	else
		ewarn "No kernel config available from the live system; using the generic x86_64 defconfig."
		try make defconfig
	fi
	kernel_force_options
	try make olddefconfig

	einfo "Building the kernel with ${NPROC:-2} jobs (this takes a while)"
	try make -j"${NPROC:-2}"
	try make modules_install

	KERNEL_RELEASE="$(make -s kernelrelease)" \
		|| die "Could not determine the kernel release"
	[[ -n $KERNEL_RELEASE ]] \
		|| die "Empty kernel release"

	einfo "Installing kernel $KERNEL_RELEASE into /boot"
	cp arch/x86/boot/bzImage "/boot/vmlinuz-$KERNEL_RELEASE" \
		|| die "Could not copy the kernel image to /boot"
	cp System.map "/boot/System.map-$KERNEL_RELEASE" \
		|| ewarn "Could not copy System.map"
	cp .config "/boot/config-$KERNEL_RELEASE" \
		|| ewarn "Could not copy the kernel config"
	cd / || die "Could not cd to /"
	export KERNEL_RELEASE
}

# Headers have to match the installed kernel. Best effort: only user space builds need them.
function install_kernel_headers() {
	einfo "Installing linux-headers"
	cave_install_optional sys-kernel/linux-headers
}

function install_firmware() {
	einfo "Installing linux-firmware"
	cave_install_optional firmware/linux-firmware
}

# Sets HAVE_INITRAMFS=true if /boot/initramfs-$KERNEL_RELEASE.img exists afterwards.
function install_initramfs() {
	HAVE_INITRAMFS=false
	einfo "Installing dracut and generating the initramfs"
	if ! cave_install_optional sys-boot/dracut; then
		return 0
	fi
	local args=(--force --kver "$KERNEL_RELEASE")
	if dracut "${args[@]}" "/boot/initramfs-$KERNEL_RELEASE.img"; then
		HAVE_INITRAMFS=true
	else
		ewarn "dracut failed; the system will boot without an initramfs (root is found by PARTUUID)."
	fi
	export HAVE_INITRAMFS
}

# ---- boot loader --------------------------------------------------------

# Kernel command line. Without an initramfs the kernel cannot resolve UUID=, so PARTUUID is used.
function get_cmdline() {
	local cmdline=("rw")
	local root_uuid
	root_uuid="$(get_blkid_uuid_for_id "$DISK_ID_ROOT")"
	if [[ ${HAVE_INITRAMFS:-false} == "true" ]]; then
		cmdline+=("root=UUID=$root_uuid" "rd.vconsole.keymap=$KEYMAP_INITRAMFS")
		cmdline+=("${DISK_DRACUT_CMDLINE[@]}")
	else
		local dev partuuid=""
		dev="$(blkid -U "$root_uuid" 2>/dev/null)" || dev=""
		[[ -n $dev ]] && partuuid="$(blkid -s PARTUUID -o value "$dev" 2>/dev/null)"
		[[ -n $partuuid ]] \
			|| die "No initramfs and no PARTUUID for the root partition: the system could not find its root filesystem."
		cmdline+=("root=PARTUUID=$partuuid")
	fi
	echo -n "${cmdline[*]}"
}

function install_bootloader_systemd_boot() {
	einfo "Installing systemd-boot"
	if ! command -v bootctl &>/dev/null; then
		ewarn "bootctl not found (systemd needs the 'efi' option); using GRUB instead."
		install_bootloader_grub
		return
	fi
	try bootctl install --esp-path=/boot
	cat > /boot/loader/loader.conf <<EOF
default exherbo.conf
timeout 5
console-mode max
editor no
EOF
	mkdir_or_die 0755 /boot/loader/entries
	{
		echo "title   Exherbo"
		echo "linux   /vmlinuz-$KERNEL_RELEASE"
		[[ ${HAVE_INITRAMFS:-false} == "true" ]] && echo "initrd  /initramfs-$KERNEL_RELEASE.img"
		echo "options $(get_cmdline)"
	} > /boot/loader/entries/exherbo.conf \
		|| die "Could not write the boot entry"
}

function install_bootloader_grub() {
	einfo "Installing GRUB"
	# The efi option for sys-boot/grub is set in /etc/paludis/options.conf by configure_paludis.
	cave_install sys-boot/grub
	# A hand written grub.cfg is deterministic and does not depend on grub-mkconfig finding the kernel.
	local esp_uuid
	esp_uuid="$(get_blkid_uuid_for_id "$DISK_ID_EFI")"

	try grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Exherbo
	# Some firmwares ignore the boot entry and only look at the removable-media path.
	try grub-install --target=x86_64-efi --efi-directory=/boot --removable

	mkdir_or_die 0755 /boot/grub
	{
		echo "set timeout=5"
		echo "set default=0"
		echo ""
		echo "insmod part_gpt"
		echo "insmod fat"
		echo "menuentry \"Exherbo\" {"
		echo "	search --no-floppy --fs-uuid --set=root $esp_uuid"
		echo "	linux /vmlinuz-$KERNEL_RELEASE $(get_cmdline)"
		[[ ${HAVE_INITRAMFS:-false} == "true" ]] && echo "	initrd /initramfs-$KERNEL_RELEASE.img"
		echo "}"
	} > /boot/grub/grub.cfg \
		|| die "Could not write /boot/grub/grub.cfg"
}

function install_bootloader() {
	case "$BOOTLOADER" in
		systemd-boot) install_bootloader_systemd_boot ;;
		grub)         install_bootloader_grub ;;
	esac
}

# ---- fstab, accounts ----------------------------------------------------

function add_fstab_entry() {
	printf '%-46s  %-24s  %-6s  %-96s %s\n' "$1" "$2" "$3" "$4" "$5" >> /etc/fstab \
		|| die "Could not append entry to fstab"
}

function generate_fstab() {
	einfo "Generating fstab"
	install -m0644 -o root -g root "$GENTOO_INSTALL_REPO_DIR/contrib/fstab" /etc/fstab \
		|| die "Could not overwrite /etc/fstab"
	if [[ -n $DISK_ID_ROOT_TYPE ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_ROOT")" "/" "$DISK_ID_ROOT_TYPE" "$DISK_ID_ROOT_MOUNT_OPTS" "0 1"
	fi
	# The ESP is mounted at /boot, so kernels live on it.
	add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_EFI")" "/boot" "vfat" "defaults,noatime,fmask=0077,dmask=0077,nodev,nosuid,discard" "0 2"
	if [[ -v "DISK_ID_SWAP" ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_SWAP")" "none" "swap" "defaults,discard" "0 0"
	fi
	local entry id mp fs opts
	for entry in "${DISK_EXTRA_MOUNTS[@]}"; do
		IFS='|' read -r id mp fs opts <<< "$entry"
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$id")" "$mp" "$fs" "$opts" "0 2"
	done
}

function set_account_password() {
	local account="$1" hash="$2"
	if [[ -n $hash ]]; then
		printf '%s:%s\n' "$account" "$hash" | chpasswd -e \
			|| die "Could not set password for '$account'"
	else
		einfo "Choose a password for '$account'"
		try passwd "$account"
	fi
}

# Root locking is deferred to finalize_root_account: it must only happen once sudo works.
function setup_accounts() {
	case "$ROOT_PASSWORD_MODE" in
		set)
			einfo "Setting the root password"
			set_account_password root "$ROOT_PASSWORD_HASH"
			;;
		ask)
			einfo "Choose a password for 'root'"
			try passwd root
			;;
	esac

	[[ -n $USER_NAME ]] || return 0

	einfo "Creating user '$USER_NAME'"
	local group groups=()
	# Same groups as the Exherbo install guide, plus input/render for graphical sessions.
	for group in adm disk wheel cdrom audio video usb users input render; do
		getent group "$group" &>/dev/null \
			&& groups+=("$group")
	done
	local group_list
	group_list="$(IFS=,; echo "${groups[*]}")"
	useradd --create-home --groups "$group_list" --shell /bin/bash "$USER_NAME" \
		|| die "Could not create user '$USER_NAME'"
	set_account_password "$USER_NAME" "$USER_PASSWORD_HASH"
}

SUDO_OK=false
function setup_sudo() {
	[[ -n $USER_NAME && $USER_SUDO == "true" ]] || return 0

	einfo "Installing sudo and allowing the wheel group"
	cave_install_optional app-admin/sudo || return 0
	command -v visudo &>/dev/null || { ewarn "sudo was installed but visudo is missing."; return 0; }
	mkdir_or_die 0750 /etc/sudoers.d
	echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel \
		|| die "Could not write /etc/sudoers.d/10-wheel"
	chmod 0440 /etc/sudoers.d/10-wheel
	visudo -cf /etc/sudoers.d/10-wheel \
		|| die "Generated sudoers file is invalid"
	SUDO_OK=true
}

function finalize_root_account() {
	[[ $ROOT_PASSWORD_MODE == "locked" ]] || return 0
	if [[ $SUDO_OK == "true" ]]; then
		einfo "Locking the root account (administration via sudo)"
		passwd -l root \
			|| die "Could not lock root account"
	else
		ewarn "sudo could not be set up, so the root account is NOT locked (you would have no way to administer the system)."
		einfo "Choose a password for 'root'"
		try passwd root
	fi
}

# ---- network ------------------------------------------------------------

function configure_wired_network() {
	local mode="${1:-configured}"
	enable_service systemd-networkd
	enable_service systemd-resolved
	if [[ $mode == "dhcp" || $SYSTEMD_NETWORKD_DHCP == "true" ]]; then
		printf '[Match]\nName=%s\n\n[Network]\nDHCP=yes\n' "${SYSTEMD_NETWORKD_INTERFACE_NAME}" > /etc/systemd/network/20-wired.network \
			|| die "Could not write dhcp network config to '/etc/systemd/network/20-wired.network'"
	else
		local addresses=""
		local addr
		for addr in "${SYSTEMD_NETWORKD_ADDRESSES[@]}"; do
			addresses="${addresses}Address=$addr"$'\n'
		done
		printf '[Match]\nName=%s\n\n[Network]\n%sGateway=%s\n' "${SYSTEMD_NETWORKD_INTERFACE_NAME}" "$addresses" "$SYSTEMD_NETWORKD_GATEWAY" > /etc/systemd/network/20-wired.network \
			|| die "Could not write static network config to '/etc/systemd/network/20-wired.network'"
	fi
	chown root:systemd-network /etc/systemd/network/20-wired.network 2>/dev/null \
		|| chown root:root /etc/systemd/network/20-wired.network
	chmod 644 /etc/systemd/network/20-wired.network \
		|| die "Could not change permissions of '/etc/systemd/network/20-wired.network'"
}

function configure_network() {
	case "$NETWORK_BACKEND" in
		iwd)
			einfo "Installing iwd (use 'iwctl' to manage wifi)"
			if cave_install_optional net-wireless/iwd; then
				mkdir_or_die 0755 /etc/iwd
				cat > /etc/iwd/main.conf <<EOF
[General]
EnableNetworkConfiguration=true

[Network]
NameResolvingService=systemd
EOF
				chmod 644 /etc/iwd/main.conf
				enable_service iwd
			else
				ewarn "Wi-Fi will not work until iwd is installed. Wired networking is set up."
			fi
			# iwd only manages wifi, ethernet is handled by systemd-networkd.
			configure_wired_network dhcp
			;;
		networkmanager)
			einfo "Installing NetworkManager"
			if cave_install_optional net-apps/NetworkManager; then
				enable_service NetworkManager
			else
				ewarn "NetworkManager could not be installed; falling back to wired DHCP via systemd-networkd."
				configure_wired_network dhcp
			fi
			;;
		wired)
			configure_wired_network configured
			;;
	esac
}

function copy_live_wifi_profiles() {
	[[ $NETWORK_BACKEND == "iwd" && $COPY_LIVE_WIFI == "true" ]] || return 0
	[[ -d /var/lib/iwd ]] || return 0

	local profiles=()
	local f
	for f in /var/lib/iwd/*.psk /var/lib/iwd/*.open /var/lib/iwd/*.8021x; do
		[[ -f $f ]] && profiles+=("$f")
	done
	[[ ${#profiles[@]} -gt 0 ]] || return 0

	einfo "Copying ${#profiles[@]} wifi profile(s) from the live environment"
	install -d -m0700 "$ROOT_MOUNTPOINT/var/lib/iwd" \
		|| die "Could not create $ROOT_MOUNTPOINT/var/lib/iwd"
	for f in "${profiles[@]}"; do
		install -m0600 "$f" "$ROOT_MOUNTPOINT/var/lib/iwd/" \
			|| die "Could not copy wifi profile '$f'"
	done
}

# ---- desktop ------------------------------------------------------------

# KDE Plasma via the documented "plasma" set (https://exherbo.org/docs/kde.html) and a login screen.
# The kde repository ships KDE's Plasma Login Manager (kde/plasma-login-manager, systemd unit
# plasmalogin.service). I could not find an sddm package in the Exherbo package browser, so sddm
# is only a fallback.
function install_desktop() {
	[[ $DESKTOP == "plasma" ]] || return 0

	einfo "Installing KDE Plasma (compiled from source: this takes many hours)"
	try cave resolve --execute --skip-phase test --continue-on-failure if-satisfied plasma

	local dm_service=""
	case "$DISPLAY_MANAGER" in
		auto|plasmalogin)
			if cave_install_optional kde/plasma-login-manager; then
				dm_service="plasmalogin"
			elif [[ $DISPLAY_MANAGER == "auto" ]] && cave_install_optional sddm; then
				dm_service="sddm"
			fi
			;;
		sddm)
			cave_install_optional sddm && dm_service="sddm"
			;;
	esac

	if [[ -n $dm_service ]]; then
		enable_service "$dm_service"
		try systemctl set-default graphical.target
	else
		ewarn "No login screen installed; the system will boot to a text console."
		ewarn "Log in there and start the desktop with 'startplasma-wayland'."
	fi
}

function install_additional_packages() {
	[[ ${#ADDITIONAL_PACKAGES[@]} -gt 0 ]] || return 0
	einfo "Installing additional packages"
	try cave resolve --execute --skip-phase test --continue-on-failure if-satisfied "${ADDITIONAL_PACKAGES[@]}"
}

################################################
# Entry points

function main_install_gentoo_in_chroot() {
	[[ $# == 0 ]] || die "Too many arguments"

	# Mount the efi partition. It is the /boot partition: kernel and initramfs live here.
	mount_efivars
	einfo "Mounting efi partition"
	mount_by_id "$DISK_ID_EFI" "/boot"

	# Ask for passwords first, so the rest can run unattended.
	setup_accounts

	# Paludis, repositories and a first sync
	configure_paludis
	configure_base_system
	einfo "Syncing the Exherbo repositories"
	try cave sync

	# Rebuild the stage with the chosen options and install systemd
	install_systemd

	# Everything needed to boot, in the order that leaves a bootable system as early as possible
	install_firmware
	install_kernel
	install_kernel_headers
	install_initramfs
	generate_fstab
	install_bootloader

	# Network, administration, desktop
	configure_network
	setup_sudo
	finalize_root_account
	install_desktop
	install_additional_packages

	# Do this last: the installer needs the copied resolv.conf for downloads until now.
	einfo "Linking /etc/resolv.conf to systemd-resolved"
	ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf \
		|| die "Could not link /etc/resolv.conf"

	einfo "Exherbo installation complete."
	einfo "Kernel $KERNEL_RELEASE was built by hand: cave does not update it. See the README for how to build a new one."
	einfo "You can now exit the chroot, unmount and reboot."
}

function main_install() {
	[[ $# == 0 ]] || die "Too many arguments"

	gentoo_umount
	install_stage3
	copy_live_wifi_profiles

	mount_efivars
	gentoo_chroot "$ROOT_MOUNTPOINT" "$GENTOO_INSTALL_REPO_BIND/install" __install_gentoo_in_chroot
}

function main_chroot() {
	# Skip if already mounted
	mountpoint -q -- "$1" \
		|| die "'$1' is not a mountpoint"

	gentoo_chroot "$@"
}
