$ErrorActionPreference = 'Stop'

$Templates = 'deploy/kubernetes/src/templates'
$Files = 'deploy/kubernetes/src/files'

function Reject($hits, $why) {
    if (-not $hits) { return }
    $hits | Out-Host
    [Console]::Error.WriteLine("k8s:policy: $why")
    exit 1
}

Reject (Get-ChildItem $Templates -Recurse -File | Select-String 'database:5432|kanae:8000') `
    'service address typed into a template'

Reject (Get-ChildItem $Files -Recurse -Force -File | Where-Object { -not $_.LinkType }).FullName `
    'copy under files/, it should be a symlink'

Reject (Get-ChildItem $Files -Recurse -Force -File |
        Where-Object { -not (Test-Path ([IO.Path]::Combine($_.Directory.FullName, @($_.Target)[0]))) }).FullName `
    'dangling link under files/, its source was renamed'

Reject (Get-ChildItem $Templates -Recurse -File | Where-Object Name -ne '_helpers.tpl' | Select-String 'Files\.Get') `
    '.Files.Get outside _helpers.tpl, read the file through kanae.file'

kube-linter lint --config .kube-linter.yml deploy/kubernetes/dist .k8s-local
exit $LASTEXITCODE
