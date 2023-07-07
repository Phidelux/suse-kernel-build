#!/bin/sh

# Abort on error.
set -e

LINUX_ARCH="$(uname -m)"
LINUX_MIRROR="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
LINUX_VERSION="$(git ls-remote --tags --refs --sort="v:refname" "${LINUX_MIRROR}" | tail -n1 | sed 's/.*\///' | cut -c2-)"
LINUX_PACKAGE_SERVER="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/snapshot/"
LINUX_PACKAGE="linux-${LINUX_VERSION}.tar.gz"
LINUX_LAST_CONFIG="/boot/config-$(uname -r)"
LINUX_VERSION_SUFFIX="phidelux"
LINUX_BUILD_DEPENDENCIES="git ncurses-devel bc openssl libopenssl-devel dwarves rpm-build libelf-devel flex bison"
LINUX_BUILD_DIR="build"
LINUX_SOURCE_DIR="/usr/src/linux-${LINUX_VERSION}"
LINUX_RPM_DIR="${HOME}/rpmbuild/RPMS/${LINUX_ARCH}"

error() {
	printf "Error: %s\n" "$*" >&2
}

info() {
	printf "%s\n" "$*"
}

notify() {
	notify-send --expire-time=2000 --urgency=critical "$*"
}

usage() {
	rc=0

	if [ -n "${1}" ]; then
		rc="${1}"
	fi

	if [ -n "${2}" ]; then
		error "${2}\n"
	fi

	echo "${MKLFS_USAGE}"

	exit "${rc}"
}

yesno() {
	if [ ! "$*" ]; then
		error "Missing question"
	fi

	while [ -z "${OK}" ]; do
		printf "%s" "$*" >&2
		read -r ANS
		if [ -z "${ANS}" ]; then
			ANS="n"
		else
			ANS=$(tr '[:upper:]' '[:lower:]' << EOF
${ANS}
EOF
			)
		fi

		if [ "${ANS}" = "y" ] || [ "${ANS}" = "yes" ] || [ "${ANS}" = "n" ] || [ "${ANS}" = "no" ]; then
			OK=1
		fi

		if [ -z "${OK}" ]; then
			warning "Valid answers are: yes/no"
		fi
	done

	[ "${ANS}" = "y" ] || [ "${ANS}" = "yes" ]
}

info "Checking build dependencies ..."
for pkg in ${LINUX_BUILD_DEPENDENCIES}; do
	info "Checking if ${pkg} is installed ..."
	if ! rpm -q "${pkg}" >/dev/null; then
		error "${pkg} is not installed."
		exit 0
	fi
done

if ! [ -f "${LINUX_PACKAGE}" ]; then
	info "Downloading latest linux kernel ${LINUX_VERSION} ..."
	wget "${LINUX_PACKAGE_SERVER}${LINUX_PACKAGE}"
else
	info "Kernel tarball ${LINUX_PACKAGE} already exists - continue ..."
fi

if ! [ -d "${LINUX_SOURCE_DIR}" ]; then
	info "Extracting kernel sources to ${LINUX_SOURCE_DIR} ..."
	sudo tar xzf "${LINUX_PACKAGE}" -C /usr/src
else
	info "Kernel sources for ${LINUX_VERSION} already extracted - continue ..."
fi

info "Create a symlink to the kernel sources ..."
if [ -e "/usr/src/linux" ]; then
	sudo rm /usr/src/linux
fi

sudo ln -s "${LINUX_SOURCE_DIR}" /usr/src/linux

info "Creating build directory ..."
if ! [ -d "${LINUX_BUILD_DIR}" ]; then
	mkdir -p "${LINUX_BUILD_DIR}"
fi

cd "${LINUX_BUILD_DIR}"

info "Cleanup existing build artifacts ..."
make -C /usr/src/linux mrproper

# HINT: You can also copy the running kernel configuration from /boot:
#       cp /boot/config-`uname -r`* .config
info "Copy ${LINUX_LAST_CONFIG} to build directory ..."
cp "${LINUX_LAST_CONFIG}" ".config"

notify "Kernel build started"

info "Copy running kernel configuration and apply default for new settings ..."
make -C /usr/src/linux O="$PWD" clean
make -C /usr/src/linux olddefconfig O="$PWD"

info "Stripping unnecessary kernel configurations ..."
/usr/src/linux/scripts/config --file ".config" --disable CONFIG_MODULE_SIG_KEY

info "Ensure debugging is disabled ..."
/usr/src/linux/scripts/config --file ".config" --disable DEBUG_KERNEL
/usr/src/linux/scripts/config --file ".config" --disable DEBUG_INFO

info "Enable kernel early printing ..."
/usr/src/linux/scripts/config --file ".config" --enable CONFIG_EARLY_PRINTK

# HINT: In order to see changes applied by the above call, you can use
#       scripts/diffconfig .config{.old,}
info "View configuration changes with scripts/diffconfig .config{.old,}"

if yesno "Do you like to remove old kernel rpms from ${HOME}/rpmbuild/RPMS/${LINUX_ARCH}/ (default no) ? "; then
    info "Removing old kernel rpms from ${HOME}/rpmbuild/RPMS/${LINUX_ARCH}/ ..."
    find "${LINUX_RPM_DIR}" -name "kernel-*.rpm" -exec rm {} \;
fi

# HINT: Instead of installing the kernel via a distribution package, you can
#       build and install the kernel and the corresponging modules directly:
#
#       KERNEL_BUILD_DIR="build"
#       KERNEL_VERSION_SUFFIX="awesome-kernel"
#       make -j "$(nproc)" LOCALVERSION=-"$KERNEL_VERSION_SUFFIX" O="${KERNEL_BUILD_DIR}"
# FIXME: Fix build with LLVM=1
info "Building the new linux kernel ..."
command time -f "\t\n\n Elapsed Time : %E \n\n" make -j"$(nproc)" V=1 O="$PWD" LOCALVERSION=-"${LINUX_VERSION_SUFFIX}" binrpm-pkg

KERNEL_RPM="$(find "${LINUX_RPM_DIR}" -name "kernel-$(printf "%s" "${LINUX_VERSION}" | tr '-' '_')_1_default_${LINUX_VERSION_SUFFIX}-1.${LINUX_ARCH}.rpm" -print | head -n1)"

# HINT: You can then install the new kernel and kernel modules using:
#
#       sudo make modules_install
#       sudo make install
if ! yesno "Do you like to install the fresh compiled kernel $(basename "${KERNEL_RPM}") (default no) ? "; then
	info "Aborting."
	exit 0
fi

info "Installing the new linux kernel ..."
sudo rpm -ivh "${KERNEL_RPM}"

# HINT: Previously you would have generated the initramfs with mkinitrd,
#       however this was deprecated in favor of dracut in 2021.
info "Creating a new initramfs ..."
sudo dracut -f --regenerate-all

info "Backup bootloader config to /boot/grub2/grub.cfg.bak"
sudo cp /boot/grub2/grub.cfg /boot/grub2/grub.cfg.bak

info "Updating bootloader information ..."
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

