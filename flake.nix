{
  description = "Linux drivers and ACPI patches for Xiaomi/Redmi laptops";

  inputs = { };

  outputs = { self, ... }: {
    nixosModules = {
      redmibook-acpi = import ./nixos;
      default = self.nixosModules.redmibook-acpi;
    };
  };
}
