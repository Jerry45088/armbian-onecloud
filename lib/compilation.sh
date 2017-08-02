# Copyright (c) 2015 Igor Pecovnik, igor.pecovnik@gma**.com
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.

# This file is a part of the Armbian build script
# https://github.com/armbian/build/

# Functions:
# compile_uboot
# compile_kernel
# compile_sunxi_tools
# grab_version
# find_toolchain
# advanced_patch
# process_patch_file
# install_external_applications
# write_uboot
# customize_image
# userpatch_create
# overlayfs_wrapper

compile_uboot()
{
	# not optimal, but extra cleaning before overlayfs_wrapper should keep sources directory clean
	if [[ $CLEAN_LEVEL == *make* ]]; then
		display_alert "Cleaning" "$BOOTSOURCEDIR" "info"
		(cd $SRC/cache/sources/$BOOTSOURCEDIR; make clean > /dev/null 2>&1)
	fi

	if [[ $USE_OVERLAYFS == yes ]]; then
		local ubootdir=$(overlayfs_wrapper "wrap" "$SRC/cache/sources/$BOOTSOURCEDIR" "u-boot_${LINUXFAMILY}_${BRANCH}")
	else
		local ubootdir="$SRC/cache/sources/$BOOTSOURCEDIR"
	fi
	cd "$ubootdir"

	# read uboot version
	local version=$(grab_version "$ubootdir")

	display_alert "Compiling u-boot" "$version" "info"

	local toolchain=""
	if [[ -n $UBOOT_USE_GCC ]]; then
		toolchain=$(find_toolchain "$UBOOT_COMPILER" "$UBOOT_USE_GCC")
		[[ -z $toolchain ]] && exit_with_error "Could not find required toolchain" "${UBOOT_COMPILER}gcc $UBOOT_USE_GCC"
	fi

	display_alert "Compiler version" "${UBOOT_COMPILER}gcc $(eval ${toolchain:+env PATH=$toolchain:$PATH} ${UBOOT_COMPILER}gcc -dumpversion)" "info"

	# create directory structure for the .deb package
	local uboot_name=${CHOSEN_UBOOT}_${REVISION}_${ARCH}
	rm -rf $SRC/.tmp/$uboot_name
	mkdir -p $SRC/.tmp/$uboot_name/usr/lib/{u-boot,$uboot_name} $SRC/.tmp/$uboot_name/DEBIAN

	# process compilation for one or multiple targets
	while read -r target; do
		local target_make=$(cut -d';' -f1 <<< $target)
		local target_patchdir=$(cut -d';' -f2 <<< $target)
		local target_files=$(cut -d';' -f3 <<< $target)

		display_alert "Checking out sources"
		git checkout -f -q HEAD

		if [[ $CLEAN_LEVEL == *make* ]]; then
			display_alert "Cleaning" "$BOOTSOURCEDIR" "info"
			(cd $SRC/cache/sources/$BOOTSOURCEDIR; make clean > /dev/null 2>&1)
		fi

		[[ $FORCE_CHECKOUT == yes ]] && advanced_patch "u-boot" "$BOOTPATCHDIR" "$BOARD" "$target_patchdir" "$BRANCH" "${LINUXFAMILY}-${BOARD}-${BRANCH}"

		# create patch for manual source changes
		[[ $CREATE_PATCHES == yes ]] && userpatch_create "u-boot"

		eval CCACHE_BASEDIR="$(pwd)" ${toolchain:+env PATH=$toolchain:$PATH} \
			'make $CTHREADS $BOOTCONFIG CROSS_COMPILE="$CCACHE $UBOOT_COMPILER"' 2>&1 \
			${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/debug/compilation.log'} \
			${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'}

		[[ -f .config ]] && sed -i 's/CONFIG_LOCALVERSION=""/CONFIG_LOCALVERSION="-armbian"/g' .config
		[[ -f .config ]] && sed -i 's/CONFIG_LOCALVERSION_AUTO=.*/# CONFIG_LOCALVERSION_AUTO is not set/g' .config
		[[ -f tools/logos/udoo.bmp ]] && cp $SRC/packages/blobs/splash/udoo.bmp tools/logos/udoo.bmp
		touch .scmversion

		# $BOOTDELAY can be set in board family config, ensure autoboot can be stopped even if set to 0
		[[ $BOOTDELAY == 0 ]] && echo -e "CONFIG_ZERO_BOOTDELAY_CHECK=y" >> .config
		[[ -n $BOOTDELAY ]] && sed -i "s/^CONFIG_BOOTDELAY=.*/CONFIG_BOOTDELAY=${BOOTDELAY}/" .config || [[ -f .config ]] && echo "CONFIG_BOOTDELAY=${BOOTDELAY}" >> .config

		eval CCACHE_BASEDIR="$(pwd)" ${toolchain:+env PATH=$toolchain:$PATH} \
			'make $target_make $CTHREADS CROSS_COMPILE="$CCACHE $UBOOT_COMPILER"' 2>&1 \
			${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/debug/compilation.log'} \
			${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Compiling u-boot..." $TTY_Y $TTY_X'} \
			${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'}

		[[ ${PIPESTATUS[0]} -ne 0 ]] && exit_with_error "U-boot compilation failed"

		# copy files to build directory
		for f in $target_files; do
			local f_src=$(cut -d':' -f1 <<< $f)
			if [[ $f == *:* ]]; then
				local f_dst=$(cut -d':' -f2 <<< $f)
			else
				local f_dst=$(basename $f_src)
			fi
			[[ ! -f $f_src ]] && exit_with_error "U-boot file not found" "$(basename $f_src)"
			cp $f_src $SRC/.tmp/$uboot_name/usr/lib/$uboot_name/$f_dst
		done
	done <<< "$UBOOT_TARGET_MAP"

	# set up postinstall script
	cat <<-EOF > $SRC/.tmp/$uboot_name/DEBIAN/postinst
	#!/bin/bash
	source /usr/lib/u-boot/platform_install.sh
	[[ \$DEVICE == /dev/null ]] && exit 0
	[[ -z \$DEVICE ]] && DEVICE="/dev/mmcblk0"
	[[ \$(type -t setup_write_uboot_platform) == function ]] && setup_write_uboot_platform
	echo "Updating u-boot on device \$DEVICE" >&2
	write_uboot_platform \$DIR \$DEVICE
	sync
	exit 0
	EOF
	chmod 755 $SRC/.tmp/$uboot_name/DEBIAN/postinst

	# declare -f on non-defined function does not do anything
	cat <<-EOF > $SRC/.tmp/$uboot_name/usr/lib/u-boot/platform_install.sh
	DIR=/usr/lib/$uboot_name
	$(declare -f write_uboot_platform)
	$(declare -f setup_write_uboot_platform)
	EOF

	# set up control file
	cat <<-EOF > $SRC/.tmp/$uboot_name/DEBIAN/control
	Package: linux-u-boot-${BOARD}-${BRANCH}
	Version: $REVISION
	Architecture: $ARCH
	Maintainer: $MAINTAINER <$MAINTAINERMAIL>
	Installed-Size: 1
	Section: kernel
	Priority: optional
	Provides: armbian-u-boot
	Replaces: armbian-u-boot
	Conflicts: armbian-u-boot, u-boot-sunxi
	Description: Uboot loader $version
	EOF

	# copy config file to the package
	# useful for FEL boot with overlayfs_wrapper
	[[ -f .config && -n $BOOTCONFIG ]] && cp .config $SRC/.tmp/$uboot_name/usr/lib/u-boot/$BOOTCONFIG
	# copy license files from typical locations
	[[ -f COPYING ]] && cp COPYING $SRC/.tmp/$uboot_name/usr/lib/u-boot/LICENSE
	[[ -f Licenses/README ]] && cp Licenses/README $SRC/.tmp/$uboot_name/usr/lib/u-boot/LICENSE
	[[ -f arm-trusted-firmware/license.md ]] && cp arm-trusted-firmware/license.md $SRC/.tmp/$uboot_name/usr/lib/u-boot/LICENSE.atf

	display_alert "Building deb" "${uboot_name}.deb" "info"
	(cd $SRC/.tmp/; eval 'dpkg -b $uboot_name 2>&1' ${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/debug/compilation.log'})
	rm -rf $SRC/.tmp/$uboot_name

	[[ ! -f $SRC/.tmp/${uboot_name}.deb ]] && exit_with_error "Building u-boot package failed"

	mv $SRC/.tmp/${uboot_name}.deb $DEST/debs/
}

compile_kernel()
{
	if [[ $CLEAN_LEVEL == *make* ]]; then
		display_alert "Cleaning" "$LINUXSOURCEDIR" "info"
		(cd $SRC/cache/sources/$LINUXSOURCEDIR; make ARCH=$ARCHITECTURE clean >/dev/null 2>&1)
	fi

	if [[ $USE_OVERLAYFS == yes ]]; then
		local kerneldir=$(overlayfs_wrapper "wrap" "$SRC/cache/sources/$LINUXSOURCEDIR" "kernel_${LINUXFAMILY}_${BRANCH}")
	else
		local kerneldir="$SRC/cache/sources/$LINUXSOURCEDIR"
	fi
	cd "$kerneldir"

	# this is a patch that Ubuntu Trusty compiler works
	# TODO: Check if still required
	if [[ $(patch --dry-run -t -p1 < $SRC/patch/kernel/compiler.patch | grep Reversed) != "" ]]; then
		display_alert "Patching kernel for compiler support"
		[[ $FORCE_CHECKOUT == yes ]] && patch --batch --silent -t -p1 < $SRC/patch/kernel/compiler.patch >> $DEST/debug/output.log 2>&1
	fi

	[[ $FORCE_CHECKOUT == yes ]] && advanced_patch "kernel" "$KERNELPATCHDIR" "$BOARD" "" "$BRANCH" "$LINUXFAMILY-$BRANCH"

	if ! grep -qoE '^-rc[[:digit:]]+' <(grep "^EXTRAVERSION" Makefile | head -1 | awk '{print $(NF)}'); then
		sed -i 's/EXTRAVERSION = .*/EXTRAVERSION = /' Makefile
	fi
	rm -f localversion

	# read kernel version
	local version=$(grab_version "$kerneldir")

	# create linux-source package - with already patched sources
	local sources_pkg_dir=$SRC/.tmp/linux-source-${BRANCH}-${LINUXFAMILY}_${REVISION}_all
	rm -rf ${sources_pkg_dir}
	mkdir -p $sources_pkg_dir/usr/src/ $sources_pkg_dir/usr/share/doc/linux-source-${version}-${LINUXFAMILY} $sources_pkg_dir/DEBIAN

	display_alert "Compressing sources for the linux-source package"
	tar cp --directory="$kerneldir" --exclude='./.git/' . | pixz -4 > $sources_pkg_dir/usr/src/linux-source-${version}-${LINUXFAMILY}.tar.xz
	cp COPYING $sources_pkg_dir/usr/share/doc/linux-source-${version}-${LINUXFAMILY}/LICENSE

	# create patch for manual source changes in debug mode
	[[ $CREATE_PATCHES == yes ]] && userpatch_create "kernel"

	display_alert "Compiling $BRANCH kernel" "$version" "info"

	local toolchain=""
	if [[ -n $KERNEL_USE_GCC ]]; then
		toolchain=$(find_toolchain "$KERNEL_COMPILER" "$KERNEL_USE_GCC")
		[[ -z $toolchain ]] && exit_with_error "Could not find required toolchain" "${KERNEL_COMPILER}gcc $KERNEL_USE_GCC"
	fi

	display_alert "Compiler version" "${KERNEL_COMPILER}gcc $(eval ${toolchain:+env PATH=$toolchain:$PATH} ${KERNEL_COMPILER}gcc -dumpversion)" "info"

	# copy kernel config
	if [[ $KERNEL_KEEP_CONFIG == yes && -f $DEST/$LINUXCONFIG.config ]]; then
		display_alert "Using previous kernel config" "$DEST/$LINUXCONFIG.config" "info"
		cp $DEST/$LINUXCONFIG.config .config
	else
		if [[ -f $SRC/userpatches/$LINUXCONFIG.config ]]; then
			display_alert "Using kernel config provided by user" "userpatches/$LINUXCONFIG.config" "info"
			cp $SRC/userpatches/$LINUXCONFIG.config .config
		else
			display_alert "Using kernel config file" "lib/config/kernel/$LINUXCONFIG.config" "info"
			cp $SRC/config/kernel/$LINUXCONFIG.config .config
		fi
	fi

	# hack for deb builder. To pack what's missing in headers pack.
	cp $SRC/patch/misc/headers-debian-byteshift.patch /tmp

	if [[ $KERNEL_CONFIGURE != yes ]]; then
		if [[ $BRANCH == default ]]; then
			make ARCH=$ARCHITECTURE CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" silentoldconfig
		else
			# TODO: check if required
			make ARCH=$ARCHITECTURE CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" olddefconfig
		fi
	else
		make $CTHREADS ARCH=$ARCHITECTURE CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" oldconfig
		make $CTHREADS ARCH=$ARCHITECTURE CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" menuconfig
		# store kernel config in easily reachable place
		display_alert "Exporting new kernel config" "$DEST/$LINUXCONFIG.config" "info"
		cp .config $DEST/config/$LINUXCONFIG.config
		# export defconfig too if requested
		if [[ $KERNEL_EXPORT_DEFCONFIG == yes ]]; then
			make ARCH=$ARCHITECTURE CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" savedefconfig > /dev/null 2>&1
			[[ -f defconfig ]] && cp defconfig $DEST/config/$LINUXCONFIG.defconfig
		fi
	fi

	xz < .config > $sources_pkg_dir/usr/src/${LINUXCONFIG}_${version}_${REVISION}_config.xz

	eval CCACHE_BASEDIR="$(pwd)" ${toolchain:+env PATH=$toolchain:$PATH} \
		'make $CTHREADS ARCH=$ARCHITECTURE CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" LOCALVERSION="-$LINUXFAMILY" \
		$KERNEL_IMAGE_TYPE modules dtbs 2>&1' \
		${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/debug/compilation.log'} \
		${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Compiling kernel..." $TTY_Y $TTY_X'} \
		${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'}

	if [[ ${PIPESTATUS[0]} -ne 0 || ! -f arch/$ARCHITECTURE/boot/$KERNEL_IMAGE_TYPE ]]; then
		exit_with_error "Kernel was not built" "@host"
	fi

	# different packaging for 4.3+
	if linux-version compare $version ge 4.3; then
		local kernel_packing="bindeb-pkg"
	else
		local kernel_packing="deb-pkg"
	fi

	display_alert "Creating packages"

	# produce deb packages: image, headers, firmware, dtb
	eval CCACHE_BASEDIR="$(pwd)" ${toolchain:+env PATH=$toolchain:$PATH} \
		'make -j1 $kernel_packing KDEB_PKGVERSION=$REVISION LOCALVERSION="-${LINUXFAMILY}" \
		KBUILD_DEBARCH=$ARCH ARCH=$ARCHITECTURE DEBFULLNAME="$MAINTAINER" DEBEMAIL="$MAINTAINERMAIL" CROSS_COMPILE="$CCACHE $KERNEL_COMPILER" 2>&1' \
		${PROGRESS_LOG_TO_FILE:+' | tee -a $DEST/debug/compilation.log'} \
		${OUTPUT_DIALOG:+' | dialog --backtitle "$backtitle" --progressbox "Creating kernel packages..." $TTY_Y $TTY_X'} \
		${OUTPUT_VERYSILENT:+' >/dev/null 2>/dev/null'}

	cat <<-EOF > $sources_pkg_dir/DEBIAN/control
	Package: linux-source-${version}-${LINUXFAMILY}
	Version: ${version}-${LINUXFAMILY}+${REVISION}
	Architecture: all
	Maintainer: $MAINTAINER <$MAINTAINERMAIL>
	Section: kernel
	Priority: optional
	Depends: binutils, coreutils
	Provides: linux-source
	Recommends: gcc, make
	Description: This package provides the source code for the Linux kernel $version
	EOF

	dpkg-deb -z0 -b $sources_pkg_dir ${sources_pkg_dir}.deb
	mv ${sources_pkg_dir}.deb $DEST/debs/
	rm -rf $sources_pkg_dir

	cd ..
	mv *.deb $DEST/debs/ || exit_with_error "Failed moving kernel DEBs"
}

compile_sunxi_tools()
{
	fetch_from_repo "https://github.com/linux-sunxi/sunxi-tools.git" "sunxi-tools" "branch:master"
	# Compile and install only if git commit hash changed
	cd $SRC/cache/sources/sunxi-tools
	# need to check if /usr/loca/bin/sunxi-fexc to detect new Docker containers with old cached sources
	if [[ ! -f .commit_id || $(git rev-parse @ 2>/dev/null) != $(<.commit_id) || ! -f /usr/local/bin/sunxi-fexc ]]; then
		display_alert "Compiling" "sunxi-tools" "info"
		make -s clean >/dev/null
		make -s tools >/dev/null
		mkdir -p /usr/local/bin/
		make install-tools >/dev/null 2>&1
		git rev-parse @ 2>/dev/null > .commit_id
	fi
}

grab_version()
{
	local ver=()
	ver[0]=$(grep "^VERSION" $1/Makefile | head -1 | awk '{print $(NF)}' | grep -oE '^[[:digit:]]+')
	ver[1]=$(grep "^PATCHLEVEL" $1/Makefile | head -1 | awk '{print $(NF)}' | grep -oE '^[[:digit:]]+')
	ver[2]=$(grep "^SUBLEVEL" $1/Makefile | head -1 | awk '{print $(NF)}' | grep -oE '^[[:digit:]]+')
	ver[3]=$(grep "^EXTRAVERSION" $1/Makefile | head -1 | awk '{print $(NF)}' | grep -oE '^-rc[[:digit:]]+')
	echo "${ver[0]:-0}${ver[1]:+.${ver[1]}}${ver[2]:+.${ver[2]}}${ver[3]}"
}

# find_toolchain <compiler_prefix> <expression>
#
# returns path to toolchain that satisfies <expression>
#
find_toolchain()
{
	local compiler=$1
	local expression=$2
	local dist=10
	local toolchain=""
	# extract target major.minor version from expression
	local target_ver=$(grep -oE "[[:digit:]].[[:digit:]]" <<< "$expression")
	for dir in $SRC/cache/toolchains/*/; do
		# check if is a toolchain for current $ARCH
		[[ ! -f ${dir}bin/${compiler}gcc ]] && continue
		# get toolchain major.minor version
		local gcc_ver=$(${dir}bin/${compiler}gcc -dumpversion | grep -oE "^[[:digit:]].[[:digit:]]")
		# check if toolchain version satisfies requirement
		awk "BEGIN{exit ! ($gcc_ver $expression)}" >/dev/null || continue
		# check if found version is the closest to target
		local d=$(awk '{x = $1 - $2}{printf "%.1f\n", (x > 0) ? x : -x}' <<< "$target_ver $gcc_ver")
		if awk "BEGIN{exit ! ($d < $dist)}" >/dev/null ; then
			dist=$d
			toolchain=${dir}bin
		fi
	done
	echo "$toolchain"
}

# advanced_patch <dest> <family> <board> <target> <branch> <description>
#
# parameters:
# <dest>: u-boot, kernel
# <family>: u-boot: u-boot, u-boot-neo; kernel: sun4i-default, sunxi-next, ...
# <board>: cubieboard, cubieboard2, cubietruck, ...
# <target>: optional subdirectory
# <description>: additional description text
#
# priority:
# $SRC/userpatches/<dest>/<family>/target_<target>
# $SRC/userpatches/<dest>/<family>/board_<board>
# $SRC/userpatches/<dest>/<family>/branch_<branch>
# $SRC/userpatches/<dest>/<family>
# $SRC/patch/<dest>/<family>/target_<target>
# $SRC/patch/<dest>/<family>/board_<board>
# $SRC/patch/<dest>/<family>/branch_<branch>
# $SRC/patch/<dest>/<family>
#
advanced_patch()
{
	local dest=$1
	local family=$2
	local board=$3
	local target=$4
	local branch=$5
	local description=$6

	display_alert "Started patching process for" "$dest $description" "info"
	display_alert "Looking for user patches in" "userpatches/$dest/$family" "info"

	local names=()
	local dirs=(
		"$SRC/userpatches/$dest/$family/target_${target}:[\e[33mu\e[0m][\e[34mt\e[0m]"
		"$SRC/userpatches/$dest/$family/board_${board}:[\e[33mu\e[0m][\e[35mb\e[0m]"
		"$SRC/userpatches/$dest/$family/branch_${branch}:[\e[33mu\e[0m][\e[33mb\e[0m]"
		"$SRC/userpatches/$dest/$family:[\e[33mu\e[0m][\e[32mc\e[0m]"
		"$SRC/patch/$dest/$family/target_${target}:[\e[32ml\e[0m][\e[34mt\e[0m]"
		"$SRC/patch/$dest/$family/board_${board}:[\e[32ml\e[0m][\e[35mb\e[0m]"
		"$SRC/patch/$dest/$family/branch_${branch}:[\e[32ml\e[0m][\e[33mb\e[0m]"
		"$SRC/patch/$dest/$family:[\e[32ml\e[0m][\e[32mc\e[0m]"
		)

	# required for "for" command
	shopt -s nullglob dotglob
	# get patch file names
	for dir in "${dirs[@]}"; do
		for patch in ${dir%%:*}/*.patch; do
			names+=($(basename $patch))
		done
	done
	# remove duplicates
	local names_s=($(echo "${names[@]}" | tr ' ' '\n' | LC_ALL=C sort -u | tr '\n' ' '))
	# apply patches
	for name in "${names_s[@]}"; do
		for dir in "${dirs[@]}"; do
			if [[ -f ${dir%%:*}/$name ]]; then
				if [[ -s ${dir%%:*}/$name ]]; then
					process_patch_file "${dir%%:*}/$name" "${dir##*:}"
				else
					display_alert "... ${dir##*:} $name" "skipped"
				fi
				break # next name
			fi
		done
	done
}

# process_patch_file <file> <description>
#
# parameters:
# <file>: path to patch file
# <status>: additional status text
#
process_patch_file()
{
	local patch=$1
	local status=$2

	# detect and remove files which patch will create
	lsdiff -s --strip=1 $patch | grep '^+' | awk '{print $2}' | xargs -I % sh -c 'rm -f %'

	echo "Processing file $patch" >> $DEST/debug/patching.log
	patch --batch --silent -p1 -N < $patch >> $DEST/debug/patching.log 2>&1

	if [[ $? -ne 0 ]]; then
		display_alert "... $status $(basename $patch)" "failed" "wrn"
		[[ $EXIT_PATCHING_ERROR == yes ]] && exit_with_error "Aborting due to" "EXIT_PATCHING_ERROR"
	else
		display_alert "... $status $(basename $patch)" "succeeded" "info"
	fi
	echo >> $DEST/debug/patching.log
}

install_external_applications()
{
#--------------------------------------------------------------------------------------------------------------------------------
# Install external applications example
#--------------------------------------------------------------------------------------------------------------------------------
	display_alert "Installing extra applications and drivers" "" "info"

	for plugin in $SRC/packages/extras/*.sh; do
		source $plugin
	done
}

# write_uboot <loopdev>
#
# writes u-boot to loop device
# Parameters:
# loopdev: loop device with mounted rootfs image
write_uboot()
{
	local loop=$1
	display_alert "Writing U-boot bootloader" "$loop" "info"
	mkdir -p /tmp/u-boot/
	dpkg -x ${DEST}/debs/${CHOSEN_UBOOT}_${REVISION}_${ARCH}.deb /tmp/u-boot/
	write_uboot_platform "/tmp/u-boot/usr/lib/${CHOSEN_UBOOT}_${REVISION}_${ARCH}" "$loop"
	[[ $? -ne 0 ]] && exit_with_error "U-boot bootloader failed to install" "@host"
	rm -r /tmp/u-boot/
	sync
}

customize_image()
{
	# for users that need to prepare files at host
	[[ -f $SRC/userpatches/customize-image-host.sh ]] && source $SRC/userpatches/customize-image-host.sh
	cp $SRC/userpatches/customize-image.sh $SDCARD/tmp/customize-image.sh
	chmod +x $SDCARD/tmp/customize-image.sh
	mkdir -p $SDCARD/tmp/overlay
	# util-linux >= 2.27 required
	mount -o bind,ro $SRC/userpatches/overlay $SDCARD/tmp/overlay
	display_alert "Calling image customization script" "customize-image.sh" "info"
	chroot $SDCARD /bin/bash -c "/tmp/customize-image.sh $RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP"
	umount $SDCARD/tmp/overlay
	mountpoint -q $SDCARD/tmp/overlay || rm -r $SDCARD/tmp/overlay
}

userpatch_create()
{
	# create commit to start from clean source
	git add .
	git -c user.name='Armbian User' -c user.email='user@example.org' commit -q -m "Cleaning working copy"

	local patch="$DEST/patch/$1-$LINUXFAMILY-$BRANCH.patch"

	# apply previous user debug mode created patches
	[[ -f $patch ]] && display_alert "Applying existing $1 patch" "$patch" "wrn" && patch --batch --silent -p1 -N < $patch

	# prompt to alter source
	display_alert "Make your changes in this directory:" "$(pwd)" "wrn"
	display_alert "Press <Enter> after you are done" "waiting" "wrn"
	read </dev/tty
	tput cuu1
	git add .
	# create patch out of changes
	if ! git diff-index --quiet --cached HEAD; then
		git diff --staged > $patch
		display_alert "You will find your patch here:" "$patch" "info"
	else
		display_alert "No changes found, skipping patch creation" "" "wrn"
	fi
	git reset --soft HEAD~
	for i in {3..1..1}; do echo -n "$i." && sleep 1; done
}

# overlayfs_wrapper <operation> <workdir> <description>
#
# <operation>: wrap|cleanup
# <workdir>: path to source directory
# <description>: suffix for merged directory to help locating it in /tmp
# return value: new directory
#
# Assumptions/notes:
# - Ubuntu Xenial host
# - /tmp is mounted as tmpfs
# - there is enough space on /tmp
# - UB if running multiple compilation tasks in parallel
# - should not be used with CREATE_PATCHES=yes
#
overlayfs_wrapper()
{
	local operation="$1"
	if [[ $operation == wrap ]]; then
		local srcdir="$2"
		local description="$3"
		mkdir -p /tmp/overlay_components/ /tmp/armbian_build/
		local tempdir=$(mktemp -d --tmpdir="/tmp/overlay_components/")
		local workdir=$(mktemp -d --tmpdir="/tmp/overlay_components/")
		local mergeddir=$(mktemp -d --suffix="_$description" --tmpdir="/tmp/armbian_build/")
		mount -t overlay overlay -o lowerdir="$srcdir",upperdir="$tempdir",workdir="$workdir" "$mergeddir"
		# this is executed in a subshell, so use temp files to pass extra data outside
		echo "$tempdir" >> /tmp/.overlayfs_wrapper_cleanup
		echo "$mergeddir" >> /tmp/.overlayfs_wrapper_umount
		echo "$mergeddir" >> /tmp/.overlayfs_wrapper_cleanup
		echo "$mergeddir"
		return
	fi
	if [[ $operation == cleanup ]]; then
		if [[ -f /tmp/.overlayfs_wrapper_umount ]]; then
			for dir in $(</tmp/.overlayfs_wrapper_umount); do
				[[ $dir == /tmp/* ]] && umount -l "$dir" > /dev/null 2>&1
			done
		fi
		if [[ -f /tmp/.overlayfs_wrapper_cleanup ]]; then
			for dir in $(</tmp/.overlayfs_wrapper_cleanup); do
				[[ $dir == /tmp/* ]] && rm -rf "$dir"
			done
		fi
		rm -f /tmp/.overlayfs_wrapper_umount /tmp/.overlayfs_wrapper_cleanup
	fi
}
