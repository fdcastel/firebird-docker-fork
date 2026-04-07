#
# Shared functions for firebird-docker build system.
# Sourced by both firebird-docker.build.ps1 and tests.
#

# Returns distro configuration from assets.json config section.
function Get-DistroConfig([string]$Distro) {
    $config = $script:assetsData.config.distros.$Distro
    if (-not $config) {
        throw "Unknown distro: $Distro. Valid distros: $($script:assetsData.config.distros | Get-Member -MemberType NoteProperty | ForEach-Object Name)"
    }
    return $config
}

# Returns all valid distros for a given major version (excludes blocked variants).
function Get-ValidDistros([int]$Major) {
    $allDistros = @($script:assetsData.config.distros | Get-Member -MemberType NoteProperty | ForEach-Object { $_.Name })
    $blocked = $script:assetsData.config.blockedVariants."$Major"
    if ($blocked) {
        $allDistros = $allDistros | Where-Object { $_ -notin $blocked }
    }
    return $allDistros
}

# Deterministic tag generation. See DECISIONS.md for rationale.
function Get-ImageTags {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][bool]$IsLatestOfMajor,
        [Parameter(Mandatory)][bool]$IsLatestOverall,
        [Parameter(Mandatory)][string]$DefaultDistro
    )

    $v = [version]$Version
    $major = "$($v.Major)"
    $tags = @()

    # Always: {version}-{distro}
    $tags += "$Version-$Distro"

    # If latest of major: {major}-{distro}
    if ($IsLatestOfMajor) {
        $tags += "$major-$Distro"
    }

    # If latest overall: {distro}
    if ($IsLatestOverall) {
        $tags += $Distro
    }

    # Default distro gets additional bare tags
    if ($Distro -eq $DefaultDistro) {
        # Always: {version}
        $tags += $Version

        # If latest of major: {major}
        if ($IsLatestOfMajor) {
            $tags += $major
        }

        # If latest overall: latest
        if ($IsLatestOverall) {
            $tags += 'latest'
        }
    }

    return $tags
}

# Expand a template file using {{VAR}} syntax (safe string replacement).
function Expand-TemplateFile([string]$Path, [hashtable]$Variables) {
    $content = Get-Content $Path -Raw -Encoding UTF8
    foreach ($key in $Variables.Keys) {
        $content = $content.Replace("{{$key}}", $Variables[$key])
    }
    return $content
}

# Write content to file with auto-generated header.
function Write-GeneratedFile([string]$Content, [string]$Destination) {
    if (Test-Path $Destination) {
        $outputFile = Get-Item $Destination
        $outputFile | Set-ItemProperty -Name IsReadOnly -Value $false
    }

    $fileExtension = [System.IO.Path]::GetExtension($Destination)
    $header = if ($fileExtension -eq '.md') {
        @'

[//]: # (This file was auto-generated. Do not edit. See /src.)

'@
    } else {
        @'
#
# This file was auto-generated. Do not edit. See /src.
#

'@
    }
    $header | Set-Content $Destination -Encoding UTF8
    $Content | Add-Content $Destination -Encoding UTF8

    $outputFile = Get-Item $Destination
    $outputFile | Set-ItemProperty -Name IsReadOnly -Value $true
}
