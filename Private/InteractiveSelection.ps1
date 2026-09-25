function Show-AvailableUpdates {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Candidates
    )

    Write-Host ''
    Write-Host 'Available installer-managed .NET updates:'
    $Candidates |
        Select-Object @{
            Name = 'Product'
            Expression = { $_.ProductLabel }
        }, @{
            Name = 'Architecture'
            Expression = { $_.Architecture }
        }, @{
            Name = 'Band'
            Expression = { $_.Band }
        }, @{
            Name = 'Installed'
            Expression = { $_.CurrentVersion }
        }, @{
            Name = 'Available'
            Expression = { $_.TargetVersion }
        }, @{
            Name = 'Support'
            Expression = { $_.SupportPhase }
        } |
        Format-Table -AutoSize |
        Out-Host
}

function Select-UpdateCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Candidates,

        [ValidateSet('update', 'uninstall')]
        [string] $Action = 'update'
    )

    try {
        $width = [math]::Max(1, [console]::BufferWidth - 1)
        $lineCount = $Candidates.Count + 2
        $selected = New-Object bool[] $Candidates.Count
        for ($index = 0; $index -lt $selected.Length; $index++) {
            $selected[$index] = $Action -eq 'update'
        }

        for ($line = 0; $line -lt $lineCount; $line++) {
            [console]::WriteLine()
        }
        $top = [console]::CursorTop - $lineCount
        $cursor = 0

        while ($true) {
            $lines = New-Object System.Collections.Generic.List[string]
            if ($Action -eq 'uninstall') {
                $lines.Add('Select .NET installations to uninstall:')
            }
            else {
                $lines.Add('Select .NET updates:')
            }
            for ($index = 0; $index -lt $Candidates.Count; $index++) {
                $marker = if ($selected[$index]) { 'x' } else { ' ' }
                $pointer = if ($index -eq $cursor) { '>' } else { ' ' }
                $candidate = $Candidates[$index]
                if ($Action -eq 'uninstall') {
                    $lines.Add(('{0} [{1}] {2} {3} {4}' -f
                        $pointer, $marker, $candidate.ProductType, $candidate.Architecture, $candidate.Version))
                }
                else {
                    $lines.Add(('{0} [{1}] {2} {3} {4}: {5} -> {6}' -f
                        $pointer, $marker, $candidate.ProductLabel, $candidate.Architecture, $candidate.Band,
                        $candidate.CurrentVersion, $candidate.TargetVersion))
                }
            }
            $lines.Add('Up/Down: move  Space: toggle  A: all  N: none  Enter: accept  Esc: cancel')

            for ($line = 0; $line -lt $lines.Count; $line++) {
                $text = $lines[$line]
                if ($text.Length -gt $width) {
                    $text = $text.Substring(0, $width)
                }
                [console]::SetCursorPosition(0, $top + $line)
                [console]::Write($text.PadRight($width))
            }

            $key = [console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow' {
                    if ($cursor -eq 0) {
                        $cursor = $Candidates.Count - 1
                    }
                    else {
                        $cursor--
                    }
                }
                'DownArrow' {
                    $cursor = ($cursor + 1) % $Candidates.Count
                }
                'Spacebar' {
                    $selected[$cursor] = -not $selected[$cursor]
                }
                'A' {
                    for ($index = 0; $index -lt $selected.Length; $index++) {
                        $selected[$index] = $true
                    }
                }
                'N' {
                    for ($index = 0; $index -lt $selected.Length; $index++) {
                        $selected[$index] = $false
                    }
                }
                'Escape' {
                    [console]::SetCursorPosition(0, $top + $lineCount)
                    return @()
                }
                'Enter' {
                    [console]::SetCursorPosition(0, $top + $lineCount)
                    $result = New-Object System.Collections.Generic.List[object]
                    for ($index = 0; $index -lt $Candidates.Count; $index++) {
                        if ($selected[$index]) {
                            $result.Add($Candidates[$index])
                        }
                    }
                    return $result.ToArray()
                }
            }
        }
    }
    catch {
        $allSwitch = if ($Action -eq 'uninstall') { '-UninstallAll' } else { '-UpdateAll' }
        throw "Interactive checklist input is unavailable in this host. Run with $allSwitch or -VersionBand instead. $($_.Exception.Message)"
    }
}

function Confirm-SelectedUpdates {
    param(
        [Parameter(Mandatory = $true)]
        [int] $Count
    )

    $answer = Read-Host "Download and install $Count selected .NET update(s)? [Y/n]"
    return [string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(?i:y|yes)$'
}
