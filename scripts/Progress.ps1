#requires -Version 7.4
function Invoke-CleanupActivity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message, [Parameter(Mandatory)][scriptblock]$Action)
    $indicator = $null
    $interactive = $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected
    if ($interactive) {
        try {
            if (-not ('Spvc.ActivityIndicator' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.Threading;
namespace Spvc {
    public sealed class ActivityIndicator : IDisposable {
        private readonly object gate = new object();
        private readonly Timer timer;
        private readonly string message;
        private readonly string[] frames = { "[/]", "[-]", "[\\]", "[|]" };
        private int frame;
        private bool stopped;
        public ActivityIndicator(string label) {
            message = label;
            timer = new Timer(Draw, null, 0, 180);
        }
        private void Draw(object state) {
            lock (gate) {
                if (stopped) return;
                try { Console.Write("\r" + frames[frame++ % frames.Length] + " " + message); }
                catch { /* Display failures must not interrupt the operation. */ }
            }
        }
        public void Dispose() {
            lock (gate) {
                stopped = true;
                timer.Dispose();
                try { Console.Write("\r" + new string(' ', message.Length + 4) + "\r"); }
                catch { }
            }
        }
    }
}
'@
            }
            $indicator = [Spvc.ActivityIndicator]::new($Message)
        } catch { $indicator = $null }
    }
    if (-not $indicator) { Write-Host "[...] $Message" }
    try { & $Action }
    finally { if ($indicator) { $indicator.Dispose() } }
}
