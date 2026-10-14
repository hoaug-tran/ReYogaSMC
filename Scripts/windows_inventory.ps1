param([string]$ProbeManifest, [switch]$Live)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$report = @{schema_version=1; captured_utc=[DateTime]::UtcNow.ToString('o'); classes=@(); instances=@(); probes=@(); errors=@()}
function Values($object) {
    $values=@{}
    foreach ($p in $object.CimInstanceProperties) { $values[$p.Name]=$p.Value }
    return $values
}
try { $report.computer=Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model } catch { $report.errors+=@{stage='computer';reason=$_.Exception.Message} }
try { $report.bios=Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion,ReleaseDate,EmbeddedControllerMajorVersion,EmbeddedControllerMinorVersion } catch { $report.errors+=@{stage='bios';reason=$_.Exception.Message} }
try { $report.devices=@(Get-CimInstance Win32_PnPEntity | Where-Object {$_.PNPDeviceID -match '^(ACPI|USB)'} | Select-Object Name,PNPDeviceID) } catch { $report.errors+=@{stage='devices';reason=$_.Exception.Message} }
foreach ($ns in @('root/wmi','root/cimv2','root/default')) {
    try {
        $classes=Get-CimClass -Namespace $ns | Where-Object {$_.CimClassName -match 'Lenovo|IBM|Think|Legion|Yoga|Idea|GameZone|Lighting|Fan|Thermal|ACPI|Battery|Panel|VPC|DYTC'}
        foreach ($c in $classes) {
            $report.classes+=@{namespace=$ns;name=$c.CimClassName;qualifiers=@($c.CimClassQualifiers | Select-Object Name,Value);properties=@($c.CimClassProperties | Select-Object Name,CimType);methods=@($c.CimClassMethods | ForEach-Object {
                @{name=$_.Name;return_type=[string]$_.ReturnType;qualifiers=@($_.Qualifiers | Select-Object Name,Value);parameters=@($_.Parameters | ForEach-Object {
                    @{name=$_.Name;type=[string]$_.CimType;qualifiers=@($_.Qualifiers | Select-Object Name,Value)}
                })}
            })}
            if ($ns -eq 'root/wmi' -and $c.CimClassName -match '^(LENOVO_|Lenovo_|IBM_)') {
                try {
                    $items=@(Get-CimInstance -Namespace $ns -ClassName $c.CimClassName -OperationTimeoutSec 5 | Select-Object -First 64)
                    $report.instances+=@{namespace=$ns;class=$c.CimClassName;status='collected';values=@($items | ForEach-Object { Values $_ })}
                } catch { $report.instances+=@{namespace=$ns;class=$c.CimClassName;status='failed';reason=$_.Exception.Message} }
            }
        }
    } catch { $report.errors+=@{stage='classes';namespace=$ns;reason=$_.Exception.Message} }
}
if ($Live) {
    $manifest=Get-Content -LiteralPath $ProbeManifest -Raw | ConvertFrom-Json
    foreach ($probe in $manifest.probes) {
        $entry=@{namespace=$probe.namespace;class=$probe.class;method=$probe.method;arguments=$probe.arguments}
        try {
            $class=Get-CimClass -Namespace $probe.namespace -ClassName $probe.class -OperationTimeoutSec 5
            $method=$class.CimClassMethods[$probe.method]
            if (-not $method) { throw 'Method is not advertised' }
            $args=@{}
            foreach ($p in $probe.arguments.PSObject.Properties) { $args[$p.Name]=$p.Value }
            # Only explicitly reviewed read calls are in the manifest. Output
            # parameters do not count as input parameters.
            foreach ($p in $method.Parameters) {
                $inputQualifier=$p.Qualifiers['In']
                if ($inputQualifier -and $inputQualifier.Value -and -not $args.ContainsKey($p.Name)) { throw "Required input $($p.Name) is missing" }
            }
            $instance=Get-CimInstance -Namespace $probe.namespace -ClassName $probe.class -OperationTimeoutSec 5 | Select-Object -First 1
            if (-not $instance) { throw 'No method provider instance' }
            $result=Invoke-CimMethod -InputObject $instance -MethodName $probe.method -Arguments $args -OperationTimeoutSec 5
            $values=@{}
            foreach ($p in $result.PSObject.Properties) {
                if ($p.Name -notmatch '^PS|^Cim') { $values[$p.Name]=$p.Value }
            }
            $entry.status='collected';$entry.result=$values
        } catch { $entry.status='failed';$entry.reason=$_.Exception.Message }
        $report.probes+=$entry
    }
} else { $report.live_status='not_requested' }
$report | ConvertTo-Json -Depth 18 -Compress
