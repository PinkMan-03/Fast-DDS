#!/usr/bin/env bash
# =============================================================================
# Fast DDS Learning Project - Pure CMake Build Script
# -----------------------------------------------------------------------------
# Run inside the dev container (docker compose exec dev bash).
#
# Directory layout:
#   /workspace/ws/src/         <- dependency sources (cloned via git)
#   /workspace/ws/build/       <- out-of-tree build dirs (one per package)
#   /workspace/ws/install/     <- final install prefix (libs + headers + cmake)
#   /workspace/Fast-DDS/       <- this repo (bind-mounted from host)
#
# Usage:
#   ./build.sh                # build (Release)
#   ./build.sh debug          # build (Debug)
#   ./build.sh rebuild        # clean then build
#   ./build.sh clean          # remove build/install dirs
#   ./build.sh deps           # only fetch+build foonathan & fastcdr (not Fast-DDS)
#   ./build.sh fastdds        # only build Fast-DDS (deps must already exist)
#   ./build.sh test           # run Fast-DDS tests (after build)
#   ./build.sh verify         # check install artifacts
#   ./build.sh ccache         # show ccache stats
#   ./build.sh env            # print env exports to source in your shell
#   ./build.sh help           # show help
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration (override via env vars)
# -----------------------------------------------------------------------------
WS_DIR="${WS_DIR:-/workspace/ws}"
SRC_ROOT="${SRC_ROOT:-$WS_DIR/src}"
BUILD_ROOT="${BUILD_ROOT:-$WS_DIR/build}"
INSTALL_DIR="${INSTALL_DIR:-$WS_DIR/install}"
FASTDDS_SRC="${FASTDDS_SRC:-/workspace/Fast-DDS}"

BUILD_TYPE="${BUILD_TYPE:-Release}"
NPROC="${NPROC:-$(nproc 2>/dev/null || echo 4)}"

FASTCDR_REPO="${FASTCDR_REPO:-https://github.com/eProsima/Fast-CDR.git}"
FASTCDR_BRANCH="${FASTCDR_BRANCH:-master}"
FOONATHAN_REPO="${FOONATHAN_REPO:-https://github.com/eProsima/foonathan_memory_vendor.git}"
FOONATHAN_BRANCH="${FOONATHAN_BRANCH:-master}"

# Detect best generator
if command -v ninja >/dev/null 2>&1; then
    GENERATOR="${GENERATOR:-Ninja}"
else
    GENERATOR="${GENERATOR:-Unix Makefiles}"
fi

# -----------------------------------------------------------------------------
# Colors / logging
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
    # Use $'...' so bash decodes \033 at parse time, otherwise heredoc/cat
    # cannot interpret the escape sequences and they print literally.
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'
    C_CYAN=$'\033[0;36m'
    C_BOLD=$'\033[1m'
    C_RST=$'\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_RST=''
fi

log_info()  { echo -e "${C_BLUE}[INFO]${C_RST}  $*"; }
log_ok()    { echo -e "${C_GREEN}[ OK ]${C_RST}  $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RST}  $*"; }
log_err()   { echo -e "${C_RED}[FAIL]${C_RST}  $*" >&2; }
log_step()  { echo -e "\n${C_BOLD}${C_CYAN}===== $* =====${C_RST}"; }

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
check_env() {
    log_step "Environment check"

    if [ ! -f /.dockerenv ] && ! grep -qE 'docker|kubepods' /proc/1/cgroup 2>/dev/null; then
        log_warn "You don't appear to be inside the dev container."
        log_warn "Recommended: docker compose exec dev bash, then run this script."
        log_warn "Continuing in 3s..."
        sleep 3
    else
        log_ok "Running inside container ($(hostname))"
    fi

    if [ ! -f "$FASTDDS_SRC/CMakeLists.txt" ]; then
        log_err "Cannot find Fast-DDS sources at $FASTDDS_SRC"
        exit 1
    fi

    for tool in cmake git gcc g++ ccache; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_err "Required tool '$tool' is not installed."
            exit 1
        fi
    done

    log_ok "gcc        : $(gcc --version | head -1)"
    log_ok "cmake      : $(cmake --version | head -1)"
    log_ok "generator  : $GENERATOR"
    log_ok "BUILD_TYPE : $BUILD_TYPE"
    log_ok "PARALLEL   : $NPROC jobs"
    log_ok "INSTALL    : $INSTALL_DIR"
}

# -----------------------------------------------------------------------------
# Helper: configure + build + install a single CMake project
# Args: <project_name> <source_dir> <extra_cmake_args>
# -----------------------------------------------------------------------------
cmake_build_install() {
    local name="$1"
    local src="$2"
    shift 2
    local extra=( "$@" )

    local build_dir="$BUILD_ROOT/$name"

    log_step "Build $name"

    mkdir -p "$build_dir"

    local start_ts
    start_ts=$(date +%s)

    cmake -S "$src" -B "$build_dir" \
        -G "$GENERATOR" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        "${extra[@]}"

    cmake --build "$build_dir" --target install -j "$NPROC"

    local elapsed=$(( $(date +%s) - start_ts ))
    log_ok "$name finished in $((elapsed / 60))m $((elapsed % 60))s"
}

# -----------------------------------------------------------------------------
# Step: clone deps from git (idempotent)
# -----------------------------------------------------------------------------
fetch_deps() {
    log_step "Fetch dependency sources"

    mkdir -p "$SRC_ROOT"
    cd "$SRC_ROOT"

    if [ ! -d "foonathan_memory_vendor/.git" ]; then
        log_info "Cloning foonathan_memory_vendor ($FOONATHAN_BRANCH)..."
        git clone --depth 1 --branch "$FOONATHAN_BRANCH" "$FOONATHAN_REPO" foonathan_memory_vendor
    else
        log_ok "foonathan_memory_vendor already cloned"
    fi

    if [ ! -d "Fast-CDR/.git" ]; then
        log_info "Cloning Fast-CDR ($FASTCDR_BRANCH)..."
        git clone --depth 1 --branch "$FASTCDR_BRANCH" "$FASTCDR_REPO" Fast-CDR
    else
        log_ok "Fast-CDR already cloned"
    fi
}

# -----------------------------------------------------------------------------
# Step: build foonathan_memory_vendor
# -----------------------------------------------------------------------------
build_foonathan() {
    cmake_build_install \
        "foonathan_memory_vendor" \
        "$SRC_ROOT/foonathan_memory_vendor"
}

# -----------------------------------------------------------------------------
# Step: build Fast-CDR
# -----------------------------------------------------------------------------
build_fastcdr() {
    cmake_build_install \
        "Fast-CDR" \
        "$SRC_ROOT/Fast-CDR"
}

# -----------------------------------------------------------------------------
# Step: build Fast-DDS (main)
# -----------------------------------------------------------------------------
build_fastdds() {
    cmake_build_install \
        "Fast-DDS" \
        "$FASTDDS_SRC" \
        -DCOMPILE_EXAMPLES=OFF \
        -DCOMPILE_TOOLS=ON \
        -DSECURITY=ON
}

# -----------------------------------------------------------------------------
# Write a convenience setup.bash inside the install prefix so users can do:
#   source /workspace/ws/install/setup.bash
# instead of `eval "$(./build.sh env)"`.
# -----------------------------------------------------------------------------
write_setup_script() {
    local f="$INSTALL_DIR/setup.bash"
    if [ ! -d "$INSTALL_DIR" ]; then
        log_warn "Install dir $INSTALL_DIR not found, skip setup.bash"
        return
    fi
    cat > "$f" <<EOF
# Auto-generated by build.sh - source this file to enable Fast DDS in shell.
#   source $f
export CMAKE_PREFIX_PATH="$INSTALL_DIR:\${CMAKE_PREFIX_PATH:-}"
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:\${LD_LIBRARY_PATH:-}"
export PATH="$INSTALL_DIR/bin:\${PATH:-}"
echo "[fastdds] environment activated (prefix: $INSTALL_DIR)"
EOF
    log_ok "Wrote $f"
}

# -----------------------------------------------------------------------------
# Full build pipeline
# -----------------------------------------------------------------------------
do_build_all() {
    check_env
    fetch_deps
    build_foonathan
    build_fastcdr
    build_fastdds
    write_setup_script
    verify_artifacts
    print_env_hint
}

# -----------------------------------------------------------------------------
# Clean
# -----------------------------------------------------------------------------
do_clean() {
    log_step "Clean build/install directories"
    if [ -d "$BUILD_ROOT" ]; then
        log_info "Removing $BUILD_ROOT"
        rm -rf "$BUILD_ROOT"
    fi
    if [ -d "$INSTALL_DIR" ]; then
        log_info "Removing $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
    log_ok "Cleaned (sources in $SRC_ROOT kept)"
}

# -----------------------------------------------------------------------------
# Tests (Fast-DDS only)
# -----------------------------------------------------------------------------
do_test() {
    log_step "Run Fast-DDS tests"
    local build_dir="$BUILD_ROOT/Fast-DDS"
    if [ ! -d "$build_dir" ]; then
        log_err "Build dir $build_dir not found. Run './build.sh' first."
        exit 1
    fi
    cd "$build_dir"
    ctest --output-on-failure -j "$NPROC"
}

# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------
verify_artifacts() {
    log_step "Verify install artifacts"

    if [ ! -d "$INSTALL_DIR/lib" ]; then
        log_err "Install lib dir not found: $INSTALL_DIR/lib"
        log_err "Did the build complete?"
        return 1
    fi

    log_info "Libraries in $INSTALL_DIR/lib:"
    for stem in libfastdds libfastcdr libfoonathan_memory; do
        local files
        files=$(ls "$INSTALL_DIR/lib/"${stem}* 2>/dev/null | head -3 || true)
        if [ -n "$files" ]; then
            echo "$files" | sed 's/^/      /'
        else
            log_warn "  $stem not found"
        fi
    done

    log_info "CMake config files:"
    for cfg in fastdds-config.cmake fastcdr-config.cmake foonathan_memory-config.cmake; do
        local found
        found=$(find "$INSTALL_DIR" -name "$cfg" 2>/dev/null | head -2 || true)
        if [ -n "$found" ]; then
            echo "$found" | sed 's/^/      /'
        else
            log_warn "  $cfg not found"
        fi
    done

    log_info "Headers:"
    if [ -d "$INSTALL_DIR/include/fastdds" ]; then
        log_ok "  $INSTALL_DIR/include/fastdds/ exists ($(find "$INSTALL_DIR/include/fastdds" -name '*.hpp' 2>/dev/null | wc -l) .hpp files)"
    else
        log_warn "  $INSTALL_DIR/include/fastdds/ missing"
    fi
}

print_env_hint() {
    log_step "How to use Fast DDS in this shell"
    echo ""
    echo "  ${C_BOLD}Recommended (one-liner):${C_RST}"
    echo "  ${C_CYAN}source $INSTALL_DIR/setup.bash${C_RST}"
    echo ""
    echo "  ${C_BOLD}Alternatives:${C_RST}"
    echo "  ${C_CYAN}eval \"\$(./build.sh env)\"${C_RST}"
    echo "  ${C_CYAN}export CMAKE_PREFIX_PATH=$INSTALL_DIR:\$CMAKE_PREFIX_PATH${C_RST}"
    echo "  ${C_CYAN}export LD_LIBRARY_PATH=$INSTALL_DIR/lib:\$LD_LIBRARY_PATH${C_RST}"
    echo "  ${C_CYAN}export PATH=$INSTALL_DIR/bin:\$PATH${C_RST}"
    echo ""
}

# Output shellable env exports (no decoration)
do_env() {
    echo "export CMAKE_PREFIX_PATH=$INSTALL_DIR:\$CMAKE_PREFIX_PATH"
    echo "export LD_LIBRARY_PATH=$INSTALL_DIR/lib:\$LD_LIBRARY_PATH"
    echo "export PATH=$INSTALL_DIR/bin:\$PATH"
}

# -----------------------------------------------------------------------------
# ccache stats
# -----------------------------------------------------------------------------
show_ccache() {
    log_step "ccache statistics"
    ccache -s
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
show_help() {
    cat <<EOF
${C_BOLD}Fast DDS Learning Project - Pure CMake Build Script${C_RST}

${C_BOLD}USAGE${C_RST}
    ./build.sh [command]

${C_BOLD}COMMANDS${C_RST}
    build          Full pipeline: fetch deps + build all + verify. (default)
    debug          Same as build but with BUILD_TYPE=Debug.
    rebuild        Clean then full build.
    clean          Remove build/ and install/ (keep sources).
    deps           Only fetch + build foonathan_memory + Fast-CDR.
    fastdds        Only build Fast-DDS (deps must already exist).
    test           Run Fast-DDS tests via ctest.
    verify         Check install artifacts only.
    env            Print export commands to enable Fast DDS in shell.
    ccache         Show ccache statistics.
    help | -h      Show this help.

${C_BOLD}ENVIRONMENT VARIABLES${C_RST}
    BUILD_TYPE        Release | Debug | RelWithDebInfo   (default: Release)
    NPROC             Number of parallel jobs            (default: nproc)
    GENERATOR         Ninja | "Unix Makefiles"           (default: Ninja if avail.)
    WS_DIR            Workspace root                     (default: /workspace/ws)
    INSTALL_DIR       Install prefix                     (default: \$WS_DIR/install)
    SRC_ROOT          Dependency source root             (default: \$WS_DIR/src)
    BUILD_ROOT        Out-of-tree build root             (default: \$WS_DIR/build)
    FASTDDS_SRC       Fast-DDS source dir                (default: /workspace/Fast-DDS)
    FASTCDR_BRANCH    Fast-CDR git branch/tag            (default: master)
    FOONATHAN_BRANCH  foonathan_memory_vendor branch     (default: master)

${C_BOLD}EXAMPLES${C_RST}
    ./build.sh                          # full Release build
    ./build.sh debug                    # full Debug build
    BUILD_TYPE=RelWithDebInfo ./build.sh
    NPROC=4 ./build.sh                  # limit to 4 cores
    ./build.sh rebuild                  # clean then rebuild

${C_BOLD}AFTER BUILD${C_RST}
    eval "\$(./build.sh env)"           # enable Fast DDS in current shell
    # or manually:
    export CMAKE_PREFIX_PATH=/workspace/ws/install:\$CMAKE_PREFIX_PATH
    export LD_LIBRARY_PATH=/workspace/ws/install/lib:\$LD_LIBRARY_PATH

${C_BOLD}DIRECTORY LAYOUT${C_RST}
    /workspace/ws/
    ├── src/                            <- cloned dependency sources
    │   ├── foonathan_memory_vendor/
    │   └── Fast-CDR/
    ├── build/                          <- out-of-tree build dirs
    │   ├── foonathan_memory_vendor/
    │   ├── Fast-CDR/
    │   └── Fast-DDS/
    └── install/                        <- final install prefix
        ├── include/
        ├── lib/
        └── share/<pkg>/cmake/

EOF
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------
main() {
    local cmd="${1:-build}"

    case "$cmd" in
        build)
            do_build_all
            ;;
        debug)
            BUILD_TYPE=Debug
            do_build_all
            ;;
        rebuild)
            do_clean
            do_build_all
            ;;
        clean)
            do_clean
            ;;
        deps)
            check_env
            fetch_deps
            build_foonathan
            build_fastcdr
            log_ok "Dependencies done. Run './build.sh fastdds' to build Fast-DDS."
            ;;
        fastdds)
            check_env
            build_fastdds
            verify_artifacts
            print_env_hint
            ;;
        test)
            do_test
            ;;
        verify)
            verify_artifacts
            ;;
        env)
            do_env
            ;;
        ccache)
            show_ccache
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            log_err "Unknown command: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
