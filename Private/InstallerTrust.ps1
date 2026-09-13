function Assert-InstallerTrust {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Candidate
    )

    $hashAlgorithmProperty = $Candidate.PSObject.Properties['HashAlgorithm']
    $hashAlgorithm = if ($null -ne $hashAlgorithmProperty -and
        -not [string]::IsNullOrWhiteSpace([string] $hashAlgorithmProperty.Value)) {
        [string] $hashAlgorithmProperty.Value
    }
    elseif ($Candidate.Hash.Length -eq 128) {
        'SHA512'
    }
    elseif ($Candidate.Hash.Length -eq 64) {
        'SHA256'
    }
    else {
        throw "No supported hash algorithm was provided for $($Candidate.ProductLabel) $($Candidate.TargetVersion)."
    }

    if ($hashAlgorithm -notin @('SHA256', 'SHA512')) {
        throw "Unsupported hash algorithm '$hashAlgorithm' for $($Candidate.ProductLabel) $($Candidate.TargetVersion)."
    }

    $actualHash = (Get-FileHash -LiteralPath $Candidate.InstallerPath `
        -Algorithm $hashAlgorithm).Hash.ToUpperInvariant()
    if ($actualHash -ne $Candidate.Hash) {
        throw "$hashAlgorithm validation failed for $($Candidate.ProductLabel) $($Candidate.TargetVersion). Expected $($Candidate.Hash), got $actualHash."
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $Candidate.InstallerPath
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Authenticode validation failed for $($Candidate.ProductLabel) $($Candidate.TargetVersion): $($signature.Status) - $($signature.StatusMessage)"
    }

    $signer = $signature.SignerCertificate
    if ($null -eq $signer) {
        throw "$($Candidate.ProductLabel) $($Candidate.TargetVersion) has no Authenticode signer certificate."
    }

    $simpleName = $signer.GetNameInfo(
        [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
        $false
    )
    if (-not $script:ExpectedSignerSubjects.ContainsKey($signer.Subject) -or
        $simpleName -cne $script:ExpectedSignerSubjects[$signer.Subject]) {
        throw "$($Candidate.ProductLabel) $($Candidate.TargetVersion) has an unexpected signer: '$($signer.Subject)'."
    }

    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    try {
        $chain.ChainPolicy.RevocationMode =
            [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.VerificationFlags =
            [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid
        $chain.ChainPolicy.UrlRetrievalTimeout = [timespan]::FromSeconds(30)
        [void] $chain.Build($signer)

        $elements = @()
        foreach ($chainElement in $chain.ChainElements) {
            $elements += $chainElement.Certificate
        }
        if ($elements.Count -lt 3) {
            throw "The Authenticode signer chain for $($Candidate.ProductLabel) $($Candidate.TargetVersion) could not be resolved."
        }

        $issuer = $elements[1]
        $root = $elements[$elements.Count - 1]
        $issuerThumbprint = $issuer.Thumbprint.ToUpperInvariant()
        $rootThumbprint = $root.Thumbprint.ToUpperInvariant()

        if (-not $script:TrustedSigningAuthorities.ContainsKey($issuerThumbprint)) {
            throw "$($Candidate.ProductLabel) $($Candidate.TargetVersion) was signed by an unrecognized issuing certificate '$($issuer.Subject)' ($issuerThumbprint)."
        }

        $expectedIssuerSubject = $script:TrustedSigningAuthorities[$issuerThumbprint]
        if ($issuer.Subject -cne $expectedIssuerSubject) {
            throw "$($Candidate.ProductLabel) $($Candidate.TargetVersion) has an unexpected signing-authority subject '$($issuer.Subject)'."
        }

        if ($rootThumbprint -ne $script:ExpectedRootThumbprint -or
            $root.Subject -cne $script:ExpectedRootSubject) {
            throw "$($Candidate.ProductLabel) $($Candidate.TargetVersion) has an unexpected Authenticode trust root '$($root.Subject)' ($rootThumbprint)."
        }
    }
    finally {
        $chain.Dispose()
    }

    [pscustomobject] @{
        SignerSubject = $signer.Subject
        SignerThumbprint = $signer.Thumbprint
        IssuerSubject = $issuer.Subject
        IssuerThumbprint = $issuer.Thumbprint
    }
}
