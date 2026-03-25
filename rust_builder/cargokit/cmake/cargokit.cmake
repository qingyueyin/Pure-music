SET(cargokit_cmake_root "${CMAKE_CURRENT_LIST_DIR}/..")

option(CARGOKIT_ALWAYS_RUN "Force running cargokit build tool every build" OFF)

# Workaround for https://github.com/dart-lang/pub/issues/4010
get_filename_component(cargokit_cmake_root "${cargokit_cmake_root}" REALPATH)

if(WIN32)
    # REALPATH does not properly resolve symlinks on windows :-/
    execute_process(COMMAND powershell -ExecutionPolicy Bypass -File "${CMAKE_CURRENT_LIST_DIR}/resolve_symlinks.ps1" "${cargokit_cmake_root}" OUTPUT_VARIABLE cargokit_cmake_root OUTPUT_STRIP_TRAILING_WHITESPACE)
endif()

# Arguments
# - target: CMAKE target to which rust library is linked
# - manifest_dir: relative path from current folder to directory containing cargo manifest
# - lib_name: cargo package name
# - any_symbol_name: name of any exported symbol from the library.
#                    used on windows to force linking with library.
function(apply_cargokit target manifest_dir lib_name any_symbol_name)

    set(CARGOKIT_LIB_NAME "${lib_name}")
    set(CARGOKIT_LIB_FULL_NAME "${CMAKE_SHARED_MODULE_PREFIX}${CARGOKIT_LIB_NAME}${CMAKE_SHARED_MODULE_SUFFIX}")
    if (CMAKE_CONFIGURATION_TYPES)
        set(CARGOKIT_OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/$<CONFIG>")
        set(OUTPUT_LIB "${CMAKE_CURRENT_BINARY_DIR}/$<CONFIG>/${CARGOKIT_LIB_FULL_NAME}")
    else()
        set(CARGOKIT_OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}")
        set(OUTPUT_LIB "${CMAKE_CURRENT_BINARY_DIR}/${CARGOKIT_LIB_FULL_NAME}")
    endif()
    set(CARGOKIT_TEMP_DIR "${CMAKE_CURRENT_BINARY_DIR}/cargokit_build")

    if (FLUTTER_TARGET_PLATFORM)
        set(CARGOKIT_TARGET_PLATFORM "${FLUTTER_TARGET_PLATFORM}")
    else()
        set(CARGOKIT_TARGET_PLATFORM "windows-x64")
    endif()

    set(CARGOKIT_ENV
        "CARGOKIT_CMAKE=${CMAKE_COMMAND}"
        "CARGOKIT_CONFIGURATION=$<CONFIG>"
        "CARGOKIT_MANIFEST_DIR=${CMAKE_CURRENT_SOURCE_DIR}/${manifest_dir}"
        "CARGOKIT_TARGET_TEMP_DIR=${CARGOKIT_TEMP_DIR}"
        "CARGOKIT_OUTPUT_DIR=${CARGOKIT_OUTPUT_DIR}"
        "CARGOKIT_TARGET_PLATFORM=${CARGOKIT_TARGET_PLATFORM}"
        "CARGOKIT_TOOL_TEMP_DIR=${CARGOKIT_TEMP_DIR}/tool"
        "CARGOKIT_ROOT_PROJECT_DIR=${CMAKE_SOURCE_DIR}"
    )

    # Best-effort incremental build inputs.
    # This is intentionally conservative; the old behavior can be restored by
    # configuring CARGOKIT_ALWAYS_RUN=ON.
    set(CARGOKIT_MANIFEST_DIR_ABS "${CMAKE_CURRENT_SOURCE_DIR}/${manifest_dir}")
    file(GLOB_RECURSE CARGOKIT_RUST_SOURCES CONFIGURE_DEPENDS
        "${CARGOKIT_MANIFEST_DIR_ABS}/*.rs"
    )
    file(GLOB_RECURSE CARGOKIT_CARGO_TOMLS CONFIGURE_DEPENDS
        "${CARGOKIT_MANIFEST_DIR_ABS}/Cargo.toml"
    )
    file(GLOB_RECURSE CARGOKIT_BUILD_RS CONFIGURE_DEPENDS
        "${CARGOKIT_MANIFEST_DIR_ABS}/build.rs"
    )
    set(CARGOKIT_INPUTS
        ${CARGOKIT_RUST_SOURCES}
        ${CARGOKIT_CARGO_TOMLS}
        ${CARGOKIT_BUILD_RS}
    )
    if(EXISTS "${CARGOKIT_MANIFEST_DIR_ABS}/Cargo.lock")
        list(APPEND CARGOKIT_INPUTS "${CARGOKIT_MANIFEST_DIR_ABS}/Cargo.lock")
    endif()

    if (WIN32)
        set(SCRIPT_EXTENSION ".cmd")
        set(IMPORT_LIB_EXTENSION ".lib")
    else()
        set(SCRIPT_EXTENSION ".sh")
        set(IMPORT_LIB_EXTENSION "")
        execute_process(COMMAND chmod +x "${cargokit_cmake_root}/run_build_tool${SCRIPT_EXTENSION}")
    endif()

    # Using generators in custom command is only supported in CMake 3.20+
    if (CMAKE_CONFIGURATION_TYPES AND ${CMAKE_VERSION} VERSION_LESS "3.20.0")
        foreach(CONFIG IN LISTS CMAKE_CONFIGURATION_TYPES)
            if(CARGOKIT_ALWAYS_RUN)
                add_custom_command(
                    OUTPUT
                    "${CMAKE_CURRENT_BINARY_DIR}/${CONFIG}/${CARGOKIT_LIB_FULL_NAME}"
                    "${CMAKE_CURRENT_BINARY_DIR}/_phony_"
                    COMMAND ${CMAKE_COMMAND} -E env ${CARGOKIT_ENV}
                    "${cargokit_cmake_root}/run_build_tool${SCRIPT_EXTENSION}" build-cmake
                    DEPENDS ${CARGOKIT_INPUTS}
                    VERBATIM
                )
            else()
                add_custom_command(
                    OUTPUT
                    "${CMAKE_CURRENT_BINARY_DIR}/${CONFIG}/${CARGOKIT_LIB_FULL_NAME}"
                    COMMAND ${CMAKE_COMMAND} -E env ${CARGOKIT_ENV}
                    "${cargokit_cmake_root}/run_build_tool${SCRIPT_EXTENSION}" build-cmake
                    DEPENDS ${CARGOKIT_INPUTS}
                    VERBATIM
                )
            endif()
        endforeach()
    else()
        if(CARGOKIT_ALWAYS_RUN)
            add_custom_command(
                OUTPUT
                ${OUTPUT_LIB}
                "${CMAKE_CURRENT_BINARY_DIR}/_phony_"
                COMMAND ${CMAKE_COMMAND} -E env ${CARGOKIT_ENV}
                "${cargokit_cmake_root}/run_build_tool${SCRIPT_EXTENSION}" build-cmake
                DEPENDS ${CARGOKIT_INPUTS}
                VERBATIM
            )
        else()
            add_custom_command(
                OUTPUT
                ${OUTPUT_LIB}
                COMMAND ${CMAKE_COMMAND} -E env ${CARGOKIT_ENV}
                "${cargokit_cmake_root}/run_build_tool${SCRIPT_EXTENSION}" build-cmake
                DEPENDS ${CARGOKIT_INPUTS}
                VERBATIM
            )
        endif()
    endif()

    if(CARGOKIT_ALWAYS_RUN)
        set_source_files_properties("${CMAKE_CURRENT_BINARY_DIR}/_phony_" PROPERTIES SYMBOLIC TRUE)
    endif()

    if (TARGET ${target})
        # If we have actual cmake target provided create target and make existing
        # target depend on it
        add_custom_target("${target}_cargokit" DEPENDS ${OUTPUT_LIB})
        add_dependencies("${target}" "${target}_cargokit")
        target_link_libraries("${target}" PRIVATE "${OUTPUT_LIB}${IMPORT_LIB_EXTENSION}")
        if(WIN32 AND NOT "${any_symbol_name}" STREQUAL "")
            target_link_options(${target} PRIVATE "/INCLUDE:${any_symbol_name}")
        endif()
    else()
        # Otherwise (FFI) just use ALL to force building always
        add_custom_target("${target}_cargokit" ALL DEPENDS ${OUTPUT_LIB})
    endif()

    # Allow adding the output library to plugin bundled libraries
    set("${target}_cargokit_lib" ${OUTPUT_LIB} PARENT_SCOPE)

endfunction()
