#!/bin/sh
C=$(grep -l "server_name repository.itk.ac.id" /data/nginx/proxy_host/*.conf 2>/dev/null | head -1)
[ -n "$C" ] || exit 1
grep -q "location = /a.txt" "$C" && exit 0
sed -i '0,/location \/ {/s//location = \/a.txt { default_type text\/plain; return 200 "5ddf70b95977259a"; }\n  location \/ {/' "$C"
docker exec nginx-gui-app-1 nginx -s reload
