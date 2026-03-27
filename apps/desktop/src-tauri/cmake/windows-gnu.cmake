# windows-gnu.cmake — cmake toolchain shim for x86_64-pc-windows-gnu local dev
# Loaded via CMAKE_TOOLCHAIN_FILE env var set by scripts/dev-windows.ps1.
# cmake-rs (cmake crate used by Rust build scripts) reads CMAKE_TOOLCHAIN_FILE from
# the environment and passes it as -DCMAKE_TOOLCHAIN_FILE to every cmake invocation.
#
# This file runs after command-line -D cache entries are set, so it can FORCE-override
# them.  Three problems fixed here:
#
#   1. CMAKE_C/CXX_COMPILER: cmake-rs intentionally skips setting these on non-MSVC
#      Windows (cmake-rs lib.rs line ~782).  Without this file cmake auto-detects
#      gcc.exe from PATH instead of the exact MinGW cross-compiler we want.
#
#   2. /utf-8 in cmake flags: whisper-rs-sys build.rs unconditionally calls
#      config.cxxflag("/utf-8") on all Windows builds.  GCC treats /utf-8 as a
#      filename and errors.  Strip it here; UTF-8 source encoding is gcc's default.
#
#   3. --target=... in cmake flags: whisper-rs-sys build.rs injects
#      --target=x86_64-pc-windows-gnu unconditionally on Windows GNU targets.
#      This is a clang-only flag; MinGW GCC rejects it with "unrecognized argument".
#      Strip it here.

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

# ── Flatten static-library output into OUT_DIR/build ─────────────────────────
# cmake-rs sets CMAKE_INSTALL_PREFIX = OUT_DIR and creates the build tree at
# OUT_DIR/build/.  Different Rust build scripts use different search paths:
#
#   whisper-rs-sys: searches OUT_DIR/build/ recursively via add_link_search_path()
#                   AND searches OUT_DIR directly.
#   libsql-ffi:     searches OUT_DIR/build/, OUT_DIR/build/Release/, OUT_DIR/build/Debug/
#
# Default cmake behaviour places .a files deep in the build tree
# (e.g. OUT_DIR/build/ggml/src/libggml.a) which both build scripts can
# handle, but backslash paths deep in the tree can confuse GNU ld on Windows.
# Flattening to OUT_DIR/build/ satisfies all search paths and avoids deep paths.
if(DEFINED CMAKE_INSTALL_PREFIX)
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_INSTALL_PREFIX}/build"
        CACHE PATH "" FORCE)
endif()

# ── Strip GCC-incompatible flags injected by whisper-rs-sys build.rs ──────────
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
        string(REGEX REPLACE "--target=[^ ]+" "" _val "${_val}")
        set(${_flag_var} "${_val}" CACHE STRING "" FORCE)
    endif()
    # Also strip from any normal variable with the same name
    if(DEFINED ${_flag_var})
        string(REPLACE "/utf-8" "" ${_flag_var} "${${_flag_var}}")
        string(REGEX REPLACE "--target=[^ ]+" "" ${_flag_var} "${${_flag_var}}")
    endif()
endforeach()
