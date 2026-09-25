function Assert-InstallerTrust {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Candidate
    )

    $actualHash = (Get-FileHash -LiteralPath $Candidate.InstallerPath -Algorithm SHA512).Hash.ToUpperInvariant()
    if ($actualHash -ne $Candidate.Hash) {
        throw "SHA-512 validation failed for $($Candidate.ProductLabel) $($Candidate.TargetVersion). Expected $($Candidate.Hash), got $actualHash."
    }

    return Assert-InstallerSignature -InstallerPath $Candidate.InstallerPath `
        -ProductLabel $Candidate.ProductLabel -Version $Candidate.TargetVersion
}

function Assert-InstallerSignature {
    param(
        [Parameter(Mandatory = $true)]
        [string] $InstallerPath,

        [Parameter(Mandatory = $true)]
        [string] $ProductLabel,

        [Parameter(Mandatory = $true)]
        [string] $Version
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Authenticode validation failed for $ProductLabel ${Version}: $($signature.Status) - $($signature.StatusMessage)"
    }

    $signer = $signature.SignerCertificate
    if ($null -eq $signer) {
        throw "$ProductLabel $Version has no Authenticode signer certificate."
    }

    if ($signer.Subject -cne $script:ExpectedSignerSubject -or
        $signer.GetNameInfo(
            [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false
        ) -cne '.NET') {
        throw "$ProductLabel $Version has an unexpected signer: '$($signer.Subject)'."
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
            throw "The Authenticode signer chain for $ProductLabel $Version could not be resolved."
        }

        $issuer = $elements[1]
        $root = $elements[$elements.Count - 1]
        $issuerThumbprint = $issuer.Thumbprint.ToUpperInvariant()
        $rootThumbprint = $root.Thumbprint.ToUpperInvariant()

        if (-not $script:TrustedSigningAuthorities.ContainsKey($issuerThumbprint)) {
            throw "$ProductLabel $Version was signed by an unrecognized issuing certificate '$($issuer.Subject)' ($issuerThumbprint)."
        }

        $expectedIssuerSubject = $script:TrustedSigningAuthorities[$issuerThumbprint]
        if ($issuer.Subject -cne $expectedIssuerSubject) {
            throw "$ProductLabel $Version has an unexpected signing-authority subject '$($issuer.Subject)'."
        }

        if ($rootThumbprint -ne $script:ExpectedRootThumbprint -or
            $root.Subject -cne $script:ExpectedRootSubject) {
            throw "$ProductLabel $Version has an unexpected Authenticode trust root '$($root.Subject)' ($rootThumbprint)."
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
