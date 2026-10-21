{
  description = "QNTX Reduce Plugin - UMAP dimensionality reduction for QNTX";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # The QNTX this plugin is built against: the tag Cargo.toml names.
    qntx = {
      url = "github:teranos/QNTX/v0.44.0";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, qntx }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        # Cargo.lock pins QNTX's crates to one rev; the qntx input is that
        # rev or this flake refuses to build, so the two cannot drift apart.
        lock = builtins.fromTOML (builtins.readFile ./Cargo.lock);
        qntxGrpc = pkgs.lib.findFirst (p: p.name == "qntx-grpc")
          (throw "Cargo.lock holds no qntx-grpc") lock.package;
        lockedRev = pkgs.lib.last (pkgs.lib.splitString "#" qntxGrpc.source);
        qntxSrc =
          if lockedRev == qntx.rev then qntx
          else throw "Cargo.lock pins qntx-grpc at ${lockedRev} but the flake's qntx input is ${qntx.rev}: point both at the same QNTX tag";

        # Python with umap-learn and dependencies
        pythonEnv = pkgs.python313.withPackages (ps: with ps; [
          umap-learn
          numpy
          scikit-learn
        ]);

        # Build qntx-reduce plugin binary (Rust + PyO3)
        qntx-reduce = pkgs.rustPlatform.buildRustPackage {
          pname = "qntx-reduce-plugin";
          version = self.rev or "dev";
          src = ./.;

          # QNTX's crates (qntx-grpc, qntx-proto, qntx-ats) are Cargo's git
          # dependency on teranos/QNTX; nix fetches the rev Cargo.lock pins
          # with its own git fetcher, so there is no hash to keep here.
          cargoLock = {
            lockFile = ./Cargo.lock;
            allowBuiltinFetchGit = true;
          };

          # Nix vendors each QNTX crate on its own, away from the tree
          # qntx-proto's build.rs reads ../../plugin/grpc/protocol from; the
          # protos come from the qntx input instead.
          QNTX_PROTO_DIR = "${qntxSrc}/plugin/grpc/protocol";

          buildInputs = with pkgs; [
            protobuf
            pythonEnv
            openssl
          ];

          nativeBuildInputs = with pkgs; [
            pkg-config
            protobuf
            makeWrapper
          ];

          # Set Python for PyO3 — points to env with umap-learn pre-installed
          PYO3_PYTHON = "${pythonEnv}/bin/python3";

          # 1. Set rpath/install_name so the binary finds libpython at runtime
          # 2. Wrap with PYTHONHOME so the embedded interpreter finds
          #    withPackages site-packages (umap-learn, numpy, scikit-learn)
          postFixup = pkgs.lib.optionalString pkgs.stdenv.isLinux ''
            patchelf --set-rpath "${pkgs.lib.makeLibraryPath [ pythonEnv ]}:$(patchelf --print-rpath $out/bin/qntx-reduce-plugin)" \
              $out/bin/qntx-reduce-plugin
          '' + pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
            install_name_tool -add_rpath "${pkgs.lib.makeLibraryPath [ pythonEnv ]}" \
              $out/bin/qntx-reduce-plugin
          '' + ''
            wrapProgram $out/bin/qntx-reduce-plugin \
              --set PYTHONHOME "${pythonEnv}"
          '';
        };
      in
      {
        packages = {
          default = qntx-reduce;
          qntx-reduce-plugin = qntx-reduce;
        };

        apps.default = {
          type = "app";
          program = "${qntx-reduce}/bin/qntx-reduce-plugin";
        };
      });
}
