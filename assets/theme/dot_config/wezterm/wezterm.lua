-- ZoolCoder for WezTerm, the terminal on Windows: the same colours, font and
-- glass as Ghostty on the Mac. WezTerm reads this file on every system.
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

config.colors = {
  foreground = '#f3f5f7',
  background = '#05060a',
  cursor_bg = '#9cc3ff',
  cursor_fg = '#05060a',
  cursor_border = '#9cc3ff',
  selection_bg = '#1c2a4a',
  selection_fg = '#f3f5f7',
  ansi = { '#161a22', '#ff7a7e', '#5fd38a', '#f5b44a', '#3d7bff', '#b79cff', '#7fd4f5', '#b9bfc8' },
  brights = { '#3a4150', '#ff9a9d', '#7fe0a3', '#ffd27a', '#9cc3ff', '#cdbfff', '#a5e3fa', '#f3f5f7' },
  tab_bar = {
    background = '#05060a',
    active_tab = { bg_color = '#1c2a4a', fg_color = '#f3f5f7' },
    inactive_tab = { bg_color = '#05060a', fg_color = '#b9bfc8' },
    inactive_tab_hover = { bg_color = '#161a22', fg_color = '#f3f5f7' },
    new_tab = { bg_color = '#05060a', fg_color = '#b9bfc8' },
    new_tab_hover = { bg_color = '#161a22', fg_color = '#f3f5f7' },
  },
}

config.font = wezterm.font 'JetBrainsMono Nerd Font Mono'
config.font_size = 12
config.line_height = 1.08
config.window_background_opacity = 0.92
-- Acrylic is the Windows blur behind a see-through window.
config.win32_system_backdrop = 'Acrylic'
config.window_padding = { left = 14, right = 14, top = 10, bottom = 10 }
config.use_fancy_tab_bar = false
config.hide_tab_bar_if_only_one_tab = true
config.default_cursor_style = 'SteadyBar'
config.scrollback_lines = 50000

-- PowerShell 7 on Windows; elsewhere the login shell.
if wezterm.target_triple:find 'windows' then
  config.default_prog = { 'pwsh.exe', '-NoLogo' }
end

return config
