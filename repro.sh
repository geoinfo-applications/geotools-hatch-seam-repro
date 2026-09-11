#!/bin/bash
# Renders a hatched polygon as adjacent WMS tiles and as one image with a stock GeoServer binary, so the two can be compared.
# Usage: ./repro.sh            (downloads GeoServer, starts it on $PORT, configures, renders, stops)
#        KEEP=1 ./repro.sh     (leaves GeoServer running for inspection)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
VERSION=${GEOSERVER_VERSION:-2.28.5}
PORT=${PORT:-8085}
GS=geoserver-$VERSION
ZIP=$GS-bin.zip
URL="https://sourceforge.net/projects/geoserver/files/GeoServer/$VERSION/$ZIP/download"
REST="http://localhost:$PORT/geoserver/rest"
WMS="http://localhost:$PORT/geoserver/repro/wms"
AUTH="admin:geoserver"

if [ ! -d "$GS" ]; then
    [ -f "$ZIP" ] || { echo "downloading $ZIP"; curl -L --progress-bar -o "$ZIP" "$URL"; }
    mkdir -p "$GS" && unzip -q "$ZIP" -d "$GS"
fi

echo "starting GeoServer $VERSION on port $PORT"
JAVA_OPTS="--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED --add-opens=java.desktop/java.awt.font=ALL-UNNAMED --add-opens=java.desktop/sun.awt.image=ALL-UNNAMED --add-opens=java.naming/com.sun.jndi.ldap=ALL-UNNAMED --add-opens=java.desktop/sun.java2d.pipe=ALL-UNNAMED"
( cd "$GS" && exec java $JAVA_OPTS -DGEOSERVER_DATA_DIR="$PWD/data_dir" -Djava.awt.headless=true -jar start.jar "jetty.http.port=$PORT" ) > out/geoserver.log 2>&1 &
GS_PID=$!
stop() { if [ "${KEEP:-0}" != 1 ]; then kill $GS_PID 2>/dev/null || true; fi; }
trap stop EXIT
for i in $(seq 1 120); do
    curl -s -u $AUTH -o /dev/null -w '' "$REST/about/version.json" && break
    sleep 2
done
curl -sf -u $AUTH "$REST/about/version.json" | grep -o '"Version": *"[^"]*"' | head -2

echo "configuring workspace repro (property datastore + hatch style)"
curl -s -u $AUTH -X DELETE "$REST/workspaces/repro?recurse=true" -o /dev/null
curl -sf -u $AUTH -X POST -H 'Content-Type: application/json' "$REST/workspaces" -d '{"workspace":{"name":"repro"}}' -o /dev/null
curl -sf -u $AUTH -X POST -H 'Content-Type: application/json' "$REST/workspaces/repro/datastores" \
    -d "{\"dataStore\":{\"name\":\"props\",\"type\":\"Properties\",\"connectionParameters\":{\"entry\":[{\"@key\":\"directory\",\"\$\":\"$PWD/data\"}]}}}" -o /dev/null
curl -sf -u $AUTH -X POST -H 'Content-Type: application/json' "$REST/workspaces/repro/datastores/props/featuretypes" \
    -d '{"featureType":{"name":"hatch","srs":"EPSG:3857","nativeBoundingBox":{"minx":-500,"maxx":2600,"miny":-500,"maxy":1600,"crs":"EPSG:3857"}}}' -o /dev/null
curl -sf -u $AUTH -X POST -H 'Content-Type: application/vnd.ogc.sld+xml' "$REST/workspaces/repro/styles?name=hatch" --data-binary @hatch.sld -o /dev/null
curl -sf -u $AUTH -X PUT -H 'Content-Type: application/json' "$REST/layers/repro:hatch" -d '{"layer":{"defaultStyle":{"name":"repro:hatch"}}}' -o /dev/null

getmap() { # <out> <width> <height> <bbox> <dpi>
    curl -sf -o "$1" "$WMS?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=repro:hatch&STYLES=&FORMAT=image/png&TRANSPARENT=true&SRS=EPSG:3857&WIDTH=$2&HEIGHT=$3&BBOX=$4&format_options=dpi:$5"
}
echo "rendering two 1024 px tiles and one 2048 px image at 200 dpi and at 300 dpi"
for dpi in 200 300; do
    getmap out/tile1_dpi$dpi.png 1024 1024 0,0,1024,1024 $dpi
    getmap out/tile2_dpi$dpi.png 1024 1024 1024,0,2048,1024 $dpi
    getmap out/untiled_dpi$dpi.png 2048 1024 0,0,2048,1024 $dpi
done
echo
for dpi in 200 300; do
    java Stitch.java out/tiled_dpi$dpi.png out/tile1_dpi$dpi.png out/tile2_dpi$dpi.png
    java Stitch.java out/untiled_dpi${dpi}_check.png out/untiled_dpi$dpi.png
done
echo
echo "compare out/tiled_dpi300.png (seam at x=1024) with out/untiled_dpi300.png and out/tiled_dpi200.png"
