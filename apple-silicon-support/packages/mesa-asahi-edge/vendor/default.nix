{ lib
, bison
, buildPackages
, directx-headers
, elfutils
, expat
, fetchCrate
, fetchurl
, file
, flex
, glslang
, intltool
, jdupes
, libdrm
, libglvnd
, libunwind
, libva-minimal
, libvdpau
, llvmPackages
, lm_sensors
, meson
, ninja
, pkg-config
, python3Packages
, rust-bindgen
, rust-cbindgen
, rustPlatform
, rustc
, spirv-tools
, spirv-llvm-translator
, stdenv
, udev
, valgrind-light
, vulkan-loader
, wayland
, wayland-protocols
, wayland-scanner
, xcbutilkeysyms
, xorg
, zstd
, withValgrind ? false
, withLibunwind ? lib.meta.availableOn stdenv.hostPlatform libunwind
, enableGalliumNine ? stdenv.isLinux
, enableOSMesa ? stdenv.isLinux
, enableOpenCL ? stdenv.isLinux && stdenv.isx86_64
, enableTeflon ? false
, enablePatentEncumberedCodecs ? false

, galliumDrivers ?
  if stdenv.isLinux
  then [
    "swrast" # software renderer (aka LLVMPipe)
    "virgl" # QEMU virtualized GPU (aka VirGL)
    "zink" # generic OpenGL over Vulkan, experimental
  ]
  else [ "auto" ]
, vulkanDrivers ?
  if stdenv.isLinux
  then [
    "swrast" # software renderer (aka Lavapipe)
    "virtio"
  ]
  else [ "auto" ]
, eglPlatforms ? [ "x11" "wayland" ]
, vulkanLayers ? [ # No Vulkan support on Darwin
  "device-select"
  "overlay"
]
}:

# When updating this package, please verify at least these build (assuming x86_64-linux):
# nix build .#mesa .#pkgsi686Linux.mesa .#pkgsCross.aarch64-multiplatform.mesa .#pkgsMusl.mesa

let
  version = "24.2.2";
  hash = "sha256-1aRnG5BnFDuBOnGIb7X3yDk4PkhpBbMpp+IjfpmgtkM=";

  # Release calendar: https://www.mesa3d.org/release-calendar.html
  # Release frequency: https://www.mesa3d.org/releasing.html#schedule
  branch = lib.versions.major version;

  withLibdrm = lib.meta.availableOn stdenv.hostPlatform libdrm;

  haveWayland = lib.elem "wayland" eglPlatforms;
  haveZink = lib.elem "zink" galliumDrivers;
  haveDozen = (lib.elem "d3d12" galliumDrivers) || (lib.elem "microsoft-experimental" vulkanDrivers);

  rustDeps = [
    {
      pname = "paste";
      version = "1.0.14";
      hash = "sha256-+J1h7New5MEclUBvwDQtTYJCHKKqAEOeQkuKy+g0vEc=";
    }
    {
      pname = "proc-macro2";
      version = "1.0.86";
      hash = "sha256-9fYAlWRGVIwPp8OKX7Id84Kjt8OoN2cANJ/D9ZOUUZE=";
    }
    {
      pname = "quote";
      version = "1.0.33";
      hash = "sha256-VWRCZJO0/DJbNu0/V9TLaqlwMot65YjInWT9VWg57DY=";
    }
    {
      pname = "syn";
      version = "2.0.68";
      hash = "sha256-nGLBbxR0DFBpsXMngXdegTm/o13FBS6QsM7TwxHXbgQ=";
    }
    {
      pname = "unicode-ident";
      version = "1.0.12";
      hash = "sha256-KX8NqYYw6+rGsoR9mdZx8eT1HIPEUUyxErdk2H/Rlj8=";
    }
  ];

  copyRustDep = dep: ''
    cp -R --no-preserve=mode,ownership ${fetchCrate dep} subprojects/${dep.pname}-${dep.version}
    cp -R subprojects/packagefiles/${dep.pname}/* subprojects/${dep.pname}-${dep.version}/
  '';

  copyRustDeps = lib.concatStringsSep "\n" (builtins.map copyRustDep rustDeps);

  needNativeCLC = !stdenv.buildPlatform.canExecute stdenv.hostPlatform;
self = stdenv.mkDerivation {
  pname = "mesa";
  inherit version;

  src = fetchurl {
    urls = [
      "https://archive.mesa3d.org/mesa-${version}.tar.xz"
      "https://mesa.freedesktop.org/archive/mesa-${version}.tar.xz"
      "ftp://ftp.freedesktop.org/pub/mesa/mesa-${version}.tar.xz"
      "ftp://ftp.freedesktop.org/pub/mesa/${version}/mesa-${version}.tar.xz"
      "ftp://ftp.freedesktop.org/pub/mesa/older-versions/${branch}.x/${version}/mesa-${version}.tar.xz"
    ];
    inherit hash;
  };

  patches = [
    ./opencl.patch
  ];

  postPatch = ''
    patchShebangs .

    # The drirc.d directory cannot be installed to $drivers as that would cause a cyclic dependency:
    substituteInPlace src/util/xmlconfig.c --replace \
      'DATADIR "/drirc.d"' '"${placeholder "out"}/share/drirc.d"'
    substituteInPlace src/util/meson.build --replace \
      "get_option('datadir')" "'${placeholder "out"}/share'"
    substituteInPlace src/amd/vulkan/meson.build --replace \
      "get_option('datadir')" "'${placeholder "out"}/share'"

    ${copyRustDeps}
  '';

  outputs = [
    "out" "dev" "drivers"
  ] ++ lib.optionals enableOSMesa [
    "osmesa"
  ] ++ lib.optionals stdenv.isLinux [
    "driversdev"
  ] ++ lib.optionals enableOpenCL [
    "opencl"
  ];

  # Keep build-ids so drivers can use them for caching, etc.
  # Also some drivers segfault without this.
  separateDebugInfo = true;

  # Needed to discover llvm-config for cross
  preConfigure = ''
    PATH=${lib.getDev llvmPackages.libllvm}/bin:$PATH
  '';

  mesonFlags = [
    "--sysconfdir=${placeholder "opencl"}/etc"
    "--datadir=${placeholder "drivers"}/share" # Vendor files

    # Don't build in debug mode
    # https://gitlab.freedesktop.org/mesa/mesa/blob/master/docs/meson.html#L327
    (lib.mesonBool "b_ndebug" true)

    (lib.mesonOption "platforms" (lib.concatStringsSep "," eglPlatforms))
    (lib.mesonOption "gallium-drivers" (lib.concatStringsSep "," galliumDrivers))
    (lib.mesonOption "vulkan-drivers" (lib.concatStringsSep "," vulkanDrivers))

    (lib.mesonOption "d3d-drivers-path" "${placeholder "drivers"}/lib/d3d")

    (lib.mesonBool "gallium-nine" enableGalliumNine) # Direct3D in Wine
    (lib.mesonBool "osmesa" enableOSMesa) # used by wine
    (lib.mesonBool "teflon" false) # TensorFlow frontend
    (lib.mesonEnable "microsoft-clc" false) # Only relevant on Windows (OpenCL 1.2 API on top of D3D12)

    # To enable non-mesa gbm backends to be found (e.g. Nvidia)
    (lib.mesonOption "gbm-backends-path" "${libglvnd.driverLink}/lib/gbm:${placeholder "out"}/lib/gbm")

    # meson auto_features enables these features, but we do not want them
    (lib.mesonEnable "android-libbacktrace" false)
  ] ++ lib.optionals stdenv.isLinux [
    (lib.mesonEnable "glvnd" true)
    (lib.mesonBool "install-intel-clc" false)
    (lib.mesonEnable "intel-rt" stdenv.hostPlatform.isx86_64)
    (lib.mesonOption "clang-libdir" "${lib.getLib llvmPackages.clang-unwrapped}/lib")
  ] ++ lib.optionals enableOpenCL [
    # Rusticl, new OpenCL frontend
    (lib.mesonOption "gallium-opencl" "icd")
    (lib.mesonBool "gallium-rusticl" true)
  ] ++ lib.optionals (!withValgrind) [
    (lib.mesonEnable "valgrind" false)
  ] ++ lib.optionals (!withLibunwind) [
    (lib.mesonEnable "libunwind" false)
  ] ++ lib.optionals enablePatentEncumberedCodecs [
    (lib.mesonOption "video-codecs" "vp9dec")
  ] ++ lib.optionals (vulkanLayers != []) [
    (lib.mesonOption "vulkan-layers" (lib.concatStringsSep "," vulkanLayers))
  ] ++ lib.optionals needNativeCLC [
    (lib.mesonOption "intel-clc" "system")
  ];

  strictDeps = true;

  buildInputs = with xorg; [
    expat
    spirv-tools
    libglvnd
    llvmPackages.libllvm
    zstd
  ] ++ (with xorg; [
    libX11
    libXext
    libXfixes
    libXrandr
    libXxf86vm
    libxcb
    libxshmfence
    xcbutilkeysyms
    xorgproto
  ]) ++ [
    python3Packages.python # for shebang
  ] ++ lib.optionals haveWayland [
    wayland
    wayland-protocols
  ] ++ lib.optionals stdenv.isLinux [
    llvmPackages.clang
    llvmPackages.clang-unwrapped
    llvmPackages.libclc
    lm_sensors
    spirv-llvm-translator
    udev
  ] ++ lib.optionals (lib.meta.availableOn stdenv.hostPlatform elfutils) [
    elfutils
  ] ++ lib.optionals enableOpenCL [
    llvmPackages.clang
  ] ++ lib.optionals withValgrind [
    valgrind-light
  ] ++ lib.optionals haveZink [
    vulkan-loader
  ] ++ lib.optionals haveDozen [
    directx-headers
  ];

  depsBuildBuild = [
    pkg-config
    buildPackages.stdenv.cc
  ];

  nativeBuildInputs = [
    meson
    pkg-config
    ninja
    intltool
    bison
    flex
    file
    python3Packages.python
    python3Packages.packaging
    python3Packages.pycparser
    python3Packages.mako
    python3Packages.ply
    python3Packages.pyyaml
    jdupes
    (lib.getBin glslang)
    rustc
    rust-bindgen
    rust-cbindgen
    rustPlatform.bindgenHook
  ] ++ lib.optionals haveWayland [
    wayland-scanner
  ] ++ lib.optionals needNativeCLC [
    buildPackages.mesa.driversdev
  ];

  disallowedRequisites = lib.optionals needNativeCLC [
    buildPackages.mesa.driversdev
  ];

  propagatedBuildInputs = (with xorg; [
    libXxf86vm
  ]) ++ lib.optionals withLibdrm [
    libdrm
  ];

  doCheck = false;

  postInstall = ''
    # Some installs don't have any drivers so this directory is never created.
    mkdir -p $drivers $osmesa
  '' + lib.optionalString stdenv.isLinux ''
    mkdir -p $drivers/lib

    # Move driver-related bits to $drivers
    moveToOutput "lib/gbm" $drivers
    moveToOutput "lib/libgallium*" $drivers
    moveToOutput "lib/libglapi*" $drivers
    moveToOutput "lib/lib*_mesa*" $drivers
    moveToOutput "lib/libpowervr_rogue*" $drivers
    moveToOutput "lib/libxatracker*" $drivers
    moveToOutput "lib/libvulkan_*" $drivers

    for js in $drivers/share/glvnd/egl_vendor.d/*.json; do
      substituteInPlace "$js" --replace-fail '"libEGL_' '"'"$drivers/lib/libEGL_"
    done

    # Update search path used by Vulkan (it's pointing to $out but
    # drivers are in $drivers)
    for js in $drivers/share/vulkan/icd.d/*.json; do
      substituteInPlace "$js" --replace-fail "$out" "$drivers"
    done
  '' + lib.optionalString enableOpenCL ''
    # Move OpenCL stuff
    mkdir -p $opencl/lib

    mkdir -p $opencl/etc/OpenCL/vendors/
    echo $opencl/lib/libMesaOpenCL.so > $opencl/etc/OpenCL/vendors/mesa.icd
    echo $opencl/lib/libRusticlOpenCL.so > $opencl/etc/OpenCL/vendors/rusticl.icd

    moveToOutput lib/gallium-pipe $opencl
    moveToOutput "lib/lib*OpenCL*" $opencl

  '' + lib.optionalString enableOSMesa ''
    # move libOSMesa to $osmesa, as it's relatively big
    mkdir -p $osmesa/lib
    moveToOutput "lib/libOSMesa*" $osmesa
  '' + lib.optionalString (vulkanLayers != []) ''
    moveToOutput "lib/libVkLayer*" $drivers
    for js in $drivers/share/vulkan/{im,ex}plicit_layer.d/*.json; do
      substituteInPlace "$js" --replace-fail '"libVkLayer_' '"'"$drivers/lib/libVkLayer_"
    done
  '' + lib.optionalString haveDozen ''
    mkdir -p $spirv2dxil/{bin,lib}
    mv -t $spirv2dxil/lib $out/lib/libspirv_to_dxil*
    mv -t $spirv2dxil/bin $out/bin/spirv2dxil
  '';

  postFixup = ''
    # set the default search path for DRI drivers; used e.g. by X server
    for pc in lib/pkgconfig/{dri,d3d}.pc; do
      [ -f "$dev/$pc" ] && substituteInPlace "$dev/$pc" --replace "$drivers" "${libglvnd.driverLink}"
    done

    # remove pkgconfig files for GL/EGL; they are provided by libGL.
    rm -f $dev/lib/pkgconfig/{gl,egl}.pc

    # Move development files for libraries in $drivers to $driversdev
    mkdir -p $driversdev/include
    mv $dev/include/xa_* $dev/include/d3d* -t $driversdev/include || true
    mkdir -p $driversdev/lib/pkgconfig
    for pc in lib/pkgconfig/{xatracker,d3d}.pc; do
      if [ -f "$dev/$pc" ]; then
        substituteInPlace "$dev/$pc" --replace $out $drivers
        mv $dev/$pc $driversdev/$pc
      fi
    done

    # Don't depend on build python
    patchShebangs --host --update $out/bin/*

    # NAR doesn't support hard links, so convert them to symlinks to save space.
    jdupes --hard-links --link-soft --recurse "$drivers"

    # add RPATH so the drivers can find the moved libgallium and libdricore9
    # moved here to avoid problems with stripping patchelfed files
    for lib in $drivers/lib/*.so* $drivers/lib/*/*.so*; do
      if [[ ! -L "$lib" ]]; then
        patchelf --set-rpath "$(patchelf --print-rpath $lib):$drivers/lib" "$lib"
      fi
    done
    # add RPATH here so Zink can find libvulkan.so
    ${lib.optionalString haveZink ''
      patchelf --add-rpath ${vulkan-loader}/lib $drivers/lib/libgallium*.so
    ''}

    ${lib.optionalString enableTeflon ''
      moveToOutput lib/libteflon.so $teflon
    ''}
  '';

  env.NIX_CFLAGS_COMPILE = toString ([
      "-march=armv8.5-a+fp16+fp16fml+aes+sha2+sha3+nosve+nosve2+nomemtag+norng+nosm4+nof32mm+nof64mm"
      "-UPIPE_SEARCH_DIR"
      "-DPIPE_SEARCH_DIR=\"${placeholder "opencl"}/lib/gallium-pipe\""
  ]);

  hardeningEnable = [ "pic" "format" "fortify" "stackprotector" "bindnow" ];
  hardeningDisable = [ "pie" "relro" ];

  passthru = {
    inherit (libglvnd) driverLink;
    inherit llvmPackages;

    libdrm = if withLibdrm then libdrm else null;

    tests = lib.optionalAttrs stdenv.isLinux {
      devDoesNotDependOnLLVM = stdenv.mkDerivation {
        name = "mesa-dev-does-not-depend-on-llvm";
        buildCommand = ''
          echo ${self.dev} >>$out
        '';
        disallowedRequisites = [ llvmPackages.llvm self.drivers ];
      };
    };
  };

  meta = {
    description = "Open source 3D graphics library";
    longDescription = ''
      The Mesa project began as an open-source implementation of the OpenGL
      specification - a system for rendering interactive 3D graphics. Over the
      years the project has grown to implement more graphics APIs, including
      OpenGL ES (versions 1, 2, 3), OpenCL, OpenMAX, VDPAU, VA API, XvMC, and
      Vulkan.  A variety of device drivers allows the Mesa libraries to be used
      in many different environments ranging from software emulation to
      complete hardware acceleration for modern GPUs.
    '';
    homepage = "https://www.mesa3d.org/";
    changelog = "https://www.mesa3d.org/relnotes/${version}.html";
    license = with lib.licenses; [ mit ]; # X11 variant, in most files
    platforms = [
      "i686-linux" "x86_64-linux" "aarch64-linux"
    ];
    maintainers = with lib.maintainers; [ primeos vcunat ]; # Help is welcome :)
  };
};

in self
