$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$ageKey = if ($env:SOPS_AGE_KEY_FILE) { $env:SOPS_AGE_KEY_FILE } else { Join-Path $env:APPDATA 'sops\age\keys.txt' }

if (-not $env:SOPS_AGE_KEY) {
    if (-not (Test-Path -LiteralPath $ageKey)) {
        throw "apply: no age key at $ageKey, so deploy/kubernetes/secrets.sops.yml cannot be decrypted. Point SOPS_AGE_KEY_FILE at yours"
    }

    # sops reads a passphrase-encrypted identity itself, but it asks through
    # pinentry rather than in line with the rest of this output. age asks here.
    if (Select-String -LiteralPath $ageKey -Pattern 'BEGIN AGE ENCRYPTED FILE' -Quiet) {
        Write-Host "==> unlocking $ageKey"
        $env:SOPS_AGE_KEY = (age --decrypt $ageKey) -join "`n"
    }
}

Write-Host "==> rendering the Secrets from deploy/kubernetes/secrets.sops.yml"
$secrets = sops --decrypt deploy/kubernetes/secrets.sops.yml |
    helm template kanae deploy/kubernetes/src --namespace kanae `
        --set renderSecrets=true --values - --show-only templates/secrets.yml

Write-Host "==> handing them to kapp beside deploy/kubernetes/dist"
$tmp = Join-Path ([IO.Path]::GetTempPath()) "kanae-secrets-$([guid]::NewGuid()).yml"
try {
    Set-Content -LiteralPath $tmp -Value $secrets -Encoding utf8
    kapp deploy --yes -a kanae -n kanae -c -f deploy/kubernetes/dist -f $tmp
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
