{ self, inputs, ... }:
{
  flake.nixosModules.base = { pkgs, ... }: {
    
    imports = [
      inputs.home-manager.nixosModules.home-manager
    ];

    nix.settings = {
      trusted-users = [ "romes" ];
      experimental-features = [ "nix-command" "flakes" ];
    };
    nixpkgs.config.allowUnfree = true;

    environment = {
      systemPackages = with pkgs; [
        vim
        btop
        ncurses
        ghostty.terminfo
      ];
      variables = {
        HISTCONTROL = "ignoredups";
        EDITOR = "vim";
      };
    };

    security.sudo = {
      enable = true;
      wheelNeedsPassword = false;
    };
  
    users.users.romes = {
      isNormalUser = true;
      shell = pkgs.zsh;
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKdREVP76ISSwCnKzqMCeaMwgETLtnKqWPF7ORZSReZ romes@world"
      ];
      extraGroups = [ "wheel" "networkmanager" "video" "input" "seat" ]; # Enable ‘sudo’ for the user.
      packages = [ ];
      uid = 1000;
    };
  
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.users.romes = {
      imports = [
        self.homeModules.romes
      ];
  
      # is this thing working?
      home.sessionVariables = {
        TERMINFO_DIRS = "$HOME/.terminfo:$TERMINFO_DIRS";
      };
      # part of this ^^
      home.file.".terminfo/x/xterm-ghostty".source = "${pkgs.ghostty.terminfo}/share/terminfo/x/xterm-ghostty";
      home.file.".terminfo/x/xterm-256color".source = "${pkgs.ncurses}/share/terminfo/x/xterm-256color";
    };
  
    programs.zsh.enable = true;
  
    services.openssh.enable = true;
  };
}
