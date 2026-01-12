infrapath := "infra"
certspath := "infra/certs"

certs:
    chmod +x {{infrapath}}/certs.script.sh && \
    {{infrapath}}/certs.script.sh

# upload device inter CAs to Kong
upload:
    curl -X POST http://localhost:8001/ca_certificates \
    -F "cert=@{{certspath}}/ca/deviceinter/watertrt.crt" \
    -F "tags[]=iot-watertrt" && \
    curl -X POST http://localhost:8001/ca_certificates \
    -F "cert=@{{certspath}}/ca/deviceinter/watch.crt" \
    -F "tags[]=iot-watch"

# setup watertrt device service
setup-wd:
    curl -sS -X POST http://localhost:8001/services \
    --data name=iot-watertrt \
    --data url=http://host.docker.internal:8080/anything && \
    curl -sS -X POST http://localhost:8001/services/iot-watertrt/routes \
    --data 'paths[]=/secure-iot-watertrt' \
    --data 'hosts[]=watertrt.local' && \
    curl -X POST http://localhost:8001/services/iot-watertrt/plugins \
    -F "name=cert-to-jwt" \
    -F "config.private_key=/etc/secrets/jwt-rs256.key" \
    -F "config.issuer=dolomi.watertrt.kong.issuer" \
    -F "config.expected_issuer=dolomi.watertrt.local" \
    -F "config.exp_seconds=300" \
    -F "config.include_cert_headers=true" \
    -F "config.roles[]=watertrt" \
    -F "config.roles[]=iot" \
    -F "config.scope=write"

# setup watch device service
setup-watch:
    curl -sS -X POST http://localhost:8001/services \
      --data name=iot-watch \
      --data url=http://host.docker.internal:8080/anything && \
    curl -sS -X POST http://localhost:8001/services/iot-watch/routes \
      --data 'paths[]=/secure-iot-watch' \
      --data 'hosts[]=watch.local' && \
    curl -sS -X POST http://localhost:8001/services/iot-watch/plugins \
      --data "name=cert-to-jwt" \
      --data "config.private_key=/etc/secrets/jwt-rs256.key" \
      --data "config.issuer=dolomi.watch.kong.issuer" \
      --data "config.expected_issuer=dolomi.watch.local" \
      --data "config.exp_seconds=300" \
      --data "config.include_cert_headers=true" \
      --data "config.roles[]=watch" \
      --data "config.roles[]=iot" \
      --data "config.scope=read,write"

setup: upload setup-wd setup-watch

# test watertrt client
water := "x00000002"
waterc:
    curl -v https://localhost:8443/secure-iot-watertrt \
    --cert {{certspath}}/devices/watertrt/{{water}}.crt \
    --key {{certspath}}/devices/watertrt/{{water}}.key \
    --cacert {{certspath}}/ca/server/ca.crt \
    -H "Host: watertrt.local"

# test watch client
watch := "x00000002"
watchc:
    curl -v https://localhost:8443/secure-iot-watch \
    --cert {{certspath}}/devices/watch/{{watch}}.crt \
    --key {{certspath}}/devices/watch/{{watch}}.key \
    --cacert {{certspath}}/ca/server/ca.crt \
    -H "Host: watch.local"

# kong migrations
migration:
    docker compose -f {{infrapath}}/docker-compose.yml run --rm kong-migrations

# run full stack
run:
    docker compose -f {{infrapath}}/docker-compose.yml up
