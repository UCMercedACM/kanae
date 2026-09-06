[CmdletBinding()]
param(
    [string]$Namespace
)

$ErrorActionPreference = 'Stop'

$namespaceName = if ($Namespace) { $Namespace } elseif ($env:usage_namespace) { $env:usage_namespace } else { 'kanae' }

$now = (Get-Date).ToUniversalTime()

$rows = foreach ($pod in (kubectl get pods --namespace $namespaceName -o jsonpath='{.items[*].metadata.name}') -split ' ' | Where-Object { $_ }) {
    $statuses = kubectl get pod $pod --namespace $namespaceName `
        -o jsonpath='{range .status.containerStatuses[*]}{.name} {.state.running.startedAt}{"\n"}{end}'

    foreach ($status in $statuses -split '\r?\n' | Where-Object { $_ }) {
        $container, $started = $status -split ' '

        if (-not $started) { continue }

        $lines = kubectl exec $pod --container $container --namespace $namespaceName -- `
            cat /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.stat 2>$null

        if ($LASTEXITCODE -ne 0 -or $lines.Count -lt 3) {
            [pscustomobject]@{ POD = $pod; CONTAINER = $container; 'PEAK (Mi)' = '?'; 'LIMIT (Mi)' = '?'; 'OF LIMIT' = '?'; 'CPU (m)' = '?' }
            continue
        }

        $peakBytes = [long]$lines[0]
        $limit = '-'
        $share = '-'
        if ($lines[1] -ne 'max') {
            $limit = [long]$lines[1] / 1MB
            $share = '{0}%' -f [int]($peakBytes * 100 / [long]$lines[1])
        }

        $elapsed = ($now - [datetime]::Parse($started).ToUniversalTime()).TotalSeconds
        $usageUsec = [long]($lines[2] -replace '^usage_usec ')
        $cpu = if ($elapsed -gt 0) { [int]($usageUsec / 1000 / $elapsed) } else { 0 }

        [pscustomobject]@{
            POD           = $pod
            CONTAINER     = $container
            'PEAK (Mi)'   = [int]($peakBytes / 1MB)
            'LIMIT (Mi)'  = $limit
            'OF LIMIT'    = $share
            'CPU (m)'     = $cpu
        }
    }
}

$rows | Format-Table -AutoSize
