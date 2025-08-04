#!/bin/bash

# Build step definitions.
# Meant to be sourced.

dump_config() {
    group "build config dump"
    echo_kv BUILD_RID "$BUILD_RID"
    echo_kv BUILD_CFG "$BUILD_CFG"
    echo_kv TARGET_ARCH "$TARGET_ARCH"
    echo
    echo_kv CCACHE_DIR "$CCACHE_DIR"
    echo_kv OUT_DIR "$OUT_DIR"
    echo
    echo_kv TARGET_GLIBC_RID "$TARGET_GLIBC_RID"
    echo_kv ROOTFS_GLIBC_DIR "$ROOTFS_GLIBC_DIR"
    echo_kv ROOTFS_GLIBC_IMAGE_TAG "$ROOTFS_GLIBC_IMAGE_TAG"
    echo
    echo_kv TARGET_MUSL_RID "$TARGET_MUSL_RID"
    echo_kv ROOTFS_MUSL_DIR "$ROOTFS_MUSL_DIR"
    echo_kv ROOTFS_MUSL_IMAGE_TAG "$ROOTFS_MUSL_IMAGE_TAG"
    endgroup

    group "source versions"
    echo "$(_term bold yellow)dotnet/dotnet:$(_term reset)"
    echo_kv "  repo" "$DOTNET_VMR_REPO"
    echo_kv "  branch" "$DOTNET_VMR_BRANCH"
    echo_kv "  checkout" "$DOTNET_VMR_CHECKOUT"
    echo

    if [[ -n "$CI" ]]; then
        group "environment variables"
        env
        endgroup
    fi
}

maybe_dump_ccache_stats() {
    if [[ -z $CCACHE_DIR ]]; then
        return 0
    fi

    group "ccache stats"
    ccache -s
    endgroup
}

provision_loong_rootfs() {
    local tag="$1"
    local destdir="$2"
    local sudo="$3"
    local platform=linux/loong64
    local container_id

    group "provisioning $platform cross rootfs into $destdir"

    if [[ -e "$destdir/.provisioned" ]]; then
        # TODO: check against the build info
        echo "found existing rootfs, skipping provision"
        endgroup
        return
    fi

    echo docker pull --platform="$platform" "$tag"
    docker pull --platform="$platform" "$tag"
    container_id="$(docker create --platform="$platform" "$tag" /bin/true)"
    echo "temp container ID is $(_term green)${container_id}$(_term reset)"

    mkdir -p "$destdir" || true
    pushd "$destdir" > /dev/null || return
    docker export "$container_id" | $sudo tar -xf -
    touch .provisioned
    popd > /dev/null || return

    docker rm "$container_id"
    docker rmi "$tag"

    endgroup
}

_do_checkout() {
    local repo="$1"
    local branch="$2"
    local dest="$3"
    local skip="${4:=false}"

    if "$skip"; then
        echo "skipping checkout into $dest, assuming correct contents"
        return
    fi

    local git_clone_args=(
        --depth 1
        --recurse-submodules
        --shallow-submodules
        -b "$branch"
        "$repo"
        "$dest"
    )
    git clone "${git_clone_args[@]}"
}

prepare_tools() {
    apt install cpio
}

prepare_sources() {
    group "preparing sources"
    _do_checkout "$DOTNET_VMR_REPO" "$DOTNET_VMR_BRANCH" "$DOTNET_VMR_CHECKOUT" "$DOTNET_VMR_CHECKED_OUT"
    endgroup
}

prepare_vmr_stage1() {
    local vmr_root="$1"

    group "preparing VMR for stage1 build"
    pushd "$vmr_root" > /dev/null || return
    ./prep-source-build.sh
    popd > /dev/null || return
    endgroup
}

setup_flags() {
    local stage="$1"
    local cfg_var
    local dest_var

    group "setting up flags for stage$stage"
    for dest_var in CFLAGS CXXFLAGS LDFLAGS; do
        cfg_var="STAGE${stage}_$dest_var"
        if [[ -n ${!cfg_var} ]]; then
            export "$dest_var"="${!cfg_var}"
            echo "* exported $(_term yellow)${dest_var}=$(_term cyan)${!dest_var}$(_term reset)"
        else
            unset "$dest_var"
            echo "* unset $(_term yellow)${dest_var}$(_term reset)"
        fi
    done
    endgroup
}

_BUILT_VERSION=

build_vmr_stage1() {
    local vmr_root="$1"

    group "building stage1"
    pushd "$vmr_root" > /dev/null || return

    local args=(
        -so
        --clean-while-building
        -c "$BUILD_CFG"
        /p:PortableBuild=true
    )
    # CI=true interferes with dotnet/aspire's build
    # see https://github.com/dotnet/dotnet/blob/v9.0.0-rc.1.24431.7/src/aspire/Directory.Build.targets#L18
    CI='' ./build.sh "${args[@]}"

    _detect_built_version artifacts/assets/Release
    mv artifacts/assets/Release/Private.SourceBuilt.Artifacts.*.tar.gz "$OUT_DIR"/
    mv artifacts/assets/Release/Sdk/*/dotnet-sdk-*.tar.gz "$OUT_DIR"/

    ls -lh "$OUT_DIR"

    popd > /dev/null || return
    endgroup
}

_detect_built_version() {
    local dir="$1"

    # record the version of produced artifacts so we don't have to pull it out
    # manually with shell
    _BUILT_VERSION="$(cd "$dir" && echo Private.SourceBuilt.Artifacts.*."$BUILD_RID".tar.*)"
    _BUILT_VERSION="${_BUILT_VERSION#Private.SourceBuilt.Artifacts.}"
    _BUILT_VERSION="${_BUILT_VERSION%."$BUILD_RID".tar.*}"

    _SDK_VERSION="$(cd "$dir" && echo dotnet-sdk-*-"$BUILD_RID".tar.*)"
    _SDK_VERSION="${_SDK_VERSION#dotnet-sdk-}"
    _SDK_VERSION="${_SDK_VERSION%-"$BUILD_RID".tar.*}"

    echo "artifact version detected as $_BUILT_VERSION"
    echo "SDK version detected as $_SDK_VERSION"
}

unpack_sb_artifacts() {
    group "unpacking source build artifacts from stage1"

    [[ -z $_BUILT_VERSION ]] && _detect_built_version "$OUT_DIR"
    if [[ -z $_BUILT_VERSION ]]; then
        echo "fatal: artifact version not detected" >&2
        exit 1
    fi

    _SB_ARTIFACTS_DIR="$(mktemp --tmpdir -d stage1.XXXXXXXX)"
    pushd "$_SB_ARTIFACTS_DIR" > /dev/null || return
    mkdir pkg sdk

    pushd pkg > /dev/null || return
    tar xf "$OUT_DIR"/Private.SourceBuilt.Artifacts."$_BUILT_VERSION"."$BUILD_RID".tar.*
    popd > /dev/null || return

    pushd sdk > /dev/null || return
    tar xf "$OUT_DIR"/dotnet-sdk-"$_SDK_VERSION"-"$BUILD_RID".tar.*
    popd > /dev/null || return

    popd > /dev/null || return
    endgroup
}

prepare_vmr_stage2() {
    local vmr_root="$1"

    group "preparing VMR for stage2 build"
    pushd "$vmr_root" > /dev/null || return

    git checkout -- .
    git clean -dfx

    local args=(
        --no-bootstrap
        --no-sdk
        --no-artifacts
        --with-sdk "$_SB_ARTIFACTS_DIR"/sdk
        --with-packages "$_SB_ARTIFACTS_DIR"/pkg
    )
    ./prep-source-build.sh "${args[@]}"

    popd > /dev/null || return
    endgroup
}

build_vmr_stage2() {
    local vmr_root="$1"
    local target_rid="$2"

    group "building $target_rid stage2"
    pushd "$vmr_root" > /dev/null || return

    local args=(
        -so
        --clean-while-building
        -c "$BUILD_CFG"
        --with-sdk "$_SB_ARTIFACTS_DIR"/sdk
        --with-packages "$_SB_ARTIFACTS_DIR"/pkg
        --target-rid "$target_rid"
        /p:PortableBuild=true
        /p:HostRid="$target_rid"
        /p:PortableRid="$target_rid"
        /p:TargetArchitecture="$TARGET_ARCH"
    )
    # CI=true interferes with dotnet/aspire's build
    # see https://github.com/dotnet/dotnet/blob/v9.0.0-rc.1.24431.7/src/aspire/Directory.Build.targets#L18
    CI='' ./build.sh "${args[@]}"

    mv artifacts/assets/Release/Private.SourceBuilt.Artifacts.*.tar.gz "$OUT_DIR"/
    mv artifacts/assets/Release/Sdk/dotnet-sdk-*.tar.gz "$OUT_DIR"/

    ls -lh "$OUT_DIR"

    popd > /dev/null || return
    endgroup
}
