{ inputs, ... }:
{
  perSystem = { system, ... }: {
    # vim plugin for editing a data source as buffer text (~/Developer/vlens.nvim).
    packages.vlens-nvim = inputs.vlens-nvim.packages.${system}.default;
  };
}
