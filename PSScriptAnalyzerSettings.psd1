@{
    # PSScriptAnalyzer settings used by .github/workflows/ci.yaml.
    # Suppressions live here (not as inline attributes) so the justification is
    # discoverable in one place and doesn't clutter every parameter block.

    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # GitHub Actions inputs are always strings, so signing scripts that bridge
        # a `pfx-password` action input to the .NET PFX import API have no way to
        # accept a SecureString at the boundary. The plaintext-to-SecureString
        # conversion is immediate, the resulting SecureString is the only thing
        # that leaves the function, and the temp PFX file is removed in a finally
        # block. Suppressing globally rather than per-script because every signing
        # helper hits the same constraint.
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingConvertToSecureStringWithPlainText',

        # `$PSNativeCommandErrorActionPreference` is a PowerShell automatic
        # variable; assigning it changes runtime behaviour but the analyzer can't
        # see the consumption (the runtime does it implicitly when invoking native
        # commands), so it warns spuriously.
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
