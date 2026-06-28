@{
    # PSScriptAnalyzer config for CI. Fails on Error + Warning, EXCEPT the rules below that
    # are by-design, false positives for this codebase, or scheduled for a later refactor.
    # All other default rules stay active to catch new problems.
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # Intentional: this is an interactive installer; Write-Host IS the console UX.
        'PSAvoidUsingWriteHost'

        # By design: passwords come from the operator's config.ps1 (a gitignored plaintext
        # PS file) and MUST be converted to SecureString for Set-LocalUser/New-LocalUser.
        # There is no credential store in this USB-portable, no-AD scenario.
        'PSAvoidUsingConvertToSecureStringWithPlainText'

        # Write-Log is the script's own logger, not a built-in cmdlet clash.
        'PSAvoidOverwritingBuiltInCmdlets'

        # Encoding is controlled deliberately (autounattend.xml needs UTF-8 *without* BOM;
        # build-usb.ps1 writes it that way on purpose).
        'PSUseBOMForUnicodeEncodedFile'

        # Style only (e.g. Remove-Diacritics) - plural reads better here.
        'PSUseSingularNouns'

        # False positives in WinForms event-handler scriptblocks: param($s, $e) is the
        # required signature even when the body ignores the args.
        'PSReviewUnusedParameter'

        # UI builder helpers (New-Group/New-TextBox/Set-Phase) are not real state-changing
        # cmdlets that need ShouldProcess/-WhatIf.
        'PSUseShouldProcessForStateChangingFunctions'

        # --- TODO: re-enable these as the matching reform stage lands ---

        # WinForms builder pattern: control vars are parented to the form (used) but not
        # re-referenced, so the analyzer thinks they are write-only. Revisit after Stage 4
        # (modularization) splits the GUI builder out.
        'PSUseDeclaredVarsMoreThanAssignments'

        # Best-effort cleanup blocks (progress-runspace dispose, log enqueue). Intentional
        # for now; revisit after Stage 4 to add explicit error logging where useful.
        'PSAvoidUsingEmptyCatchBlock'

        # build-usb.ps1 -AdminPassword is a plaintext [string] param. Stage 1 converts it to
        # [securestring]; REMOVE this exclusion once that lands so the rule guards it again.
        'PSAvoidUsingPlainTextForPassword'
    )
}
