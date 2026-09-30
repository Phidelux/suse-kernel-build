#!/bin/sh

# Abort on error.
set -e

LINUX_ARCH="$(uname -m)"
LINUX_MIRROR="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
LINUX_PACKAGE_SERVER="${LINUX_MIRROR}/snapshot/"
LINUX_DEFAULT_CONFIG="/boot/config-$(uname -r)"
LINUX_LAST_CONFIG="${LINUX_DEFAULT_CONFIG}"
LINUX_VERSION_SUFFIX="${USER}"
LINUX_BUILD_DEPENDENCIES="git gcc make perl wget tar time zstd dracut ncurses-devel bc openssl libopenssl-devel dwarves rpm-build libelf-devel flex bison"
LINUX_BUILD_DIR="$(pwd)/build"
LINUX_SOURCE_DIR="/usr/src/linux-${LINUX_VERSION}"
LINUX_RPMBUILD_DIR="${LINUX_BUILD_DIR}/rpmbuild/"
LINUX_RPM_DIR="${LINUX_RPMBUILD_DIR}/RPMS/${LINUX_ARCH}"
LINUX_RPM_BUILDROOT="${LINUX_RPMBUILD_DIR}/BUILDROOT"

SCRIPT_NAME=$(basename "$0")
SCRIPT_USAGE=$(cat <<EOF
Usage:

    ${SCRIPT_NAME} [--GLOBAL-OPTIONS]

    Global Options:
    --help, -h              Help.
    --verbose, -v           Display additional information.
    --config, -c <config>   Use the specified configuration file to build the kernel.
    --debug-kernel, -d      Build a debug kernel.
    --no-reconfigure, -r    Do not reconfigure the current kernel.
    --keep-artifacts, -k    Keep previous build artifacts (do not run mrproper).
    --build-only, -b        Only build the kernel without installing it.
    --install-only, -i      Try to install latest kernel built in ${LINUX_BUILD_DIR}.

    This script will download, unpack build and install the latest stable
    mainline linux kernel into an openSUSE system and derivates.
EOF
)

has_value() {
	if [ -n "${1}" ] && ! case "${1}" in -*) true;; *) false;; esac; then
		return 0
	fi

	return 1
}

error() {
	printf "Error: %s\n" "$*" >&2
}

warning() {
	printf "Warning: %s\n" "$*" >&2
}

info() {
	if [ -n "${VERBOSE_INFO}" ]; then
		printf "%s\n" "$*"
	fi
}

notify() {
	notify-send --expire-time=2000 --urgency=critical "$*" >/dev/null 2>&1 || true
}

usage() {
	rc=0

	if [ -n "${1}" ]; then
		rc="${1}"
	fi

	if [ -n "${2}" ]; then
		error "${2}"
	fi

	echo "${SCRIPT_USAGE}"

	exit "${rc}"
}

latest_version() {
	# Only take release tags (no -rc), sorted by version, without the leading "v".
	git ls-remote --tags --refs "${LINUX_MIRROR}" 'v*' \
		| sed 's#.*refs/tags/v##' \
		| grep -v -- '-rc' \
		| sort -V \
		| tail -n1
}

absolute_path() {
	cd "$(dirname "${1}")"
	case $(basename "${1}") in
		..) dirname "$(pwd)";;
		.)  pwd;;
		*)  echo "$(pwd)/$(basename "${1}")";;
	esac
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

while :; do
	case "$1" in
		-h|--help)
			usage
			;;
		-v|--verbose)
			VERBOSE_INFO=1
			;;
		-c|--config)
			if has_value "${2}"; then
				LINUX_LAST_CONFIG=$(absolute_path "${2}")
				if ! [ -f "${LINUX_LAST_CONFIG}" ]; then
					usage 1 "${LINUX_LAST_CONFIG} is not a file or does not exist."
				fi

				shift
			else
				usage 1 "Missing value for option ${1}."
			fi
			;;
		-d|--debug-kernel)
			LINUX_DEBUG_KERNEL=1
			;;
		-k|--keep-artifacts)
			LINUX_NO_CLEAN=1
			;;
		-r|--no-reconfigure)
			LINUX_NO_RECONFIGURE=1
			;;
		-b|--build-only)
			LINUX_BUILD_ONLY=1
			;;
		-i|--install-only)
			LINUX_INSTALL_ONLY=1
			;;
		-?*)
			usage 1 "Unknown option: $1"
			;;
		*)
			break
			;;
	esac

	shift
done

if [ -n "${LINUX_NO_RECONFIGURE}" ] && { [ "${LINUX_LAST_CONFIG}" != "${LINUX_DEFAULT_CONFIG}" ] || [ -n "${LINUX_DEBUG_KERNEL}" ]; }; then
	usage 1 "You cannot use -d or -c without reconfiguring the kernel."
fi

if [ -n "${LINUX_INSTALL_ONLY}" ] && { [ "${LINUX_LAST_CONFIG}" != "${LINUX_DEFAULT_CONFIG}" ] || [ -n "${LINUX_DEBUG_KERNEL}" ] || [ -n "${LINUX_BUILD_ONLY}" ]; }; then
	usage 1 "You cannot use -d, -b or -c without rebuilding the kernel."
fi

info "Checking build dependencies ..."
for pkg in ${LINUX_BUILD_DEPENDENCIES}; do
	info "Checking if ${pkg} is installed ..."
	if ! rpm -q --whatprovides "${pkg}" >/dev/null 2>&1; then
		error "${pkg} is not installed."
		exit 1
	fi
done

if [ -z "${LINUX_INSTALL_ONLY}" ]; then
	LINUX_VERSION="$(latest_version)"
	if [ -z "${LINUX_VERSION}" ]; then
		error "Could not determine the latest kernel version from ${LINUX_MIRROR}."
		exit 1
	fi

	LINUX_PACKAGE="linux-${LINUX_VERSION}.tar.gz"
	LINUX_SOURCE_DIR="/usr/src/linux-${LINUX_VERSION}"

	if ! [ -f "${LINUX_PACKAGE}" ]; then
		info "Downloading latest linux kernel ${LINUX_VERSION} ..."
		if ! wget -O "${LINUX_PACKAGE}.part" "${LINUX_PACKAGE_SERVER}${LINUX_PACKAGE}"; then
			rm -f "${LINUX_PACKAGE}.part"
			error "Download of ${LINUX_PACKAGE} failed."
			exit 1
		fi
		mv "${LINUX_PACKAGE}.part" "${LINUX_PACKAGE}"
	else
		info "Kernel tarball ${LINUX_PACKAGE} already exists - continue ..."
	fi

	if ! [ -d "${LINUX_SOURCE_DIR}" ]; then
		info "Extracting kernel sources to ${LINUX_SOURCE_DIR} ..."
		sudo tar xzf "${LINUX_PACKAGE}" -C /usr/src
	else
		info "Kernel sources for ${LINUX_VERSION} already extracted - continue ..."
	fi

	# HINT: Older versions of depmod require the version string to start with three
	#       digits, this would include a symlink to fix this. Newer kernels
    #       no longer contain this hack, so only patch it if it is present.
	if [ -f "${LINUX_SOURCE_DIR}/scripts/depmod.sh" ] && grep -q '^depmod_hack_needed' "${LINUX_SOURCE_DIR}/scripts/depmod.sh"; then
		info "Disable the depmod hack ..."
		sudo sed -i '/^depmod_hack_needed/ s/true/false/' "${LINUX_SOURCE_DIR}/scripts/depmod.sh"
	fi

	info "Create a symlink to the kernel sources ..."
	sudo ln -sfn "${LINUX_SOURCE_DIR}" /usr/src/linux

	info "Creating build directory ..."
	mkdir -p "${LINUX_BUILD_DIR}"
	cd "${LINUX_BUILD_DIR}"

	if [ -z "${LINUX_NO_CLEAN}" ]; then
		info "Cleanup existing build artifacts ..."
		make -C /usr/src/linux O="${LINUX_BUILD_DIR}" clean
	fi

	if [ -z "${LINUX_NO_RECONFIGURE}" ]; then
		# HINT: You can also copy the running kernel configuration from /boot:
		#       cp /boot/config-`uname -r`* .config
		if [ -f "${LINUX_LAST_CONFIG}" ]; then
			info "Copy ${LINUX_LAST_CONFIG} to build directory ..."
			cp "${LINUX_LAST_CONFIG}" ".config"
		elif [ -z "${LINUX_CUSTOM_CONFIG}" ] && [ -r /proc/config.gz ]; then
			info "Copy /proc/config.gz to build directory ..."
			zcat /proc/config.gz > ".config"
		else
			error "No kernel configuration found (tried ${LINUX_LAST_CONFIG} and /proc/config.gz)."
			exit 1
		fi

		info "Stripping distribution specific kernel configurations ..."
		/usr/src/linux/scripts/config --file ".config" \
			--set-str MODULE_SIG_KEY "certs/signing_key.pem" \
			--set-str SYSTEM_TRUSTED_KEYS "" \
			--set-str SYSTEM_REVOCATION_KEYS "" \
			--disable SUSE_KERNEL_RELEASED

		# HINT: Since Linux 5.18 DEBUG_INFO can no longer be switched directly,
		#       it is selected through the "Debug information" choice.
		if [ -n "${LINUX_DEBUG_KERNEL}" ]; then
			info "Ensure debugging is enabled ..."
			/usr/src/linux/scripts/config --file ".config" \
				--enable EXPERT \
				--enable DEBUG_KERNEL \
				--disable DEBUG_INFO_NONE \
				--enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
		else
			info "Ensure debugging is disabled ..."
			/usr/src/linux/scripts/config --file ".config" \
				--disable EXPERT \
				--disable DEBUG_KERNEL \
				--disable DEBUG_INFO \
				--disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
				--disable DEBUG_INFO_DWARF4 \
				--disable DEBUG_INFO_DWARF5 \
				--disable DEBUG_INFO_BTF \
				--enable DEBUG_INFO_NONE
		fi

		info "Enable kernel early printing ..."
		/usr/src/linux/scripts/config --file ".config" --enable EARLY_PRINTK

		info "Copy running kernel configuration and apply default for new settings ..."
		make -C /usr/src/linux O="${LINUX_BUILD_DIR}" olddefconfig
	fi

	# HINT: In order to see changes applied by the above call, you can use
	#       scripts/diffconfig .config{.old,}
	info "View configuration changes with /usr/src/linux/scripts/diffconfig .config{.old,}"

	if [ -d "${LINUX_RPM_DIR}" ] && yesno "Do you like to remove old kernel rpms from ${LINUX_RPM_DIR} (default no) ? "; then
	    info "Removing old kernel rpms from ${LINUX_RPM_DIR} ..."
	    find "${LINUX_RPM_DIR}" -name "kernel-*.rpm" -exec rm {} \;
	fi

	info "Removing old kernel buildroots from ${LINUX_RPM_BUILDROOT} ..."
	rm -rf "${LINUX_RPM_BUILDROOT:?}"/*

	notify "Kernel build started"

	# HINT: Instead of installing the kernel via a distribution package, you can
	#       build and install the kernel and the corresponging modules directly:
	#
	#       KERNEL_BUILD_DIR="build"
	#       KERNEL_VERSION_SUFFIX="awesome-kernel"
	#       make -j "$(nproc)" LOCALVERSION=-"${KERNEL_VERSION_SUFFIX}" O="${LINUX_BUILD_DIR}"
	# FIXME: Fix build with LLVM=1
	info "Building the new linux kernel ..."
	command time -f "\t\n\n Elapsed Time : %E \n\n" \
		make -C /usr/src/linux -j"$(nproc)" V=1 O="${LINUX_BUILD_DIR}" \
		LOCALVERSION=-"${LINUX_VERSION_SUFFIX}" INSTALL_MOD_STRIP=1 binrpm-pkg
fi

if [ -z "${LINUX_BUILD_ONLY}" ]; then
	# The exact kernel release (including CONFIG_LOCALVERSION like "-default"
	# and our LOCALVERSION suffix) is written by kbuild during the build.
	KERNEL_RELEASE_FILE="${LINUX_BUILD_DIR}/include/config/kernel.release"
	if ! [ -f "${KERNEL_RELEASE_FILE}" ]; then
		error "No kernel build found in ${LINUX_BUILD_DIR}."
		exit 1
	fi
	KERNEL_RELEASE="$(cat "${KERNEL_RELEASE_FILE}")"

	# The rpm version is the kernel release with "-" replaced by "_", the rpm
	# release is the build counter. Pick the newest build.
	KERNEL_RPM="$(find "${LINUX_RPM_DIR}" -name "kernel-$(printf "%s" "${KERNEL_RELEASE}" | tr '-' '_')-*.${LINUX_ARCH}.rpm" -print 2>/dev/null | sort -V | tail -n1)"
	if [ -z "${KERNEL_RPM}" ]; then
		error "No kernel rpm for ${KERNEL_RELEASE} found in ${LINUX_RPM_DIR}."
		exit 1
	fi

	# HINT: You can then install the new kernel and kernel modules using:
	#
	#       sudo make modules_install
	#       sudo make install
	info "Installing ${KERNEL_RPM} ..."
	sudo rpm -ivh "${KERNEL_RPM}"

	# HINT: Previously you would have generated the initramfs with mkinitrd,
	#       however this was deprecated in favor of dracut in 2021.
	info "Creating a new initramfs for ${KERNEL_RELEASE} ..."
	sudo dracut -f --kver "${KERNEL_RELEASE}"

	if [ -f /boot/grub2/grub.cfg ]; then
		info "Backup bootloader config to /boot/grub2/grub.cfg.bak"
		sudo cp /boot/grub2/grub.cfg /boot/grub2/grub.cfg.bak

		info "Updating bootloader information ..."
		sudo grub2-mkconfig -o /boot/grub2/grub.cfg
	else
		warning "/boot/grub2/grub.cfg not found - please update your bootloader manually."
	fi
fi

