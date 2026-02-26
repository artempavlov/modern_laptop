# NixOS ACPI Patch Module for Redmi Book Pro

NixOS module that applies ACPI DSDT patches for Xiaomi/Redmi laptops.
Fixes keyboard, microphone, power management, and suspend/resume issues.

## Supported Models

| Model                  | Product Name                    |
| ---------------------- | ------------------------------- |
| Redmi Book Pro 15 2022 | `TM2113-Redmi_Book_Pro_15_2022` |
| Redmi Book Pro 14 2022 | `TM2107-Redmi_Book_Pro_14_2022` |
| RedmiBook Pro 15 2021  | `TM2019-RedmiBook_Pro_15S`      |

## Setup (3 steps)

### 1. Import the module

In your `flake.nix` or `configuration.nix`:

```nix
# flake.nix
{
  inputs.modern-laptop.url = "github:artempavlov/modern_laptop";

  outputs = { self, nixpkgs, modern-laptop, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        modern-laptop.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

Or without flakes, clone the repo and import directly:

```nix
# configuration.nix
{
  imports = [
    /path/to/modern_laptop/nixos
  ];
}
```

### 2. Dump ACPI tables

After importing the module, rebuild once to get the helper script, then dump:

```bash
sudo nixos-rebuild switch
sudo dump-acpi-tables /etc/nixos/acpi-dump
```

The script prints your product name and BIOS version.

### 3. Configure and rebuild

```nix
# configuration.nix
{
  hardware.redmibook-acpi = {
    enable = true;
    productName = "TM2113-Redmi_Book_Pro_15_2022";  # from step 2
    biosVersion = "RMARB5B0P0C0C";                   # from step 2
    acpiDumpDir = /etc/nixos/acpi-dump;               # path from step 2
  };
}
```

Then rebuild:

```bash
sudo nixos-rebuild switch
```

Reboot to apply.

## Options

| Option            | Type   | Default                         | Description                                   |
| ----------------- | ------ | ------------------------------- | --------------------------------------------- |
| `enable`          | bool   | `false`                         | Enable the ACPI patch                         |
| `productName`     | string | `TM2113-Redmi_Book_Pro_15_2022` | Product identifier (see supported models)     |
| `biosVersion`     | string | —                               | BIOS version string                           |
| `acpiDumpDir`     | path   | —                               | Path to ACPI dump directory                   |
| `overrideAcpiOsi` | bool   | `true`                          | Add `acpi_osi=! acpi_osi=Linux` kernel params |
| `memSleepDeep`    | bool   | `false`                         | Add `mem_sleep_default=deep` (TM2019 only)    |

## How it works

1. At `nixos-rebuild` time, the module decompiles your dumped DSDT table using `iasl`
2. Applies the appropriate patch from the repository for your model/BIOS version
3. Recompiles the patched DSDT into an AML binary
4. Wraps it in a CPIO archive and prepends it to the initrd via `boot.initrd.prepend`
5. The kernel loads the patched DSDT at early boot, before any drivers initialize

This is the NixOS-native equivalent of `sudo ./install.sh acpi`.
