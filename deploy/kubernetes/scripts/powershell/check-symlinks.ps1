$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$Files = 'deploy/kubernetes/src/files'
$Map = 'deploy/kubernetes/files.map'
$Workflow = '.github/workflows/kubernetes.yml'

$failed = 0
function Fail($message) {
    [Console]::Error.WriteLine("check-symlinks: $message")
    $script:failed = 1
}

$patterns = yq '.jobs.Changes.steps[] | select(.id == "filter") | .with.filters | from_yaml | .kubernetes[]' $Workflow

$root = [System.IO.Path]::GetFullPath($Files)
$found = @{}
foreach ($item in Get-ChildItem -LiteralPath $Files -Recurse -Force -File) {
    $found[$item.FullName.Substring($root.Length + 1).Replace('\', '/')] = $item
}

foreach ($line in Get-Content -LiteralPath $Map) {
    if ($line -match '^\s*(#|$)') { continue }

    $link, $source = $line -split '\|', 2
    $path = "$Files/$link"
    $expected = [System.IO.Path]::GetRelativePath((Split-Path -Parent $path), $source).Replace('\', '/')

    if (-not (Test-Path -LiteralPath $source)) {
        Fail "$source does not exist, so $path has nothing to point at"
    }

    $item = $found[$link]
    if ($null -eq $item) {
        Fail "$path is not a symlink"
        continue
    }
    if ($item.LinkType -ne 'SymbolicLink') {
        Fail "$path is a plain file. This checkout has no symlink support: run 'git config core.symlinks true' and check out again, or clone with 'git clone -c core.symlinks=true'"
        continue
    }

    $target = @($item.Target)[0].Replace('\', '/')
    if ([System.IO.Path]::IsPathRooted($target)) { Fail "$path has an absolute target: $target" }
    if ($target -ne $expected) { Fail "$path points at $target, expected $expected" }

    $resolved = [System.IO.Path]::Combine($item.Directory.FullName, $target)
    if (-not (Test-Path -LiteralPath $resolved)) { Fail "$path does not resolve" }

    if (-not $patterns.Where({ $source -like $_ }, 'First')) {
        Fail "$source matches no pattern in the kubernetes filter of $Workflow, so a change to it would run no CI"
    }
}

exit $failed
