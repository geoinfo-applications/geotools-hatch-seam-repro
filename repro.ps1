# Renders a hatched polygon as adjacent WMS tiles and as one image with a stock GeoServer binary, so the two can be compared.
# Windows counterpart of repro.sh, for Windows PowerShell 5.1 or PowerShell 7.
# Usage: powershell -ExecutionPolicy Bypass -File .\repro.ps1                   (downloads GeoServer, starts it on $env:PORT, configures, renders, stops)
#        $env:KEEP = "1"; powershell -ExecutionPolicy Bypass -File .\repro.ps1  (leaves GeoServer running for inspection)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Set-Location $PSScriptRoot
New-Item -ItemType Directory -Force -Path out | Out-Null
$Version = if ($env:GEOSERVER_VERSION) { $env:GEOSERVER_VERSION } else { "2.28.5" }
$Port = if ($env:PORT) { $env:PORT } else { "8085" }
$GS = "geoserver-$Version"
$Zip = "$GS-bin.zip"
$Url = "https://sourceforge.net/projects/geoserver/files/GeoServer/$Version/$Zip/download"
$Rest = "http://localhost:$Port/geoserver/rest"
$Wms = "http://localhost:$Port/geoserver/repro/wms"
$Auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:geoserver")) }

if (-not (Test-Path $GS)) {
    if (-not (Test-Path $Zip)) {
        Write-Host "downloading $Zip"
        Invoke-WebRequest -UseBasicParsing -UserAgent "curl" -Uri $Url -OutFile $Zip
    }
    Expand-Archive -Path $Zip -DestinationPath $GS
}

Write-Host "starting GeoServer $Version on port $Port"
$JavaArgs = @(
    "--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED", "--add-opens=java.base/java.lang=ALL-UNNAMED",
    "--add-opens=java.base/java.util=ALL-UNNAMED", "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED",
    "--add-opens=java.base/java.text=ALL-UNNAMED", "--add-opens=java.desktop/java.awt.font=ALL-UNNAMED",
    "--add-opens=java.desktop/sun.awt.image=ALL-UNNAMED", "--add-opens=java.naming/com.sun.jndi.ldap=ALL-UNNAMED",
    "--add-opens=java.desktop/sun.java2d.pipe=ALL-UNNAMED",
    "`"-DGEOSERVER_DATA_DIR=$(Join-Path (Resolve-Path $GS).Path data_dir)`"", "-Djava.awt.headless=true",
    "-jar", "start.jar", "jetty.http.port=$Port")
$GeoServer = Start-Process -FilePath java -ArgumentList $JavaArgs -WorkingDirectory $GS -NoNewWindow -PassThru `
    -RedirectStandardOutput (Join-Path $PSScriptRoot out/geoserver.log) `
    -RedirectStandardError (Join-Path $PSScriptRoot out/geoserver-err.log)

function Invoke-Rest($Method, $Path, $ContentType, $Body) {
    Invoke-RestMethod -Method $Method -Uri "$Rest/$Path" -Headers $Auth -ContentType $ContentType -Body $Body | Out-Null
}

function Get-Map($Out, $Width, $Height, $Bbox, $Dpi) {
    Invoke-WebRequest -UseBasicParsing -OutFile (Join-Path out $Out) -Uri ("${Wms}?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=repro:hatch" +
        "&STYLES=&FORMAT=image/png&TRANSPARENT=true&SRS=EPSG:3857&WIDTH=$Width&HEIGHT=$Height&BBOX=$Bbox&format_options=dpi:$Dpi")
}

function Invoke-Stitch {
    & java Stitch.java @args
    if ($LASTEXITCODE -ne 0) { throw "java Stitch.java failed" }
}

try {
    $About = $null
    for ($i = 0; $i -lt 120 -and -not $About; $i++) {
        try { $About = Invoke-RestMethod -Uri "$Rest/about/version.json" -Headers $Auth } catch { Start-Sleep -Seconds 2 }
    }
    if (-not $About) { throw "GeoServer did not start, see out/geoserver.log" }
    $About.about.resource | Where-Object { $_.Version } | Select-Object -First 2 | ForEach-Object { "$($_.'@name') $($_.Version)" }

    Write-Host "configuring workspace repro (property datastore + hatch style)"
    try { Invoke-Rest Delete "workspaces/repro?recurse=true" } catch { }
    Invoke-Rest Post "workspaces" "application/json" '{"workspace":{"name":"repro"}}'
    $Store = @{ dataStore = @{ name = "props"; type = "Properties"
            connectionParameters = @{ entry = @(@{ '@key' = "directory"; '$' = (Resolve-Path data).Path }) } } }
    Invoke-Rest Post "workspaces/repro/datastores" "application/json" ($Store | ConvertTo-Json -Depth 6)
    Invoke-Rest Post "workspaces/repro/datastores/props/featuretypes" "application/json" `
        '{"featureType":{"name":"hatch","srs":"EPSG:3857","nativeBoundingBox":{"minx":-500,"maxx":2600,"miny":-500,"maxy":1600,"crs":"EPSG:3857"}}}'
    Invoke-Rest Post "workspaces/repro/styles?name=hatch" "application/vnd.ogc.sld+xml" ([IO.File]::ReadAllBytes((Resolve-Path hatch.sld).Path))
    Invoke-Rest Put "layers/repro:hatch" "application/json" '{"layer":{"defaultStyle":{"name":"repro:hatch"}}}'

    Write-Host "rendering two 1024 px tiles and one 2048 px image at 200 dpi and at 300 dpi"
    foreach ($Dpi in 200, 300) {
        Get-Map "tile1_dpi$Dpi.png" 1024 1024 "0,0,1024,1024" $Dpi
        Get-Map "tile2_dpi$Dpi.png" 1024 1024 "1024,0,2048,1024" $Dpi
        Get-Map "untiled_dpi$Dpi.png" 2048 1024 "0,0,2048,1024" $Dpi
    }
    Write-Host ""
    foreach ($Dpi in 200, 300) {
        Invoke-Stitch "out/tiled_dpi$Dpi.png" "out/tile1_dpi$Dpi.png" "out/tile2_dpi$Dpi.png"
        Invoke-Stitch "out/untiled_dpi${Dpi}_check.png" "out/untiled_dpi$Dpi.png"
    }
    Write-Host ""
    Write-Host "compare out/tiled_dpi300.png (seam at x=1024) with out/untiled_dpi300.png and out/tiled_dpi200.png"
} finally {
    if ($env:KEEP -ne "1") { Stop-Process -Id $GeoServer.Id -ErrorAction SilentlyContinue }
}
