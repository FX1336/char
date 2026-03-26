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
if(DEFINED ENV{CMAKE_C_COMPILER})
    set(CMAKE_C_COMPILER "$ENV{CMAKE_C_COMPILER}" CACHE FILEPATH "" FORCE)
endif()
if(DEFINED ENV{CMAKE_CXX_COMPILER})
    set(CMAKE_CXX_COMPILER "$ENV{CMAKE_CXX_COMPILER}" CACHE FILEPATH "" FORCE)
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
