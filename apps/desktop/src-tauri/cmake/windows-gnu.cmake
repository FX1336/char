# windows-gnu.cmake — cmake toolchain shim for x86_64-pc-windows-gnu local dev
# Loaded via CMAKE_TOOLCHAIN_FILE env var set by scripts/dev-windows.ps1.
# cmake-rs (cmake crate used by Rust build scripts) reads CMAKE_TOOLCHAIN_FILE from
# the environment and passes it as -DCMAKE_TOOLCHAIN_FILE to every cmake invocation.
#
# This file runs after command-line -D cache entries are set, so it can FORCE-override
# them.  Two problems fixed here:
#
#   1. CMAKE_C/CXX_COMPILER: cmake-rs intentionally skips setting these on non-MSVC
#      Windows (cmake-rs lib.rs line ~782).  Without this file cmake auto-detects
#      gcc.exe from PATH, which rejects clang-specific flags like --target=...
#
#   2. /utf-8 in CMAKE_CXX_FLAGS: whisper-rs-sys build.rs unconditionally calls
#      config.cxxflag("/utf-8") on all Windows builds.  Clang in GNU driver mode
#      treats /utf-8 as a filename and errors.  Strip it here; UTF-8 source encoding
#      is clang's default anyway.

# ── Compilers (paths come from CC/CXX env vars set by dev-windows.ps1) ───────
# file(TO_CMAKE_PATH ...) converts Windows backslash paths to forward slashes so
# cmake does not misparse the compiler path in generated Makefiles.
if(DEFINED ENV{CMAKE_C_COMPILER})
    file(TO_CMAKE_PATH "$ENV{CMAKE_C_COMPILER}" _tc_c)
    set(CMAKE_C_COMPILER "${_tc_c}" CACHE FILEPATH "" FORCE)
endif()
if(DEFINED ENV{CMAKE_CXX_COMPILER})
    file(TO_CMAKE_PATH "$ENV{CMAKE_CXX_COMPILER}" _tc_cxx)
    set(CMAKE_CXX_COMPILER "${_tc_cxx}" CACHE FILEPATH "" FORCE)
endif()

# ── Flatten static-library output into CMAKE_INSTALL_PREFIX (= OUT_DIR) ───────
# cmake-rs (the cmake crate) sets CMAKE_INSTALL_PREFIX to the build script's
# OUT_DIR and then searches OUT_DIR itself with
#   cargo:rustc-link-search=native=OUT_DIR
# By default, cmake places static libraries deep inside subdirectories of the
# build tree (e.g. OUT_DIR/build/ggml/src/libggml.a).  The whisper-rs-sys
# build.rs does recurse those subdirs with add_link_search_path(), but on
# Windows the resulting backslash paths can be mis-handled by the GNU linker.
# Setting CMAKE_ARCHIVE_OUTPUT_DIRECTORY to OUT_DIR puts every .a file
# directly in the directory that cargo always passes as -L to the linker,
# so libggml.a / libggml-base.a / libggml-cpu.a / libwhisper.a are always
# found regardless of build-tree depth.
if(DEFINED CMAKE_INSTALL_PREFIX)
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_INSTALL_PREFIX}"
        CACHE PATH "" FORCE)
endif()

# ── Strip /utf-8 from all flag variables ──────────────────────────────────────
foreach(_flag_var
    CMAKE_C_FLAGS CMAKE_CXX_FLAGS CMAKE_ASM_FLAGS
    CMAKE_C_FLAGS_DEBUG CMAKE_CXX_FLAGS_DEBUG
    CMAKE_C_FLAGS_RELEASE CMAKE_CXX_FLAGS_RELEASE
    CMAKE_C_FLAGS_RELWITHDEBINFO CMAKE_CXX_FLAGS_RELWITHDEBINFO
    CMAKE_C_FLAGS_MINSIZEREL CMAKE_CXX_FLAGS_MINSIZEREL)
    # Read from cache (set by cmake-rs -D args which arrive before this file runs)
    get_property(_val CACHE ${_flag_var} PROPERTY VALUE)
    if(_val)
        string(REPLACE "/utf-8" "" _val "${_val}")
        set(${_flag_var} "${_val}" CACHE STRING "" FORCE)
    endif()
    # Also strip from any normal variable with the same name
    if(DEFINED ${_flag_var})
        string(REPLACE "/utf-8" "" ${_flag_var} "${${_flag_var}}")
    endif()
endforeach()

# ── Switch clang++ to libstdc++ (avoid std::__1:: ABI mismatch) ───────────────
# llvm-mingw's clang++ defaults to LLVM libc++ which places all C++ symbols in
# the std::__1:: inline namespace.  MinGW's gcc.exe (used as Rust's linker)
# links libstdc++ by default, which uses plain std:: — so every std::__1::*
# reference from whisper.cpp/ggml/knf-rs objects is left unresolved at link time.
# Passing -stdlib=libstdc++ makes clang compile against GCC's C++ headers
# (plain std:: namespace) instead.  --gcc-toolchain points clang at the winlibs
# MinGW-w64 installation where the libstdc++ headers live.
# MINGW_DIR env var is exported by dev-windows.ps1.
if(DEFINED ENV{MINGW_DIR})
    file(TO_CMAKE_PATH "$ENV{MINGW_DIR}" _mingw_gcc_tc)
    set(_stdlib_flags "-stdlib=libstdc++ --gcc-toolchain=${_mingw_gcc_tc}")
    foreach(_fv
        CMAKE_CXX_FLAGS
        CMAKE_CXX_FLAGS_DEBUG CMAKE_CXX_FLAGS_RELEASE
        CMAKE_CXX_FLAGS_RELWITHDEBINFO CMAKE_CXX_FLAGS_MINSIZEREL)
        get_property(_cached CACHE ${_fv} PROPERTY VALUE)
        if(NOT _cached MATCHES "-stdlib=")
            set(${_fv} "${_cached} ${_stdlib_flags}" CACHE STRING "" FORCE)
        endif()
        if(DEFINED ${_fv} AND NOT ${_fv} MATCHES "-stdlib=")
            string(APPEND ${_fv} " ${_stdlib_flags}")
        endif()
    endforeach()

    # cmake's CXX compiler detection test compiles AND links a small executable.
    # lld (llvm-mingw's default linker) cannot find libstdc++ because its library
    # search path doesn't include MinGW's GCC lib directory.  Switch cmake's test
    # executable links to MinGW's GNU ld (which already knows its own sysroot and
    # resolves -lstdc++ automatically).  whisper-rs-sys only builds static libraries,
    # so this flag never affects the actual whisper.cpp / ggml build — only the
    # cmake compiler detection step.
    foreach(_lfv CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS)
        get_property(_lc CACHE ${_lfv} PROPERTY VALUE)
        if(NOT _lc MATCHES "-fuse-ld=")
            set(${_lfv} "${_lc} -fuse-ld=ld" CACHE STRING "" FORCE)
        endif()
        if(DEFINED ${_lfv} AND NOT ${_lfv} MATCHES "-fuse-ld=")
            string(APPEND ${_lfv} " -fuse-ld=ld")
        endif()
    endforeach()

    unset(_stdlib_flags)
    unset(_mingw_gcc_tc)
    unset(_fv)
    unset(_lfv)
    unset(_cached)
    unset(_lc)
endif()
