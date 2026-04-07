param(
    [string]$VersionFilter,       # Filter by version (e.g. '3', '4.0', '5.0.2').
    [string]$DistributionFilter,  # Filter by image distribution (e.g. 'bookworm', 'bullseye', 'jammy').

    [string]$TestFilter,          # Filter by test name (e.g., 'FIREBIRD_USER_can_create_user'). Used only in the 'Test' task.

    [ValidateSet('master', 'v5.0-release', 'v4.0')]
    [string]$Branch               # Snapshot branch. Used only in the 'Build-Snapshot' task.
)

#
# Globals
#

$outputFolder = './generated'

# Source shared functions
. "$PSScriptRoot/src/functions.ps1"



#
# Tasks
#

# Synopsis: Rebuild "assets.json" from GitHub releases using PSFirebird.
task Update-Assets {
    # PSFirebird is required for this task
    if (-not (Get-Module PSFirebird -ListAvailable)) {
        Install-Module PSFirebird -MinimumVersion '1.0.0' -Force -Scope CurrentUser
    }
    Import-Module PSFirebird -MinimumVersion '1.0.0'

    # Load current config section (distros, blocked variants, default distro)
    $currentData = Get-Content -Raw -Path './assets.json' | ConvertFrom-Json
    $config = $currentData.config

    $defaultDistro = $config.defaultDistro
    $allDistros = $config.distros | Get-Member -MemberType NoteProperty | ForEach-Object { $_.Name }

    # Query GitHub for all Firebird releases
    $allReleases = @()
    foreach ($majorVersion in @(5, 4, 3)) {
        Write-Output "Querying releases for Firebird $majorVersion..."

        # Find all patch versions for this major
        $apiUrl = 'https://api.github.com/repos/FirebirdSQL/firebird/releases?per_page=100'
        $headers = @{ 'User-Agent' = 'PSFirebird' }
        if ($env:GITHUB_TOKEN) {
            $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
        }
        $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers

        $matchingReleases = $releases |
            Where-Object { ($_.tag_name -like "v$majorVersion.*") -and (-not $_.prerelease) } |
            ForEach-Object {
                $v = [version]($_.tag_name.TrimStart('v'))
                [PSCustomObject]@{ Version = $v; TagName = $_.tag_name }
            } |
            Sort-Object { $_.Version } -Descending

        foreach ($rel in $matchingReleases) {
            $version = $rel.Version
            if ($version -lt [version]'3.0.8') { continue }

            Write-Output "  Processing $version..."

            # Get amd64 release
            $amd64 = Find-FirebirdRelease -Version ([semver]"$version") -RuntimeIdentifier 'linux-x64'
            $releaseInfo = [ordered]@{
                amd64 = [ordered]@{
                    url    = $amd64.Url
                    sha256 = $amd64.Sha256
                }
            }

            # Get arm64 release (only FB5+)
            if ($majorVersion -ge 5) {
                try {
                    $arm64 = Find-FirebirdRelease -Version ([semver]"$version") -RuntimeIdentifier 'linux-arm64'
                    $releaseInfo['arm64'] = [ordered]@{
                        url    = $arm64.Url
                        sha256 = $arm64.Sha256
                    }
                } catch {
                    Write-Warning "  No arm64 release for $version"
                }
            }

            # If SHA-256 is null (pre-July 2025 releases), download to compute
            foreach ($arch in @('amd64', 'arm64')) {
                if ($releaseInfo.Contains($arch) -and -not $releaseInfo[$arch].sha256) {
                    Write-Output "    Downloading $arch asset to compute SHA-256..."
                    $tempFile = [System.IO.Path]::GetTempFileName()
                    try {
                        $ProgressPreference = 'SilentlyContinue'
                        Invoke-WebRequest $releaseInfo[$arch].url -OutFile $tempFile
                        $releaseInfo[$arch].sha256 = (Get-FileHash $tempFile -Algorithm SHA256).Hash.ToLower()
                    } finally {
                        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            $allReleases += [PSCustomObject]@{
                Version  = $version
                Major    = $majorVersion
                Releases = $releaseInfo
            }
        }
    }

    # Sort: by major desc, then version desc
    $allReleases = $allReleases | Sort-Object { $_.Major }, { $_.Version } -Descending

    # Group by major to determine latest-of-major
    $byMajor = $allReleases | Group-Object Major
    $latestOverallVersion = $allReleases[0].Version

    # Build tags
    $versions = @()
    foreach ($group in ($byMajor | Sort-Object Name -Descending)) {
        $isFirstInGroup = $true
        foreach ($rel in $group.Group) {
            $validDistros = Get-ValidDistros -Major $rel.Major
            $tags = [ordered]@{}

            foreach ($distro in $validDistros) {
                $distroTags = Get-ImageTags `
                    -Version "$($rel.Version)" `
                    -Distro $distro `
                    -IsLatestOfMajor $isFirstInGroup `
                    -IsLatestOverall ($rel.Version -eq $latestOverallVersion) `
                    -DefaultDistro $defaultDistro
                $tags[$distro] = $distroTags
            }

            $versions += [ordered]@{
                version  = "$($rel.Version)"
                releases = $rel.Releases
                tags     = $tags
            }

            $isFirstInGroup = $false
        }
    }

    # Write assets.json
    $output = [ordered]@{
        config   = $config
        versions = $versions
    }

    $output | ConvertTo-Json -Depth 10 | Out-File './assets.json' -Encoding UTF8
    Write-Output "assets.json updated with $($versions.Count) versions."
}

# Synopsis: Load the assets from "assets.json".
task LoadAssets {
    $script:assetsData = Get-Content -Raw -Path './assets.json' | ConvertFrom-Json
}

# Synopsis: Load the assets from "assets.json", optionally filtering by command-line parameters.
task FilteredAssets LoadAssets, {
    $result = $script:assetsData.versions

    # Filter assets by command-line arguments
    if ($VersionFilter) {
        $result = $result | Where-Object { $_.version -like "$VersionFilter*" }
    }

    if ($DistributionFilter) {
        $result = $result | Where-Object { $_.tags.$DistributionFilter -ne $null } |
            Select-Object -Property 'version','releases',@{Name = 'tags'; Expression = { [PSCustomObject]@{ "$DistributionFilter" = $_.tags.$DistributionFilter } } }
    }

    if (-not $result) {
        Write-Error "No assets found matching the specified filters."
        exit 1
    }

    $script:assets = $result
}

# Synopsis: Rebuild "README.md" from "assets.json".
task Update-Readme LoadAssets, {
    $assets = $script:assetsData.versions
    $TSupportedTags = $assets | ForEach-Object {
        $asset = $_
        $version = [version]$asset.version
        $versionFolder = Join-Path $outputFolder $version

        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $image = $_.Name
            $TImageTags = $asset.tags.$image
            if ($TImageTags) {
                $TImageTags = "``{0}``" -f ($TImageTags -join "``, ``")
            }
            $variantFolder = (Join-Path $versionFolder $image).Replace('\', '/')
            Write-Output "|$TImageTags|[Dockerfile]($variantFolder/Dockerfile)|`n"
        }
    }

    $template = Get-Content './src/README.md.template' -Raw -Encoding UTF8
    $content = $template.Replace('{{SupportedTags}}', ($TSupportedTags -join ' '))
    Write-GeneratedFile -Content $content -Destination './README.md'
}

# Synopsis: Clean up the output folder.
task Clean {
    Remove-Item -Path $outputFolder -Recurse -Force -ErrorAction SilentlyContinue
}

# Synopsis: Invoke preprocessor to generate the image source files (can be filtered using command-line options).
task Prepare FilteredAssets, {
    # Create output folders if they do not exist
    New-Item -ItemType Directory $outputFolder -Force > $null

    $config = $script:assetsData.config

    # For each asset
    $assets | ForEach-Object {
        $asset = $_

        $version = [version]$asset.version
        $versionFolder = Join-Path $outputFolder $version
        New-Item -ItemType Directory $versionFolder -Force > $null

        # For each tag/distro
        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $distribution = $_.Name
            $distributionFolder = Join-Path $versionFolder $distribution
            New-Item -ItemType Directory $distributionFolder -Force > $null

            $distroConfig = Get-DistroConfig -Distro $distribution

            # Template variables
            $hasArm64 = ($null -ne $asset.releases.arm64)
            $variables = @{
                'BASE_IMAGE'        = $distroConfig.baseImage
                'ICU_PACKAGE'       = $distroConfig.icuPackage
                'EXTRA_PACKAGES'    = if ($distroConfig.extraPackages) { "        $($distroConfig.extraPackages) \`n" } else { '' }
                'URL_AMD64'         = "$($asset.releases.amd64.url)"
                'SHA256_AMD64'      = "$($asset.releases.amd64.sha256)"
                'URL_ARM64'         = if ($hasArm64) { "$($asset.releases.arm64.url)" } else { '' }
                'SHA256_ARM64'      = if ($hasArm64) { "$($asset.releases.arm64.sha256)" } else { '' }
                'FIREBIRD_VERSION'  = "$($asset.version)"
                'FIREBIRD_MAJOR'    = "$($version.Major)"
            }

            # Render template
            $dockerfile = Expand-TemplateFile -Path './src/Dockerfile.template' -Variables $variables

            # For amd64-only versions, remove the arm64 case from the Dockerfile
            if (-not $hasArm64) {
                $dockerfile = $dockerfile -replace "(?ms)\s+arm64\)\s*\\.*?;;\s*\\", ''
            }

            Write-GeneratedFile -Content $dockerfile -Destination "$distributionFolder/Dockerfile"
            Copy-Item './src/entrypoint.sh' $distributionFolder
        }
    }
}

# Synopsis: Build all docker images (can be filtered using command-line options).
task Build Prepare, {
    $PSStyle.OutputRendering = 'PlainText'
    $config = $script:assetsData.config
    $imagePrefix = 'firebirdsql'
    $imageName = 'firebird'

    # Detect host architecture
    $hostArch = if ($IsLinux) { (dpkg --print-architecture 2>$null) ?? 'amd64' } else { 'amd64' }

    $assets | ForEach-Object {
        $asset = $_
        $version = [version]$asset.version
        $versionFolder = Join-Path $outputFolder $version

        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $distribution = $_.Name
            $distributionFolder = Join-Path $versionFolder $distribution
            $imageTags = $asset.tags.$distribution
            $hasArm64 = ($null -ne $asset.releases.arm64)

            # Build amd64
            if ($hostArch -eq 'amd64') {
                $tagsAmd64 = $imageTags | ForEach-Object { '--tag', "$imagePrefix/${imageName}-amd64:$_" }
                $buildArgs = @(
                    'build'
                    $tagsAmd64
                    '--label', 'org.opencontainers.image.description=Firebird Database'
                    '--label', "org.opencontainers.image.version=$($asset.version)"
                    '--progress=plain'
                    $distributionFolder
                )
                Write-Build Cyan "----- [$($asset.version) / $distribution / amd64] -----"
                exec { & docker $buildArgs *>&1 }
            }

            # Build arm64 (only if available and on arm64 host)
            if ($hasArm64 -and $hostArch -eq 'arm64') {
                $tagsArm64 = $imageTags | ForEach-Object { '--tag', "$imagePrefix/${imageName}-arm64:$_" }
                $buildArgs = @(
                    'build'
                    $tagsArm64
                    '--label', 'org.opencontainers.image.description=Firebird Database'
                    '--label', "org.opencontainers.image.version=$($asset.version)"
                    '--progress=plain'
                    $distributionFolder
                )
                Write-Build Cyan "----- [$($asset.version) / $distribution / arm64] -----"
                exec { & docker $buildArgs *>&1 }
            }
        }
    }
}

# Synopsis: Run all tests (can be filtered using command-line options).
task Test FilteredAssets, {
    $imagePrefix = 'firebirdsql'
    $imageName = 'firebird'
    $testFile = './src/image.tests.ps1'

    # Detect host architecture
    $hostArch = if ($IsLinux) { (dpkg --print-architecture 2>$null) ?? 'amd64' } else { 'amd64' }

    if ($TestFilter) {
        Write-Verbose "Running single test '$TestFilter'..."
    } else {
        Write-Verbose "Running all tests..."
        $TestFilter = '*'
    }

    $assets | ForEach-Object {
        $asset = $_
        $hasArm64 = ($null -ne $asset.releases.arm64)
        $tag = $asset.tags | Get-Member -MemberType NoteProperty | Select-Object -First 1 | ForEach-Object {
            $asset.tags.($_.Name) | Select-Object -First 1
        }

        Write-Build Magenta "----- [$($asset.version)] -----"

        # Test host architecture
        $env:FULL_IMAGE_NAME = "$imagePrefix/${imageName}-${hostArch}:${tag}"
        Write-Verbose "  Image: $($env:FULL_IMAGE_NAME)"
        Invoke-Build $TestFilter $testFile
    }
}

# Synopsis: Publish all images.
task Publish FilteredAssets, {
    $imagePrefix = 'firebirdsql'
    $imageName = 'firebird'

    $assets | ForEach-Object {
        $asset = $_
        $hasArm64 = ($null -ne $asset.releases.arm64)

        Write-Build Magenta "----- [$($asset.version)] -----"

        $asset.tags | Get-Member -MemberType NoteProperty | ForEach-Object {
            $distribution = $_.Name
            $imageTags = $asset.tags.$distribution

            $imageTags | ForEach-Object {
                $tag = $_
                docker push "$imagePrefix/${imageName}-amd64:$tag"

                if ($hasArm64) {
                    docker push "$imagePrefix/${imageName}-arm64:$tag"

                    docker manifest create --amend "$imagePrefix/${imageName}:$tag" `
                        "$imagePrefix/${imageName}-amd64:$tag" `
                        "$imagePrefix/${imageName}-arm64:$tag"

                    docker manifest annotate "$imagePrefix/${imageName}:$tag" `
                        "$imagePrefix/${imageName}-amd64:$tag" --os linux --arch amd64
                    docker manifest annotate "$imagePrefix/${imageName}:$tag" `
                        "$imagePrefix/${imageName}-arm64:$tag" --os linux --arch arm64

                    docker manifest push "$imagePrefix/${imageName}:$tag"
                }
                else {
                    docker image tag "$imagePrefix/${imageName}-amd64:$tag" `
                        "$imagePrefix/${imageName}:$tag"
                    docker push "$imagePrefix/${imageName}:$tag"
                }
            }
        }
    }
}

# Synopsis: Build a snapshot image from a Firebird pre-release branch.
task Build-Snapshot LoadAssets, {
    if (-not $Branch) {
        throw "The -Branch parameter is required for Build-Snapshot. Use: Invoke-Build Build-Snapshot -Branch master"
    }

    # PSFirebird is required for this task
    if (-not (Get-Module PSFirebird -ListAvailable)) {
        Install-Module PSFirebird -MinimumVersion '1.0.0' -Force -Scope CurrentUser
    }
    Import-Module PSFirebird -MinimumVersion '1.0.0'

    $PSStyle.OutputRendering = 'PlainText'
    $imagePrefix = 'firebirdsql'
    $imageName = 'firebird'
    $defaultDistro = 'bookworm'

    # Detect host architecture
    $hostArch = if ($IsLinux) { (dpkg --print-architecture 2>$null) ?? 'amd64' } else { 'amd64' }
    $rid = if ($hostArch -eq 'amd64') { 'linux-x64' } else { 'linux-arm64' }

    Write-Build Cyan "Querying snapshot for branch '$Branch' ($rid)..."
    $snapshot = Find-FirebirdSnapshotRelease -Branch $Branch -RuntimeIdentifier $rid

    Write-Build Cyan "Found: $($snapshot.FileName) (uploaded: $($snapshot.UploadedAt))"

    # Determine version tag from branch
    $snapshotTag = switch ($Branch) {
        'master'        { '6-snapshot' }
        'v5.0-release'  { '5-snapshot' }
        'v4.0'          { '4-snapshot' }
    }

    # Determine major version for Dockerfile template
    $major = switch ($Branch) {
        'master'        { '6' }
        'v5.0-release'  { '5' }
        'v4.0'          { '4' }
    }

    # Prepare snapshot Dockerfile
    $snapshotFolder = Join-Path $outputFolder "snapshot-$Branch" $defaultDistro
    New-Item -ItemType Directory $snapshotFolder -Force > $null

    $distroConfig = Get-DistroConfig -Distro $defaultDistro
    $variables = @{
        'BASE_IMAGE'        = $distroConfig.baseImage
        'ICU_PACKAGE'       = $distroConfig.icuPackage
        'EXTRA_PACKAGES'    = ''
        'URL_AMD64'         = if ($hostArch -eq 'amd64') { "$($snapshot.Url)" } else { '' }
        'SHA256_AMD64'      = if ($hostArch -eq 'amd64') { "$($snapshot.Sha256)" } else { '' }
        'URL_ARM64'         = if ($hostArch -eq 'arm64') { "$($snapshot.Url)" } else { '' }
        'SHA256_ARM64'      = if ($hostArch -eq 'arm64') { "$($snapshot.Sha256)" } else { '' }
        'FIREBIRD_VERSION'  = "$snapshotTag"
        'FIREBIRD_MAJOR'    = $major
    }

    $dockerfile = Expand-TemplateFile -Path './src/Dockerfile.template' -Variables $variables

    # Remove the unused arch case
    if ($hostArch -eq 'amd64') {
        $dockerfile = $dockerfile -replace "(?ms)\s+arm64\)\s*\\.*?;;\s*\\", ''
    } else {
        $dockerfile = $dockerfile -replace "(?ms)\s+amd64\)\s*\\.*?;;\s*\\", ''
    }

    Write-GeneratedFile -Content $dockerfile -Destination "$snapshotFolder/Dockerfile"
    Copy-Item './src/entrypoint.sh' $snapshotFolder

    # Build
    $buildArgs = @(
        'build'
        '--tag', "$imagePrefix/${imageName}:$snapshotTag"
        '--label', 'org.opencontainers.image.description=Firebird Database (snapshot)'
        '--label', "org.opencontainers.image.version=$snapshotTag"
        '--progress=plain'
        $snapshotFolder
    )
    Write-Build Cyan "----- [snapshot / $Branch / $hostArch] -----"
    exec { & docker $buildArgs *>&1 }

    Write-Build Green "Snapshot image built: $imagePrefix/${imageName}:$snapshotTag"
}

# Synopsis: Default task.
task . Build
