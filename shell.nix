((import <nixpkgs> {}).haskellPackages.override {
  extension = self: super: {
    configurator = self.callPackage ./configurator.nix {};
    optparseApplicative = self.callPackage ./optparseApplicative.nix {};
  };
}).callPackage ./default.nix {}
