#!/usr/bin/env bats
# Which folder serves which name

load helpers

@test "a parked folder is found by its name" {
  php_site escrow
  [ "$(vh site_dir escrow)" = "$PARKED/escrow" ]
}

@test "a folder with capitals is found by its lowercase name" {
  static_site MyApp
  [ "$(vh site_dir myapp)" = "$PARKED/MyApp" ]
}

@test "a lowercase folder wins over one that differs only in case" {
  case "$(uname -s)" in Darwin) skip "macOS folders are case-insensitive" ;; esac
  static_site Both
  static_site both
  [ "$(vh site_dir both)" = "$PARKED/both" ]
}

@test "a linked site is served from its own path" {
  mkdir -p "$HOME/Projects/thing"
  site_conf thing "SITE_PATH=$HOME/Projects/thing
SITE_LINKED=yes"
  [ "$(vh site_dir thing)" = "$HOME/Projects/thing" ]
}

@test "site_from_dir finds the site for a folder deep inside it" {
  php_site escrow
  mkdir -p "$PARKED/escrow/app/Models"
  [ "$(vh site_from_dir "$PARKED/escrow/app/Models")" = escrow ]
}

@test "site_from_dir prefers the deepest configured site" {
  mkdir -p "$HOME/Projects/outer/inner"
  site_conf outer "SITE_PATH=$HOME/Projects/outer"
  site_conf inner "SITE_PATH=$HOME/Projects/outer/inner"
  [ "$(vh site_from_dir "$HOME/Projects/outer/inner")" = inner ]
  [ "$(vh site_from_dir "$HOME/Projects/outer")" = outer ]
}

@test "site_from_dir fails outside every site" {
  run vh site_from_dir "$HOME"
  [ "$status" -ne 0 ]
}

@test "case_sites lists servable folders with capitals, not their lowercase twins" {
  case "$(uname -s)" in Darwin) skip "macOS folders are case-insensitive" ;; esac
  static_site MyApp        # served by its own rule
  static_site Both
  static_site both         # the lowercase one wins; Both gets no rule
  mkdir -p "$PARKED/NoEntry"   # nothing to serve
  static_site lower        # the parked rules already serve it
  run vh case_sites
  [ "$output" = myapp ]
}

@test "case_sites skips a name that already has a site config" {
  static_site MyApp
  site_conf myapp "SITE_PHP=8.4"
  run vh case_sites
  [ -z "$output" ]
}
