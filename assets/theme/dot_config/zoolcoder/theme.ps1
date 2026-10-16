# ZoolCoder colours for PowerShell's line editor: the same palette as the
# terminal. The profile dot-sources this file.
if (Get-Module -ListAvailable PSReadLine) {
    Set-PSReadLineOption -Colors @{
        Command          = '#3d7bff'
        Parameter        = '#7fd4f5'
        Operator         = '#b9bfc8'
        Variable         = '#b79cff'
        String           = '#5fd38a'
        Number           = '#f5b44a'
        Type             = '#9cc3ff'
        Keyword          = '#b79cff'
        Comment          = '#3a4150'
        Error            = '#ff7a7e'
        Selection        = "`e[48;2;28;42;74m"
        InlinePrediction = '#3a4150'
    }
}
