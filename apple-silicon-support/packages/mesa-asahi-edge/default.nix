{ lib
, fetchFromGitLab
, pkgs
}:

# don't bother to provide Darwin deps
((pkgs.callPackage ./vendor { }).override {
  galliumDrivers = [ "swrast" "asahi" "virgl" "zink" ];
  vulkanDrivers = [ "swrast" "asahi" ];
  vulkanLayers = [ "device-select" "overlay" ];
  eglPlatforms = [ "x11" "wayland" ];
  withLibunwind = false;
  withValgrind = false;
  enableGalliumNine = true;
  enableTeflon = false;
  enablePatentEncumberedCodecs = false;
  # libclc and other OpenCL components are needed for geometry shader support on Apple Silicon
  enableOpenCL = true;
}).overrideAttrs (oldAttrs: {
  # version must be the same length (i.e. no unstable or date)
  # so that system.replaceRuntimeDependencies can work
  version = "25.0.0";
  src = fetchFromGitLab {
    # tracking: https://pagure.io/fedora-asahi/mesa/commits/asahi
    domain = "gitlab.freedesktop.org";
    owner = "asahi";
    repo = "mesa";
    rev = "asahi-20241211";
    hash = "sha256-Ny4M/tkraVLhUK5y6Wt7md1QBtqQqPDUv+aY4MpNA6Y=";
  };

  mesonFlags = oldAttrs.mesonFlags ++ [
      # we do not build any graphics drivers these features can be enabled for
      "-Dgallium-va=disabled"
      "-Dgallium-vdpau=disabled"
      "-Dgallium-xa=disabled"
      "-Dxlib-lease=disabled"
      # does not make any sense
      "-Dintel-rt=disabled"
      # do not want to add the dependencies
      "-Dlibunwind=disabled"
      "-Dlmsensors=disabled"
      # add options from Fedora Asahi's meson flags we're missing
      # some of these get picked up automatically since
      # auto-features is enabled, but better to be explicit
      # in the same places as Fedora is explicit
      "-Dgallium-opencl=icd"
      "-Dgallium-rusticl=true"
      "-Dgallium-rusticl-enable-drivers=asahi"
      "-Degl=enabled"
      "-Dgbm=enabled"
      "-Dopengl=true"
      "-Dshared-glapi=enabled"
      "-Dgles1=enabled"
      "-Dgles2=enabled"
      "-Dglx=dri"
      "-Dglvnd=enabled"
      # enable LLVM specifically (though auto-features seems to turn it on)
      # and enable shared-LLVM specifically like Fedora Asahi does
      # perhaps the lack of shared-llvm was/is breaking rusticl? needs investigation
      "-Dllvm=enabled"
      "-Dshared-llvm=enabled"
      # add in additional options from mesa-asahi's meson options,
      # mostly to make explicit what was once implicit (the Nix way!)
      "-Degl-native-platform=wayland"
      "-Dandroid-strict=false"
      "-Dpower8=disabled"
      # save time, don't build tests
      "-Dbuild-tests=false"
      "-Denable-glcpp-tests=false"
    ];

  # replace patches with ones tweaked slightly to apply to this version
  patches = [
    ./opencl.patch
  ];
})
