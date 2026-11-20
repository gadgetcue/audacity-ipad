get_property(_asiosdk_src GLOBAL PROPERTY asiosdk_SOURCE_DIR)
if(BD_OS STREQUAL "windows" AND _asiosdk_src)
    file(GLOB_RECURSE _asio_hdrs "${_asiosdk_src}/*.h")
    foreach(_h ${_asio_hdrs})
        if(_h MATCHES "/common/asio\\.h$")
            get_filename_component(_asio_common "${_h}" DIRECTORY)
            get_filename_component(_asiosdk_root "${_asio_common}" DIRECTORY)
            break()
        endif()
    endforeach()
    if(NOT _asiosdk_root)
        message(FATAL_ERROR "[${BD_NAME}] asiosdk source at ${_asiosdk_src} has no common/asio.h")
    endif()
    message(STATUS "[${BD_NAME}] ASIO enabled, SDK root: ${_asiosdk_root}")
    list(APPEND DEP_CMAKE_ARGS -DPA_USE_ASIO=ON "-DASIOSDK_ROOT_DIR=${_asiosdk_root}")
endif()

# iOS / iPadOS: swap the macOS CoreAudio (HAL) host API for a RemoteIO one
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    file(MAKE_DIRECTORY "${SRC}/src/hostapi/ios")
    file(COPY "${BD_RECIPE_DIR}/ios/pa_ios_audio.m" DESTINATION "${SRC}/src/hostapi/ios")
    file(READ "${SRC}/CMakeLists.txt" _pa_cml)
    string(REPLACE
        "src/hostapi/coreaudio/pa_mac_core.c
        src/hostapi/coreaudio/pa_mac_core_blocking.c
        src/hostapi/coreaudio/pa_mac_core_utilities.c)"
        "src/hostapi/ios/pa_ios_audio.m)"
        _pa_cml "${_pa_cml}")
    string(REPLACE "FIND_LIBRARY(CORESERVICES_LIBRARY CoreServices REQUIRED)" "enable_language(OBJC)
      FIND_LIBRARY(CORESERVICES_LIBRARY AVFoundation REQUIRED)" _pa_cml "${_pa_cml}")
    string(REPLACE "FIND_LIBRARY(AUDIOUNIT_LIBRARY AudioUnit REQUIRED)" "SET(AUDIOUNIT_LIBRARY \"\")" _pa_cml "${_pa_cml}")
    if(NOT _pa_cml MATCHES "pa_ios_audio.m")
        message(FATAL_ERROR "[portaudio] iOS host API patch did not apply")
    endif()
    file(WRITE "${SRC}/CMakeLists.txt" "${_pa_cml}")
    list(APPEND DEP_CMAKE_ARGS -DCMAKE_OBJC_FLAGS=-fobjc-arc)
endif()

_bd_cmake_build("${SRC}")
