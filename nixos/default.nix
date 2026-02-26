{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.redmibook-acpi;

  # The source tree with patches (modern_laptop repo root)
  modernLaptopSrc = builtins.path {
    path = ./..;
    name = "modern-laptop-src";
  };

  # Build the patched DSDT CPIO archive that the kernel loads at early boot.
  # This is the NixOS equivalent of fixes/acpi/install.sh.
  acpiOverride = pkgs.stdenv.mkDerivation {
    name = "redmibook-acpi-override";

    dontUnpack = true;

    nativeBuildInputs = with pkgs; [ acpica-tools cpio ];

    buildPhase = let
      dumpDir = cfg.acpiDumpDir;
      patchDir = "${modernLaptopSrc}/${cfg.productName}/${cfg.biosVersion}";
    in ''
      if [ ! -d "${patchDir}" ]; then
        echo "ERROR: Patch directory not found: ${patchDir}"
        echo "Available products/BIOS versions:"
        ls -d ${modernLaptopSrc}/TM*/*/ 2>/dev/null || true
        exit 1
      fi

      # Pick the right patch variant.
      # NixOS iasl output matches the archlinux variant (no extra spaces in Buffer()).
      PATCH="${patchDir}/patch.archlinux.diff"
      if [ ! -f "$PATCH" ]; then
        PATCH="${patchDir}/patch.diff"
      fi

      if [ ! -f "$PATCH" ]; then
        echo "ERROR: No patch file found in ${patchDir}"
        exit 1
      fi

      if [ ! -f "${dumpDir}/dsdt.dat" ]; then
        echo "ERROR: dsdt.dat not found in ${dumpDir}"
        echo "Run 'sudo dump-acpi-tables <output-dir>' first to create the ACPI dump."
        exit 1
      fi

      # Decompile DSDT with external SSDT references (same as the original script)
      SSDT_FILES=$(ls "${dumpDir}"/ssdt*.dat 2>/dev/null | sort -V -r || true)
      if [ -n "$SSDT_FILES" ]; then
        iasl -e $SSDT_FILES -p dsdt -d "${dumpDir}/dsdt.dat"
      else
        iasl -p dsdt -d "${dumpDir}/dsdt.dat"
      fi

      cp dsdt.dsl dsdt.dsl.origin

      # Apply the patch
      if ! patch < "$PATCH"; then
        echo "ERROR: Failed to apply DSDT patch."
        echo "Your DSDT may not be compatible with the patches for ${cfg.productName}/${cfg.biosVersion}."
        exit 1
      fi

      # Recompile (ignore warnings, only fail on errors)
      iasl -ve dsdt.dsl

      # Create the CPIO archive in the format the kernel expects
      mkdir -p kernel/firmware/acpi
      cp dsdt.aml kernel/firmware/acpi/
      find kernel | cpio -H newc --create > acpi_override
    '';

    installPhase = ''
      cp acpi_override "$out"
    '';
  };

in
{
  options.hardware.redmibook-acpi = {
    enable = lib.mkEnableOption "Redmi Book Pro ACPI patch (keyboard, microphone, power management fixes)";

    productName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Product name as detected by dmidecode. Format: `<baseboard-product-name>-<system-product-name>`.
        Run `dmidecode -s baseboard-product-name` and `dmidecode -s system-product-name` to determine yours.
        Common values:
        - `TM2113-Redmi_Book_Pro_15_2022` (Redmi Book Pro 15 2022)
        - `TM2107-Redmi_Book_Pro_14_2022` (Redmi Book Pro 14 2022)
        - `TM2019-RedmiBook_Pro_15S` (RedmiBook Pro 15 2021)
      '';
    };

    biosVersion = lib.mkOption {
      type = lib.types.str;
      description = ''
        BIOS version string. Run `dmidecode -s bios-version` to determine yours.
        For TM2113, supported values include:
        RMARB5B0P0A0A, RMARB5B0P0B0B, RMARB5B0P0C0C,
        RMARB5B0P0E0E, RMARB5B0P1010, RMARB5B1P0C0C.
      '';
    };

    acpiDumpDir = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to directory containing ACPI table dumps (dsdt.dat, ssdt*.dat).
        Generate it by running `sudo dump-acpi-tables /path/to/output-dir`,
        commit the resulting directory into the repo, and then point this
        option at it using a Nix path literal (relative paths work in pure flakes).
      '';
      example = lib.literalExpression "../../acpi-dump";
    };

    overrideAcpiOsi = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Add `acpi_osi=! acpi_osi=Linux` kernel parameters.
        WARNING: This disables LPS0 (PNP0D80), preventing amd_pmc and proper
        s2idle deep sleep. Only enable if you have specific issues that the
        DSDT patch alone doesn't fix. With a patched DSDT this is usually not needed.
      '';
    };

    memSleepDeep = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Add `mem_sleep_default=deep` kernel parameter.
        Only needed for TM2019 (RedmiBook Pro 15 2021).
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # Prepend the ACPI override CPIO to the initrd so the kernel picks up
      # the patched DSDT before any drivers initialize.
      boot.initrd.prepend = [ "${acpiOverride}" ];

      boot.kernelParams =
        lib.optionals cfg.overrideAcpiOsi [ "acpi_osi=!" "acpi_osi=Linux" ]
        ++ lib.optionals cfg.memSleepDeep [ "mem_sleep_default=deep" ];
    })
    {
      # Provide the dump helper script
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "dump-acpi-tables" ''
          set -euo pipefail
          if [ "$(id -u)" -ne 0 ]; then
            echo "Error: must run as root (sudo dump-acpi-tables <output-dir>)" >&2
            exit 1
          fi
          OUTDIR="''${1:-./acpi-dump}"
          mkdir -p "$OUTDIR"
          cd "$OUTDIR"
          ${pkgs.acpica-tools}/bin/acpidump -b
          # Remove tables not needed for DSDT patching (only dsdt.dat and ssdt*.dat are used).
          # msdm.dat and slic.dat may contain OEM license keys and should not be committed.
          find . -maxdepth 1 -name '*.dat' ! -name 'dsdt.dat' ! -name 'ssdt*.dat' -delete
          echo ""
          echo "ACPI tables dumped to: $(pwd)"
          echo ""
          echo "Product: $(${pkgs.dmidecode}/bin/dmidecode -s baseboard-product-name)-$(${pkgs.dmidecode}/bin/dmidecode -s system-product-name | sed 's/ /_/g')"
          echo "BIOS:    $(${pkgs.dmidecode}/bin/dmidecode -s bios-version)"
          echo ""
          echo "Add these to your NixOS configuration:"
          echo "  hardware.redmibook-acpi.acpiDumpDir = \"$(pwd)\";"
          echo "  hardware.redmibook-acpi.biosVersion = \"$(${pkgs.dmidecode}/bin/dmidecode -s bios-version)\";"
        '')
      ];
    }
  ];
}
