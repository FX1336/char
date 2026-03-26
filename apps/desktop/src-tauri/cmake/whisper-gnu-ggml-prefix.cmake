# whisper-gnu-ggml-prefix.cmake
#
# Loaded via the CMAKE_PROJECT_INCLUDE_BEFORE env var (whisper-rs-sys build.rs
# forwards all CMAKE_* env vars as -D flags, so setting the env var is enough).
#
# Problem
# -------
# ggml/CMakeLists.txt ~line 37 contains:
#
#     if (WIN32)
#         set(CMAKE_STATIC_LIBRARY_PREFIX "")   # remove the lib prefix on win32 mingw
#     endif()
#
# That normal-variable set() overrides any CACHE setting, so cmake generates
# ggml.a / ggml-base.a / ggml-cpu.a (no "lib" prefix).
# GNU ld (MinGW-w64) resolves -lggml by looking for libggml.a -> not found.
# Result: "could not find native static library `ggml`" linker error.
#
# Fix
# ---
# Defer a call to the end of the top-level cmake configure so that all targets
# are already defined.  Then set the PREFIX target property to "lib" on every
# affected target, overriding what ggml's CMakeLists.txt set on CMAKE_STATIC_LIBRARY_PREFIX.
# cmake will generate libggml.a / libggml-base.a / libggml-cpu.a in
# CMAKE_ARCHIVE_OUTPUT_DIRECTORY (= OUT_DIR, set by windows-gnu.cmake).
# cargo:rustc-link-search=native=OUT_DIR then covers all four libraries.
#
# Requires CMake >= 3.19 (cmake_language DEFER).

if(CMAKE_VERSION VERSION_LESS "3.19")
    message(FATAL_ERROR
        "whisper-gnu-ggml-prefix.cmake requires CMake 3.19+.\n"
        "Please upgrade: winget upgrade Kitware.CMake")
endif()

# CMAKE_PROJECT_INCLUDE_BEFORE fires before EVERY project() call in the build
# tree (top-level + subdirectories).  Guard so we register the deferred fix
# only once (for the top-level whisper.cpp project).
if(NOT DEFINED _HYPR_GGML_PREFIX_FIX_REGISTERED)
    set(_HYPR_GGML_PREFIX_FIX_REGISTERED TRUE)

    function(_hypr_fix_ggml_lib_prefix)
        foreach(_tgt ggml ggml-base ggml-cpu)
            if(TARGET ${_tgt})
                get_target_property(_type ${_tgt} TYPE)
                if(_type STREQUAL "STATIC_LIBRARY")
                    set_target_properties(${_tgt} PROPERTIES PREFIX "lib")
                    message(STATUS "whisper-gnu-fix: ${_tgt} -> lib${_tgt}.a")
                endif()
            endif()
        endforeach()
    endfunction()

    # Defer to the end of this directory's CMakeLists.txt scope.
    # By then add_subdirectory(ggml) and add_subdirectory(src) have both
    # completed, so all ggml/whisper targets exist.
    cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        CALL _hypr_fix_ggml_lib_prefix)
endif()
