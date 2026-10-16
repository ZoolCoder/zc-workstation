# PowerShell 7's profile: mise for the runtimes, the starship prompt, atuin's
# searchable history and the ZoolCoder colours. Each part loads only when its
# tool is installed, so a fresh machine opens a working shell.
if (Get-Command mise -ErrorAction SilentlyContinue) {
    (& mise activate pwsh) | Out-String | Invoke-Expression
}
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Invoke-Expression (& starship init powershell)
}
if (Get-Command atuin -ErrorAction SilentlyContinue) {
    atuin init powershell | Out-String | Invoke-Expression
}
$theme = Join-Path $HOME '.config/zoolcoder/theme.ps1'
if (Test-Path $theme) { . $theme }
