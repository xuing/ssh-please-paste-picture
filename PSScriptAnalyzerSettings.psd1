@{
    # Used by CI (.github/workflows/ci.yml) and by anyone who runs:
    #   Invoke-ScriptAnalyzer -Path src, install.ps1 -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
    #
    # Every rule is on unless it is listed below with the reason it does not fit.

    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # ssh-paste is an interactive console program: its messages are for the person at
        # the keyboard (coloured, and they must not enter the success stream, which carries
        # return values and, in --proxy mode, must stay clear because stdout is the SSH
        # byte stream). Write-Host is the right tool here.
        'PSAvoidUsingWriteHost',

        # Failures never break the user's SSH session, by design: the clipboard watcher,
        # the clipboard restore on exit and the process clean-up run `try { ... } catch { }`
        # so that nothing they hit can interrupt the relay or the terminal.
        'PSAvoidUsingEmptyCatchBlock',

        # The helpers are internal functions of one script, not exported cmdlets. Names such
        # as Split-SshArguments describe a list on purpose, and a pure function such as
        # Set-ManagedBlock only returns text. -WhatIf/-Confirm would add nothing: the user
        # confirms by typing --enable or --disable, and the exact change is printed.
        'PSUseSingularNouns',
        'PSUseShouldProcessForStateChangingFunctions',

        # Internal calls of two or three short, fixed parameters (Set-ManagedBlock $text
        # $hosts $proxy). Named parameters would only add noise to the script's main flow.
        'PSAvoidUsingPositionalParameters'
    )

    Rules        = @{
        # The script must keep parsing on Windows PowerShell 5.1 (the one built into
        # Windows) and on PowerShell 7: no ternary, ??, &&, ProcessStartInfo.ArgumentList
        # without feature detection, and so on. CI also parses the file with powershell.exe.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
