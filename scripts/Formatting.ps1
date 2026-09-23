#requires -Version 7.4.6

function Format-CleanupSize {
    param([Parameter(Mandatory = $true)][ValidateScript({ $_ -ge 0 })][decimal]$Bytes)

    # Match PowerShell's binary size constants; only the display is rounded.
    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB')
    $size = $Bytes
    $unit = 0
    while ($unit -lt ($units.Count - 1) -and [Math]::Round($size, 2) -ge 1024) {
        $size /= 1024
        $unit++
    }
    return ('{0:N2} {1}' -f $size, $units[$unit])
}
